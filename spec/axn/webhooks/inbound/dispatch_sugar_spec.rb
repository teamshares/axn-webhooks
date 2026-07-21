# frozen_string_literal: true

RSpec.describe "Axn::Webhooks::Inbound dispatch-map async/sync sugar" do
  describe Axn::Webhooks::Inbound::DSL do
    let(:dsl) { described_class.new }

    it "async(call) builds an async dispatch entry" do
      expect(dsl.async("Handler")).to eq({ call: "Handler", async: true })
    end

    it "sync(call) builds a sync dispatch entry" do
      expect(dsl.sync("Handler")).to eq({ call: "Handler", async: false })
    end

    it "passes extra kwargs (e.g. with:) through unchanged" do
      extractor = ->(e) { { id: e["id"] } }
      expect(dsl.async("Handler", with: extractor)).to eq({ call: "Handler", async: true, with: extractor })
      expect(dsl.sync("Handler", with: extractor)).to eq({ call: "Handler", async: false, with: extractor })
    end
  end

  describe "used inside a real inbound block (instance_exec context)" do
    after { Axn::Webhooks::Inbound.reset! }

    before do
      stub_const("BlockActionsHandler", Class.new do
        def self.calls = (@calls ||= [])
        def self.call_async(**kwargs) = calls << kwargs
      end)

      stub_const("ViewSubmissionHandler", Class.new do
        include Axn

        expects :event, allow_blank: true
        exposes :body
        def call = expose(body: "clear")
      end)

      Axn::Webhooks.inbound(:slack) do
        verify { |_req| true }
        dispatch on: ->(e) { e["type"] },
                 to: {
                   "block_actions" => async("BlockActionsHandler"),
                   "view_submission" => sync("ViewSubmissionHandler"),
                 }
        respond { |result| text(result.body) }
      end
    end

    def post(body) = Axn::Webhooks::Inbound[:slack].to_response(Axn::Webhooks::Request.new(raw_body: body))

    it "async(...) routes the entry async: acks with an empty 2xx and enqueues" do
      response = post('{"type":"block_actions"}')
      expect(response.status).to eq(200)
      expect(response.body).to eq("")
      expect(BlockActionsHandler.calls).to eq([{ event: { "type" => "block_actions" } }])
    end

    it "sync(...) routes the entry sync: runs inline and renders the respond body" do
      response = post('{"type":"view_submission"}')
      expect(response.status).to eq(200)
      expect(response.body).to eq("clear")
      expect(BlockActionsHandler.calls).to eq([])
    end
  end
end
