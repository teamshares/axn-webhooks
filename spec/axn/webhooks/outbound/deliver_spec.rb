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

  def declare!(transport:, max_attempts: 8, backoff: ->(_n) { 60 }, vendor: nil, user_agent: nil,
               headers: nil, sign_block: nil)
    t = transport
    ma = max_attempts
    bo = backoff
    v = vendor
    ua = user_agent
    h = headers
    sb = sign_block
    Axn::Webhooks.outbound do
      if sb
        sign(&sb)
      else
        sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('secret')}"
      end
      transport t
      max_attempts ma
      backoff bo
      vendor v if v
      user_agent ua if ua
      headers h if h
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

  describe "subscriber identity (PRO-3214)" do
    it "defaults subscriber_id to nil -- a declared to: Array (no DB-backed row) has no identity to carry" do
      transport = fake_transport(ok(202))
      declare!(transport:)

      expect { described_class.call(**kwargs) }.not_to raise_error
    end

    # Omitting `subscriber_id:` here would silently drop identity on attempt 2 -- the same class of
    # regression `deliver_spec` already guards for `vendor:` above.
    it "carries subscriber_id through a self-reschedule" do
      transport = fake_transport(ok(503))
      declare!(transport:)
      configure_adapter!
      allow(described_class).to receive(:call_async)

      described_class.call(**kwargs, subscriber_id: "17", attempt: 1)

      expect(described_class).to have_received(:call_async).with(hash_including(subscriber_id: "17"))
    end

    # The whole point of resolving secret/headers PER ATTEMPT (never storing them) is that a
    # re-enqueue -- which persists its kwargs in the queue backend's payload for the life of the
    # retry chain -- carries only the subscriber's IDENTITY, never a credential.
    it "never carries a secret/token/headers key into the re-enqueued job" do
      transport = fake_transport(ok(503))
      declare!(transport:, headers: -> { { "authorization" => "Bearer secret-token" } })
      configure_adapter!
      allow(described_class).to receive(:call_async)

      described_class.call(**kwargs, subscriber_id: "17", attempt: 1)

      expect(described_class).to have_received(:call_async) do |**call_kwargs|
        expect(call_kwargs.keys).to match_array(%i[url webhook_id body event vendor subscriber_id attempt _async])
      end
    end

    it "stamps subscriber_id as a high-cardinality TAG, not a bounded metrics dimension" do
      # A subscriber id off a DB table is unbounded -- axn's `dimension` is the metrics facet and
      # must stay bounded (the same rule Deliver's own `event` dimension and VendorFacet follow);
      # `tag` is the log/trace facet with no metrics-billing cost. Getting this backwards would
      # quietly blow up a metrics backend's cardinality limits the first time a real subscriber
      # table is wired up.
      transport = fake_transport(ok(202))
      declare!(transport:)

      events = []
      callback = ->(*, payload) { events << payload }
      ActiveSupport::Notifications.subscribed(callback, "axn.call") do
        described_class.call(**kwargs, subscriber_id: "17")
      end

      payload = events.find { |e| e[:action].instance_of?(described_class) }
      expect(payload[:tags]).to include(subscriber_id: "17")
      expect(payload[:dimensions]).not_to include(subscriber_id: anything)
    end

    it "includes subscriber_id in the exhaustion report context, so a paged exhaustion names the subscription" do
      transport = fake_transport(ok(500))
      declare!(transport:, max_attempts: 3)
      configure_adapter!
      allow(described_class).to receive(:call_async)

      captured = []
      original_on_exception = Axn.config.instance_variable_get(:@on_exception)
      Axn.config.on_exception = ->(_e, context:, **) { captured << context }

      begin
        described_class.call(**kwargs, subscriber_id: "17", attempt: 3)

        expect(captured.size).to eq(1)
        expect(captured.first).to include(subscriber_id: "17")
      ensure
        Axn.config.instance_variable_set(:@on_exception, original_on_exception)
      end
    end
  end

  describe "per-destination headers (PRO-3214)" do
    it "merges a zero-arity headers callable's Hash into the request" do
      transport = fake_transport(ok(202))
      declare!(transport:, headers: -> { { "x-static" => "1" } })

      described_class.call(**kwargs)

      expect(transport.calls.first[:headers]["x-static"]).to eq("1")
    end

    it "resolves a one-arity headers callable with the Subscriber (url + subscriber_id)" do
      seen = nil
      transport = fake_transport(ok(202))
      declare!(transport:, headers: lambda { |sub|
        seen = sub
        { "authorization" => "Bearer token-for-#{sub.id}" }
      })

      described_class.call(**kwargs, subscriber_id: "17")

      expect(seen).to eq(Axn::Webhooks::Outbound::Subscriber.new(url: "https://os.example/hook", id: "17"))
      expect(transport.calls.first[:headers]["authorization"]).to eq("Bearer token-for-17")
    end

    # Codex P1 finding, round 2: a plain `proc { |sub| ... }` (no default -- NOT a lambda) reports
    # its param as `:opt` via #parameters, same as a genuine default -- a #parameters-based
    # "prefer zero-arg" check can't tell them apart and would call this with nil in place of the
    # subscriber.
    it "still passes the subscriber to a plain Proc (not a lambda) with one param and no default" do
      seen = nil
      transport = fake_transport(ok(202))
      declare!(transport:, headers: proc { |sub|
        seen = sub
        { "authorization" => "Bearer token-for-#{sub&.id}" }
      })

      described_class.call(**kwargs, subscriber_id: "17")

      expect(seen).to eq(Axn::Webhooks::Outbound::Subscriber.new(url: "https://os.example/hook", id: "17"))
    end

    it "adds nothing when headers is not declared (default nil)" do
      transport = fake_transport(ok(202))
      declare!(transport:)

      described_class.call(**kwargs)

      expect(transport.calls.first[:headers].keys).to match_array(%w[webhook-id webhook-timestamp webhook-signature content-type user-agent])
    end

    # Codex P2 finding, round 5: a `headers` resolver returning something that ISN'T a Hash at
    # all (a permanent misconfiguration, e.g. it forgot to wrap the result, or a conditional
    # returned `false`) would otherwise raise NoMethodError from unconditional iteration -- an
    # UNEXPECTED exception the async adapter reads as a transient crash and retries forever, even
    # though the malformed return value will never become valid on retry.
    it "drops (with a warning) the whole headers result when it isn't a Hash, instead of raising mid-delivery" do
      transport = fake_transport(ok(202))
      declare!(transport:, headers: -> { false })
      expect(Axn.config.logger).to receive(:warn)

      result = nil
      expect { result = described_class.call(**kwargs) }.not_to raise_error
      expect(result).to be_ok
    end

    # The generalized MANAGED_HEADERS hazard (Codex, on HmacSigner's own header:/timestamp_header:):
    # Ruby Hash keys are case-SENSITIVE so a differently-cased duplicate survives a plain `.merge`,
    # but Net::HTTP is case-INSENSITIVE and the LATER assignment wins -- so a same-position .merge
    # would silently ship a subscriber-controlled "Content-Type" over the real one and nothing would
    # ever say so. Validating names against merge order alone would fail exactly this silently.
    it "drops (with a warning) a custom header colliding with a Deliver-managed header, case-insensitively" do
      transport = fake_transport(ok(202))
      declare!(transport:, headers: -> { { "Content-Type" => "text/evil", "CONTENT-TYPE" => "also-evil" } })
      expect(Axn.config.logger).to receive(:warn).with(/dropping custom header/i).twice

      described_class.call(**kwargs)

      expect(transport.calls.first[:headers]["content-type"]).to eq("application/json")
    end

    # Codex P2 finding, round 9: Net::HTTP silently REWRITES both of these on the built-in
    # transport, AFTER a caller's headers are applied -- Content-Length is regenerated from the
    # body, Transfer-Encoding is deleted outright (see Transport::RESERVED_HEADERS). A signer/
    # subscriber-controlled header under either name would otherwise pass every check here, only
    # to never actually leave the process -- the delivery reports success, but the receiver never
    # sees the configured header. `sign :hmac`'s own header-name validation already treats these
    # as reserved (unconditionally, not only for the built-in transport); Deliver's own collision
    # check should be no less strict.
    it "drops (with a warning) a custom header colliding with a Transport-reserved name, case-insensitively" do
      transport = fake_transport(ok(202))
      declare!(transport:, headers: -> { { "Content-Length" => "999", "TRANSFER-ENCODING" => "chunked" } })
      expect(Axn.config.logger).to receive(:warn).with(/dropping custom header/i).twice

      described_class.call(**kwargs)

      expect(transport.calls.first[:headers]).not_to include("Content-Length", "TRANSFER-ENCODING")
    end

    it "drops (with a warning) a custom header colliding with a header the active SIGNER just emitted, case-insensitively" do
      # Standard Webhooks emits "webhook-signature" -- a subscriber row supplying a differently-cased
      # duplicate must not be the thing that ships, or the receiver silently gets an unverifiable
      # delivery with no error anywhere.
      transport = fake_transport(ok(202))
      declare!(transport:, headers: -> { { "Webhook-Signature" => "not-the-real-one" } })
      expect(Axn.config.logger).to receive(:warn).with(/dropping custom header.*Webhook-Signature/)

      described_class.call(**kwargs)

      expect(transport.calls.first[:headers]["webhook-signature"]).to start_with("v1,")
    end

    # Codex P2 finding, round 11: `reserved = MANAGED_HEADERS + Transport::RESERVED_HEADERS +
    # signer_headers.keys` inherits whatever key TYPE the active signer's Hash uses -- a custom
    # `sign` block returning Symbol keys (`{ "X-Signature": "..." }`, the most natural way to write
    # a Hash literal in Ruby) puts a Symbol into `reserved`. `reserved.any? { |r| r.casecmp?(key) }`
    # then compares that Symbol against `key`, which is always a String here (guarded above) --
    # `Symbol#casecmp?` returns `nil` (not a match, and not an error) for a String argument even
    # when case-identical, so the collision silently goes undetected and BOTH headers ship: the
    # signer's real one AND the subscriber-controlled duplicate, letting a `headers` resolver spoof
    # a same-named header the signer already claimed.
    it "still detects (and drops) a collision when the SIGNER's own header keys are Symbols, not Strings" do
      transport = fake_transport(ok(202))
      declare!(transport:,
               sign_block: ->(**) { { "X-Signature": "sig-from-signer" } },
               headers: -> { { "X-Signature" => "not-the-real-one" } })
      expect(Axn.config.logger).to receive(:warn).with(/dropping custom header.*X-Signature/)

      described_class.call(**kwargs)

      headers = transport.calls.first[:headers]
      expect(headers.values).not_to include("not-the-real-one")
      expect(headers[:"X-Signature"]).to eq("sig-from-signer")
    end

    it "drops (with a warning) a non-String key or value instead of raising mid-delivery" do
      transport = fake_transport(ok(202))
      declare!(transport:, headers: -> { { sym_key: "v", "str_key" => 123 } })
      expect(Axn.config.logger).to receive(:warn).twice

      result = nil
      expect { result = described_class.call(**kwargs) }.not_to raise_error
      expect(result).to be_ok
      expect(transport.calls.first[:headers]).not_to include("sym_key", "str_key")
    end

    # Codex P1 finding, round 2: `{ Authorization: "Bearer live-token" }` is the single most
    # natural way to write a headers resolver in Ruby (symbol-keyed Hash literal) -- the OLD
    # non-String-key warning logged `value.inspect` unconditionally, copying the live bearer token
    # straight into application logs the very first time anyone wrote it that way.
    it "never logs a header's VALUE when dropping it for a non-String key" do
      transport = fake_transport(ok(202))
      declare!(transport:, headers: -> { { Authorization: "Bearer live-token-do-not-leak" } })

      warned = []
      allow(Axn.config.logger).to receive(:warn) { |msg| warned << msg }

      described_class.call(**kwargs)

      expect(warned).not_to be_empty
      expect(warned.join).not_to include("live-token-do-not-leak")
    end

    # Codex P1 finding: the built-in Transport (net/http) rejects CR/LF in a header VALUE, but a
    # non-empty String KEY containing CR/LF (or a space/colon) passed the old check unchanged --
    # `request[key] = value` serializes whatever key it's handed straight into the wire header
    # line, so a subscriber-controlled `headers` resolver could inject an entirely separate header.
    # This is the exact grammar `sign :hmac`'s own `header:`/`timestamp_header:` are already
    # validated against (Signer::HEADER_NAME) -- a custom header name now goes through the same
    # check.
    it "drops (with a warning) a custom header key that isn't a valid HTTP field-name token" do
      transport = fake_transport(ok(202))
      declare!(transport:, headers: -> { { "X-Foo\r\nX-Injected: evil" => "value", "X Bad" => "v" } })
      expect(Axn.config.logger).to receive(:warn).twice

      described_class.call(**kwargs)

      headers = transport.calls.first[:headers]
      expect(headers.keys.join).not_to include("\r\n")
      expect(headers).not_to include("X Bad")
    end

    # Codex P2 finding, round 4: the built-in Transport's underlying Net::HTTP raises
    # `ArgumentError: header field value cannot include CR/LF` for a header VALUE containing
    # CR/LF (unlike a malformed KEY, which it accepts and serializes verbatim -- see the round-1
    # finding above). Left unvalidated, a permanently-malformed subscriber value would raise an
    # UNEXPECTED exception on every attempt, which the async adapter reads as a transient crash
    # and retries forever -- rather than being dropped like every other malformed header entry.
    it "drops (with a warning) a custom header value containing CR/LF instead of raising mid-delivery" do
      transport = fake_transport(ok(202))
      declare!(transport:, headers: -> { { "x-custom" => "line1\r\nline2" } })
      expect(Axn.config.logger).to receive(:warn)

      result = nil
      expect { result = described_class.call(**kwargs) }.not_to raise_error
      expect(result).to be_ok
      expect(transport.calls.first[:headers]).not_to include("x-custom")
    end

    it "lets a headers callable that raises propagate as an unexpected exception (adapter retries the un-acked job)" do
      transport = fake_transport(ok(202))
      declare!(transport:, headers: -> { raise "header store is down" })

      result = described_class.call(**kwargs)

      expect(result.outcome).to be_exception
    end

    # Codex P2 finding, round 15: `signed_headers` builds `subscriber = Subscriber.new(url:,
    # id: subscriber_id)` from Deliver's OWN `url` -- reconstructed from the job payload on every
    # attempt, an ordinary mutable String, never the frozen snapshot `TargetPolicy.check!` produced
    # at resolution time (that snapshot lives only in `Emit`'s Resolution; `Deliver` never sees it
    # again). Ruby's hash-literal evaluates `url:` (in `post_args`) and `Subscriber.new(url:, ...)`
    # (inside `signed_headers`) against the SAME object -- so a subscriber-aware secret/headers
    # resolver that mutates `subscriber.url` IN PLACE would silently swap the destination `post_args`
    # already captured, sending the request to a host that was never checked against
    # `allowed_hosts`/`allow_url` at all (that check runs once, at resolution time). This must fail
    # LOUDLY (a frozen string raising) rather than silently deliver somewhere unvalidated.
    it "never lets a subscriber-aware sign/headers resolver mutate the delivery's own URL in place" do
      transport = fake_transport(ok(202))
      declare!(transport:, sign_block: lambda { |subscriber:, **|
        subscriber.url << "-mutated-by-signer"
        { "X-Signature" => "sig" }
      })

      result = described_class.call(**kwargs)

      expect(result.outcome).to be_exception
      expect(transport.calls).to be_empty
    end
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

    it "scrubs a long binary receiver body instead of raising Encoding::CompatibilityError" do
      # net/http labels response bodies ASCII-8BIT regardless of actual content; a long body with
      # non-ASCII bytes hits the ellipsis-append path that previously mixed encodings.
      binary_body = ("\xFF\xFE" * 300).dup.force_encoding(Encoding::ASCII_8BIT)
      transport = fake_transport(ok(422, {}, binary_body))
      declare!(transport:)

      result = described_class.call(**kwargs)

      expect(result.error).to include("HTTP 422")
      expect(result.error).to end_with("…")
    end

    it "truncates an ASCII-8BIT body without leaving an invalid byte sequence when the cut splits a multibyte character" do
      # Labeled ASCII-8BIT (as net/http does) but holding valid UTF-8 multibyte text — byte 500 lands
      # mid-character, so a raw byteslice alone would leave a dangling invalid sequence.
      long_body = ("é" * 1000).dup.force_encoding(Encoding::ASCII_8BIT)
      transport = fake_transport(ok(422, {}, long_body))
      declare!(transport:)

      result = described_class.call(**kwargs)

      expect(result.error).to end_with("…")
      expect { result.error.encode(Encoding::UTF_8) }.not_to raise_error
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
