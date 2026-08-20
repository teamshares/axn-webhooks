# frozen_string_literal: true

require "base64"

RSpec.describe Axn::Webhooks::Outbound::Deliver do
  after do
    Axn::Webhooks::Outbound.reset!
    described_class._async_adapter = nil
  end

  # Reschedule requires an async adapter to reschedule ONTO (Deliver reschedules itself via
  # call_async) — mirrors dispatch_async_spec.rb's AdapterHandler setup: set the class_attribute
  # directly (no real Sidekiq load) and stub call_async so no real adapter runs.
  def configure_adapter!
    described_class._async_adapter = :sidekiq
  end

  # A recording fake transport; `script` maps call-index -> Response or a raise.
  def fake_transport(*responses)
    Class.new do
      define_method(:calls) { @calls ||= [] }
      define_method(:post) do |url:, body:, headers:|
        calls << { url:, body:, headers: }
        outcome = responses[calls.size - 1] || responses.last
        raise outcome if outcome.is_a?(Class) || outcome.is_a?(Exception)

        outcome
      end
    end.new
  end

  def ok(status, headers = {}, body = nil) = Axn::Webhooks::Outbound::Transport::Response.new(status:, headers:, body:)

  def declare!(transport:, max_attempts: 8, backoff: ->(_n) { 60 }, vendor: nil, user_agent: nil)
    t = transport
    ma = max_attempts
    bo = backoff
    v = vendor
    ua = user_agent
    Axn::Webhooks.outbound do
      sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('secret')}"
      transport t
      max_attempts ma
      backoff bo
      vendor v if v
      user_agent ua if ua
      event :lead_signed, to: ["https://os.example/hook"]
    end
  end

  let(:kwargs) { { url: "https://os.example/hook", webhook_id: "msg_1", body: '{"a":1}', event: "lead_signed" } }

  it "signs per attempt and succeeds on 2xx" do
    transport = fake_transport(ok(202))
    declare!(transport:)

    result = described_class.call(**kwargs)

    expect(result).to be_ok
    headers = transport.calls.first[:headers]
    expect(headers["webhook-id"]).to eq("msg_1")
    expect(headers["webhook-signature"]).to start_with("v1,")
    expect(headers["content-type"]).to eq("application/json")
  end

  it "quietly fails (no reschedule) on a permanent 4xx" do
    transport = fake_transport(ok(422))
    declare!(transport:)
    allow(described_class).to receive(:call_async)

    result = described_class.call(**kwargs)

    expect(result).not_to be_ok
    expect(result.outcome).to be_failure
    expect(result.outcome).not_to be_exception
    expect(described_class).not_to have_received(:call_async)
  end

  it "reschedules with backoff on a retryable 5xx when attempts remain" do
    transport = fake_transport(ok(503))
    declare!(transport:, backoff: ->(n) { n * 100 })
    configure_adapter!
    allow(described_class).to receive(:call_async)

    described_class.call(**kwargs, attempt: 1)

    expect(described_class).to have_received(:call_async).with(
      hash_including(webhook_id: "msg_1", attempt: 2, _async: { wait: 100 }),
    )
  end

  it "honors Retry-After when it exceeds the computed backoff" do
    transport = fake_transport(ok(429, "retry-after" => "300"))
    declare!(transport:, backoff: ->(_n) { 60 })
    configure_adapter!
    allow(described_class).to receive(:call_async)

    described_class.call(**kwargs, attempt: 1)

    expect(described_class).to have_received(:call_async).with(hash_including(_async: { wait: 300 }))
  end

  it "honors Retry-After case-insensitively when a custom transport returns capitalized headers" do
    transport = fake_transport(ok(503, "Retry-After" => "300"))
    declare!(transport:, backoff: ->(_n) { 60 })
    configure_adapter!
    allow(described_class).to receive(:call_async)

    described_class.call(**kwargs, attempt: 1)

    expect(described_class).to have_received(:call_async).with(hash_including(_async: { wait: 300 }))
  end

  it "honors an HTTP-date Retry-After (RFC 7231) by computing the remaining seconds" do
    future = Time.now + 200
    transport = fake_transport(ok(503, "retry-after" => future.httpdate))
    declare!(transport:, backoff: ->(_n) { 1 })
    configure_adapter!
    allow(described_class).to receive(:call_async)

    described_class.call(**kwargs, attempt: 1)

    expect(described_class).to have_received(:call_async) do |**call_kwargs|
      wait = call_kwargs[:_async][:wait]
      expect(wait).to be_within(30).of(200)
      expect(wait).to be > 1 # backoff floor loses to the HTTP-date Retry-After
    end
  end

  it "falls back to backoff (no crash) when Retry-After is unparseable garbage" do
    transport = fake_transport(ok(503, "retry-after" => "not-a-date-or-int"))
    declare!(transport:, backoff: ->(_n) { 42 })
    configure_adapter!
    allow(described_class).to receive(:call_async)

    described_class.call(**kwargs, attempt: 1)

    expect(described_class).to have_received(:call_async).with(hash_including(_async: { wait: 42 }))
  end

  it "reschedules (does not raise) on a retryable network error" do
    transport = fake_transport(Timeout::Error)
    declare!(transport:, backoff: ->(_n) { 60 })
    configure_adapter!
    allow(described_class).to receive(:call_async)

    result = described_class.call(**kwargs, attempt: 1)

    expect(result).to be_ok # rescheduled, current attempt acked
    expect(described_class).to have_received(:call_async).with(hash_including(attempt: 2))
  end

  it "propagates (does not swallow into a second reschedule) when call_async itself raises " \
     "during enqueue, e.g. a Redis/Sidekiq outage" do
    transport = fake_transport(ok(503))
    declare!(transport:, backoff: ->(_n) { 60 })
    configure_adapter!
    allow(described_class).to receive(:call_async).and_raise(Timeout::Error)

    result = described_class.call(**kwargs, attempt: 1)

    # The enqueue failure must propagate as a loud exception outcome (un-acked job -> adapter
    # retries) rather than being caught by the retryable-network rescue and retried again in the
    # SAME attempt (which would be a duplicate enqueue attempt / quiet swallow).
    expect(described_class).to have_received(:call_async).once
    expect(result.outcome).to be_exception
  end

  it "reports once and fails (no reschedule) when retries are exhausted" do
    transport = fake_transport(ok(500))
    declare!(transport:, max_attempts: 3)
    configure_adapter!
    allow(described_class).to receive(:call_async)
    expect(Axn.config).to receive(:on_exception).at_least(:once)
                                                .with(anything, hash_including(action: instance_of(described_class)))

    result = described_class.call(**kwargs, attempt: 3)

    expect(result).not_to be_ok
    expect(described_class).not_to have_received(:call_async)
  end

  it "passes the running Deliver INSTANCE (not the class) through the REAL on_exception path " \
     "at exhaustion" do
    # Regression test for a Codex P2 finding: `report_exhaustion` used to pass `self.class` (the
    # Deliver CLASS) to `Axn.config.on_exception`, breaking axn's documented contract (axn's own
    # internal callers, e.g. executor.rb, always pass the action INSTANCE) -- axn's real
    # `on_exception` uses `action:` to enrich the report (`action.respond_to?(:result) &&
    # action.result...` to resolve the action's own failure detail) and hands `action:` straight
    # through to the configured reporter (e.g. Honeybadger), which may reasonably call
    # instance-only methods (inputs, exposed_data, result, ...) on it. A bare Class object
    # satisfies none of that. Stubbing `on_exception` (as the test above does) only proves it was
    # CALLED, not that it was called with the right thing -- this test wires up a REAL lambda
    # reporter (not a mock) and asserts on what it actually receives, so the assertion is driven by
    # axn's genuine `on_exception` implementation end-to-end, not a stand-in.
    #
    # `on_exception` is a hand-written method (not `attr_accessor`) that takes `(e, action:,
    # context:)` and dispatches to the configured `@on_exception` callable -- there's no plain
    # reader, so we must save/restore the ivar directly rather than calling
    # `Axn.config.on_exception` as a getter (which would raise ArgumentError: no `action:` given).
    captured = []
    original_on_exception = Axn.config.instance_variable_get(:@on_exception)
    Axn.config.on_exception = ->(e, action:, **) { captured << { error: e, action: } }

    begin
      transport = fake_transport(ok(500))
      declare!(transport:, max_attempts: 3)
      configure_adapter!
      allow(described_class).to receive(:call_async)

      described_class.call(**kwargs, attempt: 3)

      expect(captured.size).to eq(1)
      expect(captured.first[:error]).to be_a(Axn::Webhooks::Error)
      expect(captured.first[:error].message).to include("delivery exhausted")
      # The crux of the fix: an INSTANCE, not the class itself.
      expect(captured.first[:action]).to be_an_instance_of(described_class)
    ensure
      Axn.config.instance_variable_set(:@on_exception, original_on_exception)
    end
  end

  it "reports exhaustion only AFTER fail! has settled the result (codex P2)" do
    # Regression test for a Codex P2 finding: `report_exhaustion` used to be called INLINE in
    # `retry_or_exhaust!`, BEFORE `fail!` -- so a reporter reading `action.result` at report time
    # saw a pre-finalized (still-`ok?`) result, undercutting the entire point of handing it the
    # action instance. The fix moves the report into an `on_failure` callback, which axn only
    # dispatches once `@context.__record_exception` has already set `@failure = true` (see
    # executor.rb#with_exception_handling, which stamps the failure BEFORE dispatching :failure
    # callbacks) -- so by the time the reporter runs, `action.result` is a genuine failure.
    #
    # A real lambda reporter (not a mock) captures `action.result.ok?`/`.failure?` at the moment
    # it's invoked, so the assertion is driven by axn's actual callback-ordering semantics, not a
    # stand-in for them.
    captured = []
    original_on_exception = Axn.config.instance_variable_get(:@on_exception)
    Axn.config.on_exception = ->(_e, action:, **) { captured << { ok: action.result.ok?, failure: action.result.outcome.failure? } }

    begin
      transport = fake_transport(ok(500))
      declare!(transport:, max_attempts: 3)
      configure_adapter!
      allow(described_class).to receive(:call_async)

      result = described_class.call(**kwargs, attempt: 3)

      expect(result).not_to be_ok
      expect(captured.size).to eq(1)
      expect(captured.first[:ok]).to be(false)
      expect(captured.first[:failure]).to be(true)
    ensure
      Axn.config.instance_variable_set(:@on_exception, original_on_exception)
    end
  end

  it "does NOT report when failing on a permanent 4xx (no exhaustion) (codex P2)" do
    # The `on_failure`-based report is gated behind `@exhaustion_error` -- a permanent-4xx `fail!`
    # (see `#call`'s `fail!("permanent delivery failure ...")` branch) never sets that ivar, so the
    # `on_failure` callback must fire (fail! always triggers on_failure) but decline to report.
    transport = fake_transport(ok(422))
    declare!(transport:)
    allow(described_class).to receive(:call_async)
    expect(Axn.config).not_to receive(:on_exception)

    result = described_class.call(**kwargs)

    expect(result).not_to be_ok
    expect(result.outcome).to be_failure
  end

  it "lets an unexpected (non-network) transport exception propagate as a loud exception" do
    transport = fake_transport(ArgumentError.new("boom"))
    declare!(transport:)

    result = described_class.call(**kwargs)
    expect(result.outcome).to be_exception
  end

  it "fails quietly (no crash) on a retryable 5xx when NO async adapter is configured, " \
     "instead of raising NotImplementedError from call_async" do
    transport = fake_transport(ok(503))
    declare!(transport:)
    # Deliberately NOT calling configure_adapter! and NOT stubbing call_async — this must exercise
    # the REAL retry_or_exhaust! guard, proving it never reaches axn's call_async (which would raise
    # a ScriptError that escapes axn's StandardError-only exception boundary and crashes the caller).
    expect(Axn.config).to receive(:on_exception).at_least(:once)
                                                .with(anything, hash_including(action: instance_of(described_class)))

    result = nil
    expect do
      result = described_class.call(**kwargs, attempt: 1)
    end.not_to raise_error

    expect(result).not_to be_ok
    expect(result.outcome).to be_failure
    expect(result.outcome).not_to be_exception
  end

  it "carries the vendor through a self-reschedule" do
    transport = fake_transport(ok(503))
    declare!(transport:)
    configure_adapter!
    allow(described_class).to receive(:call_async)

    described_class.call(**kwargs, vendor: :internal, attempt: 1)

    expect(described_class).to have_received(:call_async).with(hash_including(vendor: :internal))
  end

  describe "user-agent" do
    it "defaults to the bare gem/version string" do
      transport = fake_transport(ok(202))
      declare!(transport:)

      described_class.call(**kwargs)

      expect(transport.calls.first[:headers]["user-agent"]).to eq("axn-webhooks/#{Axn::Webhooks::VERSION}")
    end

    it "appends a configured suffix" do
      transport = fake_transport(ok(202))
      declare!(transport:, user_agent: "buyout-app")

      described_class.call(**kwargs)

      expect(transport.calls.first[:headers]["user-agent"]).to eq("axn-webhooks/#{Axn::Webhooks::VERSION} (buyout-app)")
    end

    it "resolves a callable suffix per attempt" do
      calls = 0
      transport = fake_transport(ok(202))
      declare!(transport:, user_agent: lambda {
        calls += 1
        "deploy-#{calls}"
      })

      described_class.call(**kwargs)

      expect(transport.calls.first[:headers]["user-agent"]).to eq("axn-webhooks/#{Axn::Webhooks::VERSION} (deploy-1)")
    end
  end

  describe "permanent-failure messages" do
    it "includes a truncated receiver body" do
      transport = fake_transport(ok(422, {}, "validation failed: uuid missing"))
      declare!(transport:)

      result = described_class.call(**kwargs)

      expect(result.error).to include("HTTP 422")
      expect(result.error).to include("validation failed: uuid missing")
    end

    it "truncates a long receiver body" do
      long_body = "x" * 1000
      transport = fake_transport(ok(422, {}, long_body))
      declare!(transport:)

      result = described_class.call(**kwargs)

      expect(result.error.length).to be < long_body.length
      expect(result.error).to end_with("…")
    end

    it "omits the body suffix entirely when the receiver sent none" do
      transport = fake_transport(ok(422))
      declare!(transport:)

      result = described_class.call(**kwargs)

      expect(result.error).to eq("permanent delivery failure (HTTP 422) for lead_signed to https://os.example/hook")
    end
  end

  describe "retryable status codes" do
    it "retries a 408 Request Timeout" do
      transport = fake_transport(ok(408))
      declare!(transport:)
      configure_adapter!
      allow(described_class).to receive(:call_async)

      result = described_class.call(**kwargs, attempt: 1)

      expect(result).to be_ok
      expect(described_class).to have_received(:call_async)
    end

    it "retries a 425 Too Early" do
      transport = fake_transport(ok(425))
      declare!(transport:)
      configure_adapter!
      allow(described_class).to receive(:call_async)

      result = described_class.call(**kwargs, attempt: 1)

      expect(result).to be_ok
      expect(described_class).to have_received(:call_async)
    end
  end

  describe "transport timeouts" do
    it "passes the built-in Transport's default timeouts through" do
      Axn::Webhooks.outbound do
        sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('secret')}"
        event :lead_signed, to: ["https://os.example/hook"]
      end
      captured = nil
      allow(Axn::Webhooks::Outbound::Transport).to receive(:post) do |**opts|
        captured = opts
        Axn::Webhooks::Outbound::Transport::Response.new(status: 200, headers: {})
      end

      described_class.call(**kwargs)

      expect(captured[:open_timeout]).to eq(5)
      expect(captured[:read_timeout]).to eq(10)
    end

    it "honors a configured timeouts override" do
      Axn::Webhooks.outbound do
        sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('secret')}"
        timeouts open: 1, read: 2
        event :lead_signed, to: ["https://os.example/hook"]
      end
      captured = nil
      allow(Axn::Webhooks::Outbound::Transport).to receive(:post) do |**opts|
        captured = opts
        Axn::Webhooks::Outbound::Transport::Response.new(status: 200, headers: {})
      end

      described_class.call(**kwargs)

      expect(captured[:open_timeout]).to eq(1)
      expect(captured[:read_timeout]).to eq(2)
    end

    it "does NOT pass open_timeout/read_timeout to a custom (non-built-in) transport" do
      transport = fake_transport(ok(202)) # fake_transport's #post declares no timeout kwargs
      declare!(transport:)

      expect { described_class.call(**kwargs) }.not_to raise_error
    end
  end
end
