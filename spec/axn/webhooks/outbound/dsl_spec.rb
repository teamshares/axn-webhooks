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

  it "stringifies a non-String per-event wire type override (codex P2)" do
    Axn::Webhooks.outbound do
      sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('s')}"
      event :x, type: :sym_type
    end
    result = Axn::Webhooks::Outbound.config.wire_type(:x)
    expect(result).to eq("sym_type")
    expect(result).to be_a(String)
  end

  it "falls back to the block-level `subscribers` resolver when an event has no `to:`" do
    Axn::Webhooks.outbound do
      sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('s')}"
      subscribers ->(event) { ["https://resolved/#{event}"] }
      event :lead_closed
    end
    expect(Axn::Webhooks::Outbound.config.targets_for(:lead_closed)).to eq(["https://resolved/lead_closed"])
  end

  it "does NOT fall back to `subscribers` when a declared per-event `to:` resolver returns nil" do
    Axn::Webhooks.outbound do
      sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('s')}"
      subscribers ->(_event) { ["https://DEFAULT"] }
      event :x, to: ->(_event) {}
      event :y
    end
    config = Axn::Webhooks::Outbound.config

    # Declared `to:` won even though it resolved to nil -> deliver nowhere, NOT the default audience.
    expect(config.targets_for(:x)).to eq([])
    # Undeclared `to:` still falls back to the block-level `subscribers` resolver, unchanged.
    expect(config.targets_for(:y)).to eq(["https://DEFAULT"])
  end

  it "invokes a per-event `to:` lambda (arity-aware) instead of wrapping the Proc itself" do
    Axn::Webhooks.outbound do
      sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('s')}"
      event :lead_signed, to: ->(event) { ["https://u/#{event}"] }
    end
    expect(Axn::Webhooks::Outbound.config.targets_for(:lead_signed)).to eq(["https://u/lead_signed"])
  end

  it "still supports a static Array `to:` alongside a per-event lambda on another event" do
    Axn::Webhooks.outbound do
      sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('s')}"
      event :lead_signed, to: ["https://os.example/hook"]
      event :lead_closed, to: ->(event) { ["https://u/#{event}"] }
    end
    config = Axn::Webhooks::Outbound.config
    expect(config.targets_for(:lead_signed)).to eq(["https://os.example/hook"])
    expect(config.targets_for(:lead_closed)).to eq(["https://u/lead_closed"])
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

  describe "Config#transport" do
    it "defaults to Outbound::Transport when the block does not call `transport`" do
      Axn::Webhooks.outbound do
        sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('s')}"
        event :lead_signed, to: ["https://x"]
      end
      expect(Axn::Webhooks::Outbound.config.transport).to eq(Axn::Webhooks::Outbound::Transport)
    end

    it "uses the object passed to `transport` when the block declares one" do
      custom_transport = Object.new
      Axn::Webhooks.outbound do
        sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('s')}"
        transport custom_transport
        event :lead_signed, to: ["https://x"]
      end
      expect(Axn::Webhooks::Outbound.config.transport).to equal(custom_transport)
    end
  end
end
