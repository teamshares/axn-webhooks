# frozen_string_literal: true

require "openssl"
require "rack"

RSpec.describe "Axn::Webhooks::Inbound::Endpoint#call (Rack app)" do
  after { Axn::Webhooks::Inbound.reset! }

  before do
    stub_const("Handlers", Module.new)
    stub_const("Handlers::Created", Class.new do
      include Axn

      expects :event
      exposes :seen_id
      def call = expose(seen_id: event.dig("data", "id"))
    end)
  end

  def signed_env(body, secret:, sig: nil)
    sig ||= OpenSSL::HMAC.hexdigest("SHA256", secret, body)
    Rack::MockRequest.env_for("/webhooks/vendor", method: "POST", input: body,
                                                  "CONTENT_TYPE" => "application/json",
                                                  "HTTP_X_SIG" => sig)
  end

  it "responds to call(env) directly, satisfying the Rack app contract" do
    Axn::Webhooks.inbound(:vendor) { verify { |_req| true } }
    expect(Axn::Webhooks::Inbound[:vendor]).to respond_to(:call)
  end

  it "is mountable/runnable via Rack::MockRequest end-to-end (POST -> verify -> dispatch -> ack)" do
    secret = "shh"
    Axn::Webhooks.inbound(:vendor) do
      verify :hmac, secret:, signature: header("X-Sig")
      dispatch on: ->(e) { e["type"] }, to: { "created" => "Handlers::Created" }
    end
    body = '{"type":"created","data":{"id":99}}'
    status, headers, response_body = Axn::Webhooks::Inbound[:vendor].call(signed_env(body, secret:))
    expect(status).to eq(200)
    expect(headers).to eq({})
    expect(response_body).to eq([""])
  end

  it "returns 401 for a bad signature over Rack" do
    secret = "shh"
    Axn::Webhooks.inbound(:vendor) { verify :hmac, secret:, signature: header("X-Sig") }
    status, = Axn::Webhooks::Inbound[:vendor].call(signed_env("{}", secret:, sig: "wrong"))
    expect(status).to eq(401)
  end

  it "handles GET as the declared challenge" do
    Axn::Webhooks.inbound(:vendor) { challenge ->(req) { req.params["challenge"] } }
    env = Rack::MockRequest.env_for("/webhooks/vendor?challenge=xyz", method: "GET", input: "")
    status, headers, body = Axn::Webhooks::Inbound[:vendor].call(env)
    expect(status).to eq(200)
    expect(headers["content-type"]).to eq("text/plain")
    expect(body).to eq(["xyz"])
  end

  it "handles a GET challenge that carries a form-urlencoded Content-Type header (regression)" do
    # GET challenge requests (Nylas/Meta-style) sometimes carry a default
    # application/x-www-form-urlencoded Content-Type header alongside an empty body. This must
    # not be treated as a form body to parse (which would find nothing and 400) — GET always
    # reads params from the query string.
    Axn::Webhooks.inbound(:vendor) { challenge ->(req) { req.params["challenge"] } }
    env = Rack::MockRequest.env_for("/webhooks/vendor?challenge=xyz", method: "GET", input: "",
                                                                      "CONTENT_TYPE" => "application/x-www-form-urlencoded")
    status, _headers, body = Axn::Webhooks::Inbound[:vendor].call(env)
    expect(status).to eq(200)
    expect(body).to eq(["xyz"])
  end

  it "405s a GET with no declared challenge" do
    Axn::Webhooks.inbound(:vendor) { verify { |_req| true } }
    env = Rack::MockRequest.env_for("/webhooks/vendor", method: "GET", input: "")
    status, = Axn::Webhooks::Inbound[:vendor].call(env)
    expect(status).to eq(405)
  end

  it "405s any verb other than GET/POST" do
    Axn::Webhooks.inbound(:vendor) { verify { |_req| true } }
    env = Rack::MockRequest.env_for("/webhooks/vendor", method: "PUT", input: "")
    status, = Axn::Webhooks::Inbound[:vendor].call(env)
    expect(status).to eq(405)
  end

  it "returns a clean 500 (never raises) when BuildRequest can't parse the env" do
    Axn::Webhooks.inbound(:vendor) { verify { |_req| true } }
    # Stubbed rather than hand-built: since rack.input is optional under Rack 3, an env sparse
    # enough to break parsing no longer exists. The invariant under test is the mapping — a
    # BuildRequest failure becomes a 500 instead of escaping as a raise.
    allow(Axn::Webhooks::Request).to receive(:from_rack).and_raise(KeyError, "malformed env")

    env = Rack::MockRequest.env_for("/webhooks/vendor", method: "POST", input: "")
    status, = nil
    expect { status, = Axn::Webhooks::Inbound[:vendor].call(env) }.not_to raise_error
    expect(status).to eq(500)
  end

  it "answers a bodyless GET challenge whose env omits rack.input entirely" do
    # Regression: rack.input is optional under Rack 3, and Rack::MockRequest.env_for omits it for a
    # bodyless request — so every Rails request spec (and any conformant Rack 3 server) hit a 500 on
    # the Nylas/Meta GET handshake. See Request.from_rack.
    Axn::Webhooks.inbound(:vendor) do
      verify { |_req| true }
      challenge ->(req) { req.params["challenge"] }
    end

    env = Rack::MockRequest.env_for("/webhooks/vendor?challenge=accepted", method: "GET")
    expect(env).not_to have_key("rack.input")

    status, _headers, body = Axn::Webhooks::Inbound[:vendor].call(env)
    expect(status).to eq(200)
    expect(body).to eq(["accepted"])
  end

  it "challenge-only endpoint returns bare 200 ack on POST (intentional: no dispatch means no processing)" do
    Axn::Webhooks.inbound(:probe) { challenge ->(req) { req.params["challenge"] } }
    env = Rack::MockRequest.env_for("/webhooks/probe", method: "POST", input: '{"event":"test"}',
                                                       "CONTENT_TYPE" => "application/json")
    status, headers, response_body = Axn::Webhooks::Inbound[:probe].call(env)
    expect(status).to eq(200)
    expect(headers).to eq({})
    expect(response_body).to eq([""])
  end
end
