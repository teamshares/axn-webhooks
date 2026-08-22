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
    allow(Axn::Webhooks::Outbound::Deliver).to receive(:call).and_return(instance_double(Axn::Result, ok?: true))
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
    allow(Axn::Webhooks::Outbound::Deliver).to receive(:call) do |**kw|
      calls << kw
      instance_double(Axn::Result, ok?: true)
    end

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
    allow(Axn::Webhooks::Outbound::Deliver).to receive(:call) do |**kw|
      calls << kw
      instance_double(Axn::Result, ok?: true)
    end

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
    allow(Axn::Webhooks::Outbound::Deliver).to receive(:call) do |**kw|
      calls << kw
      instance_double(Axn::Result, ok?: true)
    end

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
  describe "failed_count" do
    it "counts sync-path deliveries that failed, without failing the emit itself" do
      # Two targets (see the outer `before`): one delivers, one fails.
      results = [instance_double(Axn::Result, ok?: true), instance_double(Axn::Result, ok?: false)]
      allow(Axn::Webhooks::Outbound::Deliver).to receive(:call) { results.shift }

      result = Axn::Webhooks.emit(:lead_signed, data: { lead_id: 42 })

      expect(result).to be_ok # fan-out succeeded; a subscriber being down is not an emit failure
      expect(result.target_count).to eq(2)
      expect(result.failed_count).to eq(1)
    end

    it "is 0 when every sync delivery succeeds" do
      allow(Axn::Webhooks::Outbound::Deliver).to receive(:call).and_return(instance_double(Axn::Result, ok?: true))

      expect(Axn::Webhooks.emit(:lead_signed).failed_count).to eq(0)
    end

    it "is always 0 on the async path, where nothing has failed yet at emit time" do
      allow(Axn::Webhooks::Outbound::Deliver).to receive(:_async_adapter).and_return(:sidekiq)
      allow(Axn::Webhooks::Outbound::Deliver).to receive(:call_async)

      result = Axn::Webhooks.emit(:lead_signed)

      expect(result.failed_count).to eq(0)
      expect(result.target_count).to eq(2)
      expect(Axn::Webhooks::Outbound::Deliver).not_to have_received(:call)
    end
  end

  describe "DB-backed subscribers (PRO-3214)" do
    def declare_with_rows!(rows)
      Axn::Webhooks::Outbound.reset!
      Axn::Webhooks.outbound do
        sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('secret')}"
        subscribers ->(_event) { rows }
        event :lead_closed
      end
    end

    it "threads a Hash row's id to Deliver as subscriber_id" do
      declare_with_rows!([{ url: "https://a.example/hook", id: "17" }])
      calls = []
      allow(Axn::Webhooks::Outbound::Deliver).to receive(:call) do |**kw|
        calls << kw
        instance_double(Axn::Result, ok?: true)
      end

      Axn::Webhooks.emit(:lead_closed)

      expect(calls.first[:subscriber_id]).to eq("17")
    end

    it "leaves subscriber_id nil for a bare String row (today's shape, unchanged)" do
      declare_with_rows!(["https://a.example/hook"])
      calls = []
      allow(Axn::Webhooks::Outbound::Deliver).to receive(:call) do |**kw|
        calls << kw
        instance_double(Axn::Result, ok?: true)
      end

      Axn::Webhooks.emit(:lead_closed)

      expect(calls.first[:subscriber_id]).to be_nil
    end

    # A DB-backed row is IDENTITY ONLY (url + id) -- Subscriber.coerce rejects an unknown Hash key
    # like `secret:`/`headers:` outright (see subscriber_spec.rb), and `enqueue` only ever threads
    # url/webhook_id/body/event/vendor/subscriber_id through to Deliver. Asserted explicitly here
    # because this is the whole point of the design: no credential ever sits in Deliver.call's
    # kwargs, which for the async path means no credential ever sits in the queue backend's payload.
    it "never threads a secret/token/headers key to Deliver, even if a row tried to smuggle one" do
      calls = []
      allow(Axn::Webhooks::Outbound::Deliver).to receive(:call) do |**kw|
        calls << kw
        instance_double(Axn::Result, ok?: true)
      end
      declare_with_rows!([{ url: "https://a.example/hook", id: "17" }])

      Axn::Webhooks.emit(:lead_closed)

      expect(calls.first.keys).to match_array(%i[url webhook_id body event vendor subscriber_id])
    end

    it "exposes deliveries correlating each webhook_id to its url and subscriber_id" do
      declare_with_rows!([{ url: "https://a.example/hook", id: "1" }, { url: "https://b.example/hook", id: "2" }])
      allow(Axn::Webhooks::Outbound::Deliver).to receive(:call).and_return(instance_double(Axn::Result, ok?: true))

      result = Axn::Webhooks.emit(:lead_closed)

      expect(result.deliveries).to match_array([
                                                 { webhook_id: result.webhook_ids[0], url: "https://a.example/hook", subscriber_id: "1" },
                                                 { webhook_id: result.webhook_ids[1], url: "https://b.example/hook", subscriber_id: "2" },
                                               ])
      expect(result.webhook_ids).to eq(result.deliveries.map { |d| d[:webhook_id] })
    end

    it "rejects a malformed row without failing the emit, reports it once, and excludes it from target_count" do
      declare_with_rows!(["https://good.example/hook", { url: nil }])
      allow(Axn::Webhooks::Outbound::Deliver).to receive(:call).and_return(instance_double(Axn::Result, ok?: true))
      reported = []
      allow(Axn.config).to receive(:on_exception) { |error, **kw| reported << { error:, context: kw[:context] } }

      result = Axn::Webhooks.emit(:lead_closed)

      expect(result).to be_ok
      expect(result.target_count).to eq(1)
      expect(result.rejected_count).to eq(1)
      expect(result.rejected.first).to include(reason: a_string_matching(/must be a String/))
      expect(reported.size).to eq(1) # once per emit, not once per rejected row
    end

    it "does not report anything when there are no rejections" do
      declare_with_rows!(["https://good.example/hook"])
      allow(Axn::Webhooks::Outbound::Deliver).to receive(:call).and_return(instance_double(Axn::Result, ok?: true))
      expect(Axn.config).not_to receive(:on_exception)

      result = Axn::Webhooks.emit(:lead_closed)

      expect(result.rejected_count).to eq(0)
      expect(result.rejected).to eq([])
    end
  end

  describe "per-call to: override honors the declared host policy (PRO-3214)" do
    before do
      Axn::Webhooks::Outbound.reset!
      Axn::Webhooks.outbound do
        sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('secret')}"
        allowed_hosts %w[good.example]
        event :lead_signed, to: ["https://good.example/hook"]
      end
    end

    it "raises a rescuable runtime error for a one-off to: URL the allowlist refuses" do
      expect { Axn::Webhooks.emit(:lead_signed, to: "https://evil.example/hook") }
        .to raise_error(Axn::Webhooks::Error, /not allowed/)
    end

    it "still allows a one-off to: URL the allowlist accepts" do
      allow(Axn::Webhooks::Outbound::Deliver).to receive(:call).and_return(instance_double(Axn::Result, ok?: true))

      expect { Axn::Webhooks.emit(:lead_signed, to: "https://good.example/hook") }.not_to raise_error
    end
  end
end
