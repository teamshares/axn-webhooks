# frozen_string_literal: true

require "openssl"

RSpec.describe "Axn::Webhooks endpoint#handle (verify + dispatch)" do
  after { Axn::Webhooks::Inbound.reset! }

  let(:secret) { "shh" }

  before do
    stub_const("Handlers", Module.new)
    stub_const("Handlers::Created",
               Class.new do
                 include Axn

                 expects :event
                 exposes :seen_id

                 def call = expose(seen_id: event.dig("data", "id"))
               end)
  end

  def signed_request(body)
    sig = OpenSSL::HMAC.hexdigest("SHA256", secret, body)
    Axn::Webhooks::Request.new(raw_body: body, headers: { "X-Sig" => sig })
  end

  it "verifies then dispatches to the keyed handler" do
    Axn::Webhooks.inbound(:vendor) do
      verify :hmac, secret: "shh", signature: header("X-Sig")
      dispatch on: ->(e) { e["type"] }, to: { "created" => "Handlers::Created" }
    end

    body = '{"type":"created","data":{"id":99}}'
    result = Axn::Webhooks::Inbound[:vendor].handle(signed_request(body))
    expect(result).to be_ok
    expect(result.seen_id).to eq(99)
  end

  it "short-circuits to the verify failure without dispatching on a bad signature" do
    Axn::Webhooks.inbound(:vendor) do
      verify :hmac, secret: "shh", signature: header("X-Sig")
      dispatch to: "Handlers::Created"
    end

    bad = Axn::Webhooks::Request.new(raw_body: '{"type":"created"}', headers: { "X-Sig" => "deadbeef" })
    result = Axn::Webhooks::Inbound[:vendor].handle(bad)
    expect(result).not_to be_ok
    expect(result.outcome).to be_failure # verify mismatch, not a dispatch exception
  end

  it "supports a form-body parse: override" do
    stub_const("Handlers::Sms",
               Class.new do
                 include Axn

                 expects :event
                 exposes :from

                 def call = expose(from: event["From"])
               end)
    Axn::Webhooks.inbound(:twilio) do
      verify { |_req| true }
      # rubocop:disable Style/SymbolProc
      dispatch to: "Handlers::Sms", parse: ->(req) { req.params }
      # rubocop:enable Style/SymbolProc
    end

    req = Axn::Webhooks::Request.new(raw_body: "From=+15550001111", params: { "From" => "+15550001111" })
    result = Axn::Webhooks::Inbound[:twilio].handle(req)
    expect(result).to be_ok
    expect(result.from).to eq("+15550001111")
  end

  it "returns the verify result for a verify-only endpoint (no dispatch)" do
    Axn::Webhooks.inbound(:probe) { verify { |_req| true } }
    result = Axn::Webhooks::Inbound[:probe].handle(Axn::Webhooks::Request.new(raw_body: ""))
    expect(result).to be_ok
  end
end
