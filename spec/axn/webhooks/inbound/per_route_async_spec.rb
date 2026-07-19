# frozen_string_literal: true

RSpec.describe "Axn::Webhooks::Inbound mixed per-route sync/async endpoint (PRO-2952)" do
  after { Axn::Webhooks::Inbound.reset! }

  before do
    # Async-ack route: non-Axn stub recording call_async (no adapter machinery needed).
    stub_const("BlockActionsHandler", Class.new do
      def self.calls = (@calls ||= [])
      def self.call_async(**kwargs) = calls << kwargs
    end)

    # Sync-body route: a real Axn handler returning a value the respond block renders.
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
                 "block_actions" => { call: "BlockActionsHandler", async: true },
                 "view_submission" => "ViewSubmissionHandler",
               }
      respond { |result| text(result.body) }
    end
  end

  def post(body) = Axn::Webhooks::Inbound[:slack].to_response(Axn::Webhooks::Request.new(raw_body: body))

  it "acks the async route with a bare 2xx and enqueues it" do
    response = post('{"type":"block_actions"}')
    expect(response.status).to eq(200)
    expect(response.body).to eq("")
    expect(BlockActionsHandler.calls).to eq([{ event: { "type" => "block_actions" } }])
  end

  it "runs the sync route inline and renders its respond body" do
    response = post('{"type":"view_submission"}')
    expect(response.status).to eq(200)
    expect(response.body).to eq("clear")
    expect(BlockActionsHandler.calls).to eq([]) # sync route did not enqueue
  end
end
