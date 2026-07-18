# frozen_string_literal: true

RSpec.describe "Axn::Webhooks::Inbound async dispatch mode" do
  after { Axn::Webhooks::Inbound.reset! }

  before do
    stub_const("AsyncHandler", Class.new do
      def self.calls = (@calls ||= [])
      def self.call_async(**kwargs) = calls << kwargs
    end)
  end

  it "acks immediately via a bare 2xx when mode: :async enqueues successfully" do
    Axn::Webhooks.inbound(:vendor) do
      verify { |_req| true }
      dispatch to: "AsyncHandler", mode: :async
    end
    response = Axn::Webhooks::Inbound[:vendor].to_response(Axn::Webhooks::Request.new(raw_body: "{}"))
    expect(response.status).to eq(200)
    expect(response.body).to eq("")
    expect(AsyncHandler.calls).to eq([{ event: {} }])
  end

  it "rejects an unknown mode: at declaration time" do
    expect do
      Axn::Webhooks.inbound(:bad) do
        verify { |_req| true }
        dispatch to: "AsyncHandler", mode: :yolo
      end
    end.to raise_error(Axn::Webhooks::Error, /mode:/)
  end

  it "rejects combining explicit mode: :async with a custom respond block at declaration time" do
    expect do
      Axn::Webhooks.inbound(:bad) do
        verify { |_req| true }
        dispatch to: "AsyncHandler", mode: :async
        respond { |result| text(result.to_s) }
      end
    end.to raise_error(Axn::Webhooks::Error, /handler_result/)
  end

  it "allows mode: :async with no respond declared" do
    expect do
      Axn::Webhooks.inbound(:ok) do
        verify { |_req| true }
        dispatch to: "AsyncHandler", mode: :async
      end
    end.not_to raise_error
  end

  it "a custom respond (mode: :auto) runs sync so respond can read the result" do
    stub_const("TwimlHandler", Class.new do
      include Axn

      expects :event, allow_blank: true
      exposes :twiml
      def call = expose(twiml: "<Response/>")
    end)
    TwimlHandler._async_adapter = :sidekiq # even with an adapter configured, a respond forces sync
    Axn::Webhooks.inbound(:twilio) do
      verify { |_req| true }
      dispatch to: "TwimlHandler" # mode: :auto
      respond { |result| xml(result.twiml) }
    end
    response = Axn::Webhooks::Inbound[:twilio].to_response(Axn::Webhooks::Request.new(raw_body: "{}"))
    expect(response.body).to eq("<Response/>")
  end
end
