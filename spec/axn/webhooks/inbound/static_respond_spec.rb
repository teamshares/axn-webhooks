# frozen_string_literal: true

RSpec.describe "Axn::Webhooks::Inbound static_respond" do
  before do
    stub_const("Handlers", Module.new) unless defined?(Handlers)
    stub_const("Handlers::Created", Class.new do
      include Axn

      expects :event, allow_blank: true
      def call = nil
    end)
  end

  after { Axn::Webhooks::Inbound.reset! }

  describe "registration" do
    it "rejects declaring both respond and static_respond at declaration time" do
      expect do
        Axn::Webhooks.inbound(:bad) do
          verify { |_req| true }
          dispatch to: "Handlers::Created"
          respond { |result| text(result.to_s) }
          static_respond { text("Hello API Event Received") }
        end
      end.to raise_error(Axn::Webhooks::Error, /declares both `respond` and `static_respond`/)
    end

    it "allows static_respond alone" do
      expect do
        Axn::Webhooks.inbound(:ok) do
          verify { |_req| true }
          dispatch to: "Handlers::Created"
          static_respond { text("Hello API Event Received") }
        end
      end.not_to raise_error
    end
  end
end
