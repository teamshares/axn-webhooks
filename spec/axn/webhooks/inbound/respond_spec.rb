# frozen_string_literal: true

RSpec.describe "Axn::Webhooks::Inbound::Endpoint#to_response (staged HTTP outcome mapping)" do
  after { Axn::Webhooks::Inbound.reset! }

  before do
    stub_const("Handlers", Module.new)
    stub_const("Handlers::Created", Class.new do
      include Axn

      expects :event, allow_blank: true
      exposes :twiml
      def call = expose(twiml: "<Response>ok</Response>")
    end)
    stub_const("Handlers::FailsQuietly", Class.new do
      include Axn

      expects :event, allow_blank: true
      def call = fail!("we don't care")
    end)
    stub_const("Handlers::Boom", Class.new do
      include Axn

      expects :event, allow_blank: true
      def call = raise("handler crashed")
    end)
  end

  def req(body) = Axn::Webhooks::Request.new(raw_body: body)

  it "maps a signature mismatch to 401 without dispatching" do
    Axn::Webhooks.inbound(:vendor) do
      verify { |_req| false }
      dispatch to: "Handlers::Boom"
    end
    response = Axn::Webhooks::Inbound[:vendor].to_response(req("{}"))
    expect(response.status).to eq(401)
  end

  it "maps a verifier crash to 401 (reported, not leaked)" do
    Axn::Webhooks.inbound(:vendor) { verify { |_req| raise "verifier bug" } }
    expect(Axn::Webhooks::Inbound[:vendor].to_response(req("{}")).status).to eq(401)
  end

  it "maps a missing handler class to 500" do
    Axn::Webhooks.inbound(:vendor) do
      verify { |_req| true }
      dispatch to: "Totally::Missing::Handler"
    end
    expect(Axn::Webhooks::Inbound[:vendor].to_response(req("{}")).status).to eq(500)
  end

  it "maps a handler crash to 500" do
    Axn::Webhooks.inbound(:vendor) do
      verify { |_req| true }
      dispatch to: "Handlers::Boom"
    end
    expect(Axn::Webhooks::Inbound[:vendor].to_response(req("{}")).status).to eq(500)
  end

  it "maps an unmatched event with otherwise: :ack to a bare 2xx" do
    Axn::Webhooks.inbound(:vendor) do
      verify { |_req| true }
      dispatch on: ->(e) { e["t"] }, to: { "known" => "Handlers::Created" }, otherwise: :ack
    end
    response = Axn::Webhooks::Inbound[:vendor].to_response(req('{"t":"surprise"}'))
    expect(response.status).to eq(200)
    expect(response.body).to eq("")
  end

  it "maps a handler business fail! to a bare 2xx (quiet, already logged by axn)" do
    Axn::Webhooks.inbound(:vendor) do
      verify { |_req| true }
      dispatch to: "Handlers::FailsQuietly"
    end
    response = Axn::Webhooks::Inbound[:vendor].to_response(req("{}"))
    expect(response.status).to eq(200)
    expect(response.body).to eq("")
  end

  it "defaults a genuine handler success to a bare 2xx ack when no respond is declared" do
    Axn::Webhooks.inbound(:vendor) do
      verify { |_req| true }
      dispatch to: "Handlers::Created"
    end
    response = Axn::Webhooks::Inbound[:vendor].to_response(req("{}"))
    expect(response.status).to eq(200)
    expect(response.body).to eq("")
  end

  it "maps a genuine handler success through a custom respond block (Twilio-style TwiML)" do
    Axn::Webhooks.inbound(:vendor) do
      verify { |_req| true }
      dispatch to: "Handlers::Created"
      respond { |result| xml(result.twiml) }
    end
    response = Axn::Webhooks::Inbound[:vendor].to_response(req("{}"))
    expect(response.status).to eq(200)
    expect(response.body).to eq("<Response>ok</Response>")
    expect(response.headers).to eq("content-type" => "application/xml")
  end

  it "maps a raise inside the respond block to a reported 500 (never an escaping exception)" do
    Axn::Webhooks.inbound(:vendor) do
      verify { |_req| true }
      dispatch to: "Handlers::Created"
      respond { |result| xml(result.exposure_the_handler_forgot) } # raises NoMethodError inside respond
    end
    response = nil
    expect { response = Axn::Webhooks::Inbound[:vendor].to_response(req("{}")) }.not_to raise_error
    expect(response.status).to eq(500)
  end

  it "supports a literal string body (DropboxSign-style)" do
    Axn::Webhooks.inbound(:vendor) do
      verify { |_req| true }
      dispatch to: "Handlers::Created"
      respond { |_result| text("Hello API Event Received") }
    end
    expect(Axn::Webhooks::Inbound[:vendor].to_response(req("{}")).body).to eq("Hello API Event Received")
  end

  it "returns a bare 2xx ack for a verify-only endpoint (no dispatch declared)" do
    Axn::Webhooks.inbound(:probe) { verify { |_req| true } }
    response = Axn::Webhooks::Inbound[:probe].to_response(req(""))
    expect(response.status).to eq(200)
    expect(response.body).to eq("")
  end
end
