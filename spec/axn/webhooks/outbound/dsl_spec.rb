# frozen_string_literal: true

require "base64"

RSpec.describe "Axn::Webhooks.outbound" do
  after { Axn::Webhooks::Outbound.reset! }

  let(:secret) { "whsec_#{Base64.strict_encode64('secret')}" }

  it "captures signer, events, and retry curve; resolves static targets" do
    Axn::Webhooks.outbound do
      sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('secret')}"
      max_attempts 5
      backoff ->(attempt) { attempt * 10 }
      event :lead_signed, to: ["https://os.example/hook"]
    end

    config = Axn::Webhooks::Outbound.config
    expect(config.targets_for(:lead_signed)).to eq(["https://os.example/hook"])
    expect(config.max_attempts).to eq(5)
    expect(config.backoff.call(3)).to eq(30)
    expect(config.wire_type(:lead_signed)).to eq("lead_signed")
    expect(config.signer.call(id: "m", timestamp: 1, body: "b")).to include("webhook-signature")
  end

  it "supports a per-event wire type override" do
    Axn::Webhooks.outbound do
      sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('s')}"
      event :lead_signed, type: "lead.signed", to: ["https://x"]
    end
    expect(Axn::Webhooks::Outbound.config.wire_type(:lead_signed)).to eq("lead.signed")
  end

  it "falls back to the block-level `subscribers` resolver when an event has no `to:`" do
    Axn::Webhooks.outbound do
      sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('s')}"
      subscribers ->(event) { ["https://resolved/#{event}"] }
      event :lead_closed
    end
    expect(Axn::Webhooks::Outbound.config.targets_for(:lead_closed)).to eq(["https://resolved/lead_closed"])
  end

  it "raises loudly on an unknown event, listing the known ones" do
    Axn::Webhooks.outbound do
      sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('s')}"
      event :lead_signed, to: ["https://x"]
    end
    expect { Axn::Webhooks::Outbound.config.targets_for(:nope) }
      .to raise_error(Axn::Webhooks::Error, /unknown outbound event :nope.*lead_signed/m)
  end

  it "raises when config is read before `outbound` is declared" do
    Axn::Webhooks::Outbound.reset!
    expect { Axn::Webhooks::Outbound.config }.to raise_error(Axn::Webhooks::Error, /no `outbound` block/)
  end

  it "warns (does not raise) at boot when an event has a statically empty target list" do
    expect(Axn.config.logger).to receive(:warn).with(/lead_signed.*empty/i)
    Axn::Webhooks.outbound do
      sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('s')}"
      event :lead_signed, to: []
    end
  end
end
