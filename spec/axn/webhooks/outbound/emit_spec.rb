# frozen_string_literal: true

require "base64"
require "json"

RSpec.describe "Axn::Webhooks.emit" do
  after { Axn::Webhooks::Outbound.reset! }

  before do
    Axn::Webhooks.outbound do
      sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('secret')}"
      event :lead_signed, to: ["https://a.example/hook", "https://b.example/hook"]
    end
    # Capture Deliver enqueues without running HTTP. Deliver has no adapter in the test env, so the
    # Emit fan-out uses the sync inline path unless we stub; stub call to record instead.
    allow(Axn::Webhooks::Outbound::Deliver).to receive(:call)
  end

  it "raises loudly on an unknown event" do
    expect { Axn::Webhooks.emit(:not_a_real_event, data: {}) }
      .to raise_error(Axn::Webhooks::Error, /unknown outbound event/)
  end

  it "fans out one delivery per target, each with a distinct webhook-id and the wire type" do
    calls = []
    allow(Axn::Webhooks::Outbound::Deliver).to receive(:call) { |**kw| calls << kw }

    Axn::Webhooks.emit(:lead_signed, data: { lead_id: 42 })

    expect(calls.size).to eq(2)

    urls = calls.map { |c| c[:url] }
    ids = calls.map { |c| c[:webhook_id] }
    expect(urls).to contain_exactly("https://a.example/hook", "https://b.example/hook")
    expect(ids.uniq.size).to eq(2) # distinct id per (emission x target)

    body = JSON.parse(calls.first[:body])
    expect(body).to include("type" => "lead_signed", "data" => { "lead_id" => 42 })
    expect(body["id"]).to eq(calls.first[:webhook_id])
  end

  it "warns when delivering synchronously because no async adapter is configured" do
    expect(Axn.config.logger).to receive(:warn).with(/synchronous|no async adapter/i).at_least(:once)
    Axn::Webhooks.emit(:lead_signed, data: {})
  end
end
