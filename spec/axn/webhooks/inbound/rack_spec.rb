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

  it "returns a clean 500 (never raises) for a malformed env BuildRequest can't parse" do
    Axn::Webhooks.inbound(:vendor) { verify { |_req| true } }
    broken_env = { "REQUEST_METHOD" => "POST" } # no rack.input at all
    status, = nil
    expect { status, = Axn::Webhooks::Inbound[:vendor].call(broken_env) }.not_to raise_error
    expect(status).to eq(500)
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
