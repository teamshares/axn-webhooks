# frozen_string_literal: true

require "base64"
require "json"

RSpec.describe "Axn::Webhooks.emit" do
  after do
    Axn::Webhooks::Outbound.reset!
    Axn::Webhooks.reset_config!
  end

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

  it "reports an unknown event through axn's own exception reporting, not a bare raise ahead of the action" do
    # Regression: `self.emit` used to resolve `vendor_for(event)` BEFORE calling `Emit.call!`, so an
    # unknown event raised outside the Axn action entirely -- same error class/message, but axn's
    # executor (and its on_exception reporting) never ran. Assert on the reporter call, not just the
    # raised error, so this can't pass for the wrong reason again.
    reported = []
    allow(Axn.config).to receive(:on_exception) { |error, **| reported << error }

    expect { Axn::Webhooks.emit(:not_a_real_event, data: {}) }
      .to raise_error(Axn::Webhooks::Error, /unknown outbound event/)

    expect(reported.map(&:message)).to include(a_string_matching(/unknown outbound event/))
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

  it "warns ONCE per emit (not once per target) when no async adapter is configured" do
    # This event fans out to 2 targets (see the `before` block) — the warning is a single
    # configuration fact, not a per-delivery one, so a high-fan-out event mustn't spam N warn lines.
    expect(Axn.config.logger).to receive(:warn).with(/synchronous|no async adapter/i).once
    Axn::Webhooks.emit(:lead_signed, data: {})
  end

  it "exposes the resolved webhook_ids and target_count" do
    calls = []
    allow(Axn::Webhooks::Outbound::Deliver).to receive(:call) { |**kw| calls << kw }

    result = Axn::Webhooks.emit(:lead_signed, data: {})

    expect(result.webhook_ids).to match_array(calls.map { |c| c[:webhook_id] })
    expect(result.target_count).to eq(2)
  end

  it "passes the outbound block's configured vendor down to Deliver" do
    Axn::Webhooks::Outbound.reset!
    Axn::Webhooks.outbound do
      sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('secret')}"
      vendor :internal
      event :lead_signed, to: ["https://a.example/hook"]
    end
    calls = []
    allow(Axn::Webhooks::Outbound::Deliver).to receive(:call) { |**kw| calls << kw }

    Axn::Webhooks.emit(:lead_signed, data: {})

    expect(calls.first[:vendor]).to eq(:internal)
  end

  it "stamps :vendor on Emit's OWN dimension, not only on the Deliver it enqueues" do
    # Regression: resolving `@vendor` inside `#call` (see the unknown-event fix above) is too late
    # for axn's own instrumentation — `dimension`/`tag` facets resolve input-phase, i.e. EAGERLY
    # BEFORE the body runs, so they'd see `@vendor` still unset and stamp nil (Codex P2 finding).
    Axn::Webhooks::Outbound.reset!
    Axn::Webhooks.outbound do
      sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('secret')}"
      vendor :internal
      event :lead_signed, to: ["https://a.example/hook"]
    end
    Axn::Webhooks.configure { |c| c.vendor_facet = :dimension }

    events = []
    callback = ->(*, payload) { events << payload }
    ActiveSupport::Notifications.subscribed(callback, "axn.call") do
      Axn::Webhooks.emit(:lead_signed, data: {})
    end

    payload = events.find { |e| e[:action].instance_of?(Axn::Webhooks::Outbound::Emit) }
    expect(payload[:dimensions]).to include(vendor: "internal")
  end
end
