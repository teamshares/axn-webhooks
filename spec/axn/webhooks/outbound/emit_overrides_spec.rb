# frozen_string_literal: true

require "base64"

RSpec.describe "Axn::Webhooks.emit per-call overrides" do
  after { Axn::Webhooks::Outbound.reset! }

  let(:calls) { [] }

  before do
    Axn::Webhooks.outbound do
      sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('s')}"
      event :lead_signed, to: ["https://declared.example/hook"]
    end

    recorded = calls
    allow(Axn::Webhooks::Outbound::Deliver).to receive(:call) do |**kw|
      recorded << kw
      instance_double(Axn::Result, ok?: true)
    end
  end

  describe "to:" do
    it "REPLACES the declared targets rather than merging with them" do
      Axn::Webhooks.emit(:lead_signed, to: "https://one-off.example/hook")

      expect(calls.map { |c| c[:url] }).to eq(["https://one-off.example/hook"])
    end

    it "accepts an Array" do
      Axn::Webhooks.emit(:lead_signed, to: %w[https://a.example/h https://b.example/h])

      expect(calls.map { |c| c[:url] }).to eq(%w[https://a.example/h https://b.example/h])
    end

    it "still requires the event to be declared (it supplies the wire type)" do
      expect { Axn::Webhooks.emit(:nope, to: "https://a.example/h") }
        .to raise_error(Axn::Webhooks::Error, /unknown outbound event/)
    end

    it "validates a one-off URL at emit time, as a rescuable runtime error" do
      expect { Axn::Webhooks.emit(:lead_signed, to: "ftp://nope.example/hook") }
        .to raise_error(Axn::Webhooks::Error, /must be http\(s\)/)
      expect { Axn::Webhooks.emit(:lead_signed, to: [nil]) }
        .to raise_error(Axn::Webhooks::Error, /must be a String/)
    end

    it "leaves the declared targets intact for the next emit" do
      Axn::Webhooks.emit(:lead_signed, to: "https://one-off.example/hook")
      Axn::Webhooks.emit(:lead_signed)

      expect(calls.map { |c| c[:url] })
        .to eq(["https://one-off.example/hook", "https://declared.example/hook"])
    end
  end

  describe "async:" do
    it "async: true with no adapter configured raises, rather than silently running inline" do
      expect { Axn::Webhooks.emit(:lead_signed, async: true) }
        .to raise_error(Axn::Webhooks::Error, /requires an axn async adapter/)
      expect(calls).to be_empty
    end

    it "async: true enqueues when an adapter IS configured" do
      allow(Axn::Webhooks::Outbound::Deliver).to receive(:_async_adapter).and_return(:sidekiq)
      allow(Axn::Webhooks::Outbound::Deliver).to receive(:call_async)

      Axn::Webhooks.emit(:lead_signed, async: true)

      expect(Axn::Webhooks::Outbound::Deliver).to have_received(:call_async).once
    end

    it "async: false runs inline even when an adapter is configured" do
      allow(Axn::Webhooks::Outbound::Deliver).to receive(:_async_adapter).and_return(:sidekiq)
      allow(Axn::Webhooks::Outbound::Deliver).to receive(:call_async)

      Axn::Webhooks.emit(:lead_signed, async: false)

      expect(calls.size).to eq(1)
      expect(Axn::Webhooks::Outbound::Deliver).not_to have_received(:call_async)
    end

    it "async: false does NOT log the degraded-mode warning (the caller asked for sync)" do
      expect(Axn.config.logger).not_to receive(:warn)

      Axn::Webhooks.emit(:lead_signed, async: false)
    end

    it "omitting async: keeps the :auto fallback, warning once" do
      expect(Axn.config.logger).to receive(:warn).with(/synchronously/).once

      Axn::Webhooks.emit(:lead_signed)
    end
  end
end
