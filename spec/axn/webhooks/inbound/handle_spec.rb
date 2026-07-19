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
    expect(result.handler_result.seen_id).to eq(99)
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
      dispatch to: "Handlers::Sms", parse: lambda(&:params)
    end

    req = Axn::Webhooks::Request.new(raw_body: "From=+15550001111", params: { "From" => "+15550001111" })
    result = Axn::Webhooks::Inbound[:twilio].handle(req)
    expect(result).to be_ok
    expect(result.handler_result.from).to eq("+15550001111")
  end

  it "returns the verify result for a verify-only endpoint (no dispatch)" do
    Axn::Webhooks.inbound(:probe) { verify { |_req| true } }
    result = Axn::Webhooks::Inbound[:probe].handle(Axn::Webhooks::Request.new(raw_body: ""))
    expect(result).to be_ok
  end

  it "returns (does not raise) a Dispatch exception result through handle when the handler class is missing" do
    Axn::Webhooks.inbound(:missing) do
      verify { |_req| true }
      dispatch to: "Totally::Missing::Handler"
    end

    body = '{"type":"created"}'
    result = nil
    expect { result = Axn::Webhooks::Inbound[:missing].handle(signed_request(body)) }.not_to raise_error
    expect(result.outcome).to be_exception
  end

  it "returns (does not raise) a Dispatch exception result through handle when the handler crashes" do
    stub_const("Handlers::Boom",
               Class.new do
                 include Axn

                 expects :event, allow_blank: true
                 def call = raise "boom"
               end)
    Axn::Webhooks.inbound(:boom) do
      verify { |_req| true }
      dispatch to: "Handlers::Boom"
    end

    body = '{"type":"created"}'
    result = nil
    expect { result = Axn::Webhooks::Inbound[:boom].handle(signed_request(body)) }.not_to raise_error
    expect(result.outcome).to be_exception
  end
end

RSpec.describe "Endpoint#to_response retry_later" do
  after { Axn::Webhooks::Inbound.reset! }

  it "maps a handler retry_later! to 503 + Retry-After, without reporting via on_exception " \
     "(the no-paging guarantee, using the recommended Axn::Webhooks::Handler include)" do
    stub_const("DeferHandler", Class.new do
      include Axn::Webhooks::Handler

      expects :event, allow_blank: true
      def call = Axn::Webhooks.retry_later!(after: 60)
    end)

    Axn::Webhooks.inbound(:vendor) do
      verify { |_req| true }
      dispatch to: "DeferHandler", mode: :sync
    end

    expect(Axn.config).not_to receive(:on_exception)

    response = Axn::Webhooks::Inbound[:vendor].to_response(Axn::Webhooks::Request.new(raw_body: "{}"))
    expect(response.status).to eq(503)
    expect(response.headers["retry-after"]).to eq("60")
  end

  it "maps a bare handler retry_later! (no after:) to 503 with no Retry-After header, " \
     "without reporting via on_exception" do
    stub_const("BareDeferHandler", Class.new do
      include Axn::Webhooks::Handler

      expects :event, allow_blank: true
      def call = Axn::Webhooks.retry_later!
    end)

    Axn::Webhooks.inbound(:vendor) do
      verify { |_req| true }
      dispatch to: "BareDeferHandler", mode: :sync
    end

    expect(Axn.config).not_to receive(:on_exception)

    response = Axn::Webhooks::Inbound[:vendor].to_response(Axn::Webhooks::Request.new(raw_body: "{}"))
    expect(response.status).to eq(503)
    expect(response.headers).not_to have_key("retry-after")
  end

  it "still 503s a plain include-Axn handler's retry_later!, but pages via on_exception first " \
     "(regression proof/contrast: this is exactly why Axn::Webhooks::Handler, or a manual " \
     "`fails_on Axn::Webhooks::RetryLater`, is the recommended pattern)" do
    stub_const("PlainAxnDeferHandler", Class.new do
      include Axn # deliberately NOT Axn::Webhooks::Handler — no fails_on RetryLater

      expects :event, allow_blank: true
      def call = Axn::Webhooks.retry_later!(after: 60)
    end)

    Axn::Webhooks.inbound(:vendor) do
      verify { |_req| true }
      dispatch to: "PlainAxnDeferHandler", mode: :sync
    end

    expect(Axn.config).to receive(:on_exception).once

    response = Axn::Webhooks::Inbound[:vendor].to_response(Axn::Webhooks::Request.new(raw_body: "{}"))
    # The 503 mapping still works (Dispatch's rescue catches the re-raised RetryLater regardless
    # of which axn bucket classified it) — only the paging behavior differs.
    expect(response.status).to eq(503)
    expect(response.headers["retry-after"]).to eq("60")
  end
end
