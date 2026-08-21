# PRO-3211 outbound follow-ups Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the five remaining PRO-3211 items in axn-webhooks — `Config` immutability, an `emit` `failed_count`, a `sign :hmac` preset, per-emit `to:`/`async:` overrides, and nested `inbound` `endpoint` sugar.

**Architecture:** Five independent changes to an existing gem; none depends on another, so tasks may be reordered or dropped individually. Ordered here by ascending size. Every change is additive to the public DSL except Task 2, which alters one internal method's return contract (and the specs that stub it).

**Tech Stack:** Ruby 3.2, RSpec, RuboCop, the `axn` gem (`Axn::Configurable`, `Axn::Result`, `call_async`). No new runtime dependencies.

**Spec:** `internal-docs/specs/2026-08-20-axn-webhooks-outbound-follow-ups-design.md`

## Global Constraints

- **TDD, always**: failing test first, watch it fail, then implement. (AGENTS.md)
- **`bundle exec rake` (specs + rubocop) must pass before any task is done.** RuboCop is part of the default rake task and CI; a task is not complete with offenses outstanding.
- **Works outside Rails** — guard any `Rails`/`ActiveRecord`/`ActiveJob` reference with `defined?(...)`. None of these tasks should need one.
- **CHANGELOG every user-visible change** under `## [Unreleased]`. Tasks 2–5 are user-visible; Task 1 is user-visible as a behavior guarantee.
- **README every user-visible DSL change** (Tasks 2–5).
- **Error-class split, used throughout this gem**: a pure declaration mistake decided once at boot raises plain `ArgumentError`; a condition a caller might legitimately rescue at runtime raises `Axn::Webhooks::Error`. Follow it exactly — the tasks below say which applies where.
- **Never interpolate a secret into an error message.** `Signer::StandardWebhooksSigner#describe_secret` is the pattern to copy.
- Specs live under `spec/axn/webhooks/`; `.rspec` already requires `spec_helper`.
- Every outbound spec that declares an `outbound` block MUST have `after { Axn::Webhooks::Outbound.reset! }`; every inbound spec that registers MUST have `after { Axn::Webhooks::Inbound.reset! }`. The registries are process-global.

---

### Task 1: `Config` immutability

Makes `config.rb:6`'s "immutable" comment true. The load-bearing discovery: `Axn::Configurable` lazily memoizes a **static** default into an ivar on first read, so freezing before that read makes the *reader* raise `FrozenError`. Settings with a dynamic default (`backoff`, `transport`, declared as `-> { … }`) escape, which is exactly why the fix must not rely on them.

**Files:**
- Modify: `lib/axn/webhooks/outbound/config.rb`
- Modify: `lib/axn/webhooks/outbound.rb:14-32`
- Create: `spec/axn/webhooks/outbound/config_immutability_spec.rb`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `Axn::Webhooks::Outbound::Config::SETTING_NAMES` (frozen `Array<Symbol>`, the seven Configurable settings) and `Config.url_problem(url) -> String | nil`, a class method returning a human-readable problem description or `nil` when the URL is a valid http(s) String. Task 4 calls `url_problem`.

- [ ] **Step 1: Write the failing test**

Create `spec/axn/webhooks/outbound/config_immutability_spec.rb`:

```ruby
# frozen_string_literal: true

require "base64"

RSpec.describe "Axn::Webhooks::Outbound::Config immutability" do
  after { Axn::Webhooks::Outbound.reset! }

  def declare_minimal!
    Axn::Webhooks.outbound do
      sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('s')}"
      event :lead_signed, to: ["https://a.example/hook"]
    end
    Axn::Webhooks::Outbound.config
  end

  it "is frozen once declared" do
    expect(declare_minimal!).to be_frozen
  end

  it "reads every setting after freezing, including ones the block never assigned" do
    # Regression guard for the whole design: Axn::Configurable memoizes a STATIC default into an
    # ivar on first read, so a Config frozen before that read raises FrozenError from the READER,
    # not from a writer. Only backoff/transport escape (dynamic `-> { … }` defaults, recomputed
    # rather than memoized) — which is why this asserts on all seven rather than spot-checking.
    config = declare_minimal!

    expect(config.max_attempts).to eq(8)
    expect(config.backoff.call(1)).to be_a(Integer)
    expect(config.transport).to eq(Axn::Webhooks::Outbound::Transport)
    expect(config.vendor).to be_nil
    expect(config.user_agent).to be_nil
    expect(config.open_timeout).to eq(5)
    expect(config.read_timeout).to eq(10)
  end

  it "rejects mutation of a setting" do
    expect { declare_minimal!.max_attempts = 3 }.to raise_error(FrozenError)
  end

  it "freezes the events map, each event spec, and a statically-declared to: array" do
    events = declare_minimal!.instance_variable_get(:@events)

    expect(events).to be_frozen
    expect(events[:lead_signed]).to be_frozen
    expect(events[:lead_signed][:to]).to be_frozen
  end

  it "does NOT freeze caller-supplied callables" do
    resolver = ->(_event) { ["https://x.example/hook"] }
    signer = ->(id:, timestamp:, body:) { { "x-sig" => "#{id}#{timestamp}#{body}" } }

    Axn::Webhooks.outbound do
      sign(&signer)
      subscribers resolver
      event :lead_closed
    end

    expect(resolver).not_to be_frozen
    expect(signer).not_to be_frozen
    expect(Axn::Webhooks::Outbound.config.signer).not_to be_frozen
  end

  it "still resolves targets and still raises on an unknown event" do
    config = declare_minimal!

    expect(config.targets_for(:lead_signed)).to eq(["https://a.example/hook"])
    expect(config.wire_type(:lead_signed)).to eq("lead_signed")
    expect(config.vendor_for(:lead_signed)).to be_nil
    expect { config.targets_for(:nope) }.to raise_error(Axn::Webhooks::Error, /unknown outbound event/)
  end

  it "delivers end-to-end against a frozen config" do
    posted = []
    stub_transport = Class.new do
      define_singleton_method(:post) do |url:, body:, headers:, **|
        posted << { url:, headers: }
        Axn::Webhooks::Outbound::Transport::Response.new(status: 200, headers: {})
      end
    end

    Axn::Webhooks.outbound do
      sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('s')}"
      transport stub_transport
      event :lead_signed, to: ["https://a.example/hook"]
    end

    result = Axn::Webhooks.emit(:lead_signed, data: { lead_id: 1 })

    expect(result).to be_ok
    expect(posted.map { |p| p[:url] }).to eq(["https://a.example/hook"])
  end

  it "serializes install and reset! behind a mutex" do
    # Not a race test (unwinnable deterministically) — asserts the lock exists and that a
    # concurrent install cannot interleave with the nil-check that logs the replacement warning.
    expect(Axn::Webhooks::Outbound.instance_variable_get(:@mutex)).to be_a(Mutex)
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bundle exec rspec spec/axn/webhooks/outbound/config_immutability_spec.rb`

Expected: FAIL. "is frozen once declared" fails (`expected #<Config> to be frozen`), "rejects mutation" fails (no `FrozenError` raised), the events-frozen and mutex examples fail. The "reads every setting" and "still resolves" examples PASS at this point — they are regression guards for what Step 3 must not break.

- [ ] **Step 3: Freeze the Config**

In `lib/axn/webhooks/outbound/config.rb`, add the constant next to the other constants at the top of the class body (after `DEFAULT_READ_TIMEOUT = 10`):

```ruby
        # Every Configurable setting declared below. Read once in `initialize` before freezing:
        # Configurable memoizes a STATIC default into an ivar on first read, so a frozen Config
        # would otherwise raise FrozenError from the reader of any setting the `outbound` block
        # never explicitly assigned. `backoff`/`transport` escape only because their defaults are
        # dynamic (`-> { … }`) and recomputed per read — an inconsistency to design around, not
        # rely on.
        SETTING_NAMES = %i[max_attempts backoff transport vendor user_agent open_timeout read_timeout].freeze
```

Replace the last line of `initialize` (currently `@events.each { |name, spec| validate_event!(name, spec) }`) with:

```ruby
          @events.each { |name, spec| validate_event!(name, spec) }

          deep_freeze!
```

Add to the `private` section:

```ruby
        # Freezes the CONTAINERS we own, never the caller's objects: a `to:` resolver, the signer,
        # an injected transport and a `user_agent` callable all stay mutable — they belong to the
        # app, and freezing them could break a memoizing resolver. A statically-declared `to:`
        # Array is ours once validated, so it freezes.
        def deep_freeze!
          SETTING_NAMES.each { |name| public_send(name) }
          @events.each_value do |spec|
            spec[:to].freeze if spec[:to].is_a?(Array)
            spec.freeze
          end
          @events.freeze
          freeze
        end
```

- [ ] **Step 4: Extract the shared URL check**

Still in `config.rb`. Task 4 needs the same http(s) check at emit time but must raise a different error class, so lift the predicate out of `validate_url!` into a class method. Add above `def initialize` (public):

```ruby
        # The problem with `url` as an outbound target, or nil when there is none. A predicate
        # rather than a raiser, because its two callers disagree on the error class: a declaration
        # mistake at boot is an ArgumentError (below), while a bad one-off `emit(to:)` URL is an
        # Axn::Webhooks::Error a caller may rescue at runtime (see Outbound::Emit).
        def self.url_problem(url)
          # A non-String (e.g. a `URI`) would parse fine via `#to_s`, but the ORIGINAL object is
          # what reaches `Deliver`, which `expects :url, type: String` and rejects. Require a
          # String outright rather than normalizing.
          return "must be a String (got #{url.class})" unless url.is_a?(String)

          uri = URI.parse(url)
          return nil if %w[http https].include?(uri.scheme) && !uri.host.to_s.empty?

          "#{url.inspect} must be http(s)"
        rescue URI::InvalidURIError
          "#{url.inspect} is not a valid URL"
        end
```

Replace the whole existing private `validate_url!` method body with:

```ruby
        def validate_url!(name, url)
          problem = self.class.url_problem(url)
          return if problem.nil?

          raise ArgumentError, "outbound event #{name.inspect} `to:` URL #{problem}"
        end
```

Note the message shape changes slightly (`… \`to:\` URL must be a String (got NilClass)`). Check `spec/axn/webhooks/outbound/dsl_spec.rb` for examples asserting on those strings and update the expectations to match if any fail.

- [ ] **Step 5: Add the install mutex**

In `lib/axn/webhooks/outbound.rb`, replace the `module Outbound` body:

```ruby
    module Outbound
      @config = nil
      # Guards install/reset! only. `config` READS stay unsynchronized: what's published is a
      # frozen Config, so a reader either sees the old one or the new one and never a half-built
      # object — and `config` is read on every delivery attempt, where a lock would be real
      # overhead protecting nothing.
      @mutex = Mutex.new

      class << self
        def install(config)
          @mutex.synchronize do
            unless @config.nil?
              Axn.config.logger.warn(
                "[axn-webhooks] a second `Axn::Webhooks.outbound` block replaces the first — only one outbound declaration is active at a time",
              )
            end

            @config = config
          end
        end

        def reset! = @mutex.synchronize { @config = nil }

        def config
          @config || raise(Axn::Webhooks::Error, "no `outbound` block declared — call Axn::Webhooks.outbound { … } at boot")
        end
      end
    end
```

- [ ] **Step 6: Run the full suite**

Run: `bundle exec rake`

Expected: PASS, no RuboCop offenses. If `Metrics/AbcSize` or `Metrics/MethodLength` fires on `install`, extract the warning into a private `warn_replacement` method rather than adding an inline disable.

- [ ] **Step 7: CHANGELOG**

Add under `## [Unreleased]`, in a `### Changed (Outbound)` section (create it if absent):

```markdown
- **`Outbound::Config` is now genuinely frozen**, making good on the "immutable" claim in its own doc
  comment. Freezing naively would have broken reads: `Axn::Configurable` memoizes a static default
  into an ivar on first read, so any setting an `outbound` block never assigned (`max_attempts`,
  `vendor`, `user_agent`, `open_timeout`, `read_timeout`) raised `FrozenError` **from the reader**.
  `Config#initialize` now materializes all seven settings before freezing itself, the events map and
  each event spec. Caller-supplied objects — the signer, a `to:` resolver, an injected transport —
  are deliberately left mutable. `Outbound.install`/`reset!` are serialized behind a mutex; `config`
  reads stay lock-free, which is safe precisely because what they publish is frozen.
```

- [ ] **Step 8: Commit**

```bash
git add lib/axn/webhooks/outbound/config.rb lib/axn/webhooks/outbound.rb \
        spec/axn/webhooks/outbound/config_immutability_spec.rb CHANGELOG.md
git commit -m "feat: freeze Outbound::Config, serialize install"
```

---

### Task 2: `emit` exposes `failed_count`

`Emit`'s fan-out calls `Deliver.call(**)` on the no-adapter sync path and throws the result away, so a failed delivery still leaves `emit` `ok` with the target counted as delivered.

**Files:**
- Modify: `lib/axn/webhooks/outbound/emit.rb`
- Modify: `spec/axn/webhooks/outbound/emit_spec.rb` (stubs must now return a result)
- Modify: `spec/axn/webhooks/outbound/runtime_subscribers_spec.rb` (same)
- Modify: `README.md`, `CHANGELOG.md`

**Interfaces:**
- Consumes: nothing.
- Produces: `Emit` exposes `failed_count` (`Integer`, default `0`). `Emit#enqueue(**) -> Boolean` — true when the delivery is not known to have failed. Task 4 modifies both.

- [ ] **Step 1: Write the failing test**

Append to `spec/axn/webhooks/outbound/emit_spec.rb` (inside the existing top-level `describe`):

```ruby
  describe "failed_count" do
    it "counts sync-path deliveries that failed, without failing the emit itself" do
      # Two targets (see the outer `before`): one delivers, one fails.
      results = [instance_double(Axn::Result, ok?: true), instance_double(Axn::Result, ok?: false)]
      allow(Axn::Webhooks::Outbound::Deliver).to receive(:call) { results.shift }

      result = Axn::Webhooks.emit(:lead_signed, data: { lead_id: 42 })

      expect(result).to be_ok            # fan-out succeeded; a subscriber being down is not an emit failure
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bundle exec rspec spec/axn/webhooks/outbound/emit_spec.rb -e failed_count`

Expected: FAIL with `undefined method 'failed_count'` on the result (axn raises `Axn::OutboundValidationError`/`NoMethodError` for an undeclared exposure).

- [ ] **Step 3: Implement**

In `lib/axn/webhooks/outbound/emit.rb`, add below the existing `exposes :target_count` line:

```ruby
        # Sync fallback only: how many of `target_count` deliveries came back failed. ALWAYS 0 on
        # the async path — nothing has failed at emit time there; failures happen later, and
        # `Deliver` reports them itself (exhaustion via on_exception, a permanent 4xx via its own
        # result). `nil`-when-async would be more honest and would turn every
        # `result.failed_count > 0` into a NoMethodError, so the footgun costs more than the
        # precision buys.
        exposes :failed_count, type: Integer, default: 0
```

Replace `#call`:

```ruby
        def call
          config = Axn::Webhooks::Outbound.config
          type = config.wire_type(event)
          warn_sync_fallback(type) unless async_configured?

          ids = []
          failed = 0
          config.targets_for(event).each do |url|
            id = Envelope.new_id
            body = Envelope.build(id:, type:, data:)
            failed += 1 unless enqueue(url:, webhook_id: id, body:, event: type, vendor:)
            ids << id
          end
          expose(webhook_ids: ids, target_count: ids.size, failed_count: failed)
        end
```

Replace `#enqueue`:

```ruby
        # Async when an adapter is configured for Deliver, else a warned best-effort sync fallback
        # (no cross-process retries). Presence check only — never branches on adapter type.
        # Returns whether the delivery is (so far) not-failed: an enqueue can't know the eventual
        # outcome, so it always counts as not-failed; the sync path reads Deliver's own result.
        def enqueue(**)
          if async_configured?
            Deliver.call_async(**)
            true
          else
            Deliver.call(**).ok?
          end
        end
```

- [ ] **Step 4: Fix the stubs this breaks**

`Deliver.call(**).ok?` means every spec stubbing `Deliver.call` must return something answering `ok?`. A stub returning `nil` (or an Array, from a recording block) now raises `NoMethodError`.

In `spec/axn/webhooks/outbound/emit_spec.rb`, change the `before` block's bare stub:

```ruby
    allow(Axn::Webhooks::Outbound::Deliver).to receive(:call).and_return(instance_double(Axn::Result, ok?: true))
```

and every recording stub of the form `receive(:call) { |**kw| calls << kw }` to return a result:

```ruby
    allow(Axn::Webhooks::Outbound::Deliver).to receive(:call) do |**kw|
      calls << kw
      instance_double(Axn::Result, ok?: true)
    end
```

Apply the same change to the two recording stubs in `spec/axn/webhooks/outbound/runtime_subscribers_spec.rb` (the `before` block) — grep for `receive(:call)` across `spec/` and fix every outbound one.

Run: `grep -rn "receive(:call)" spec/ | grep -i deliver`

- [ ] **Step 5: Run the full suite**

Run: `bundle exec rake`

Expected: PASS, no offenses. If `Metrics/AbcSize` fires on the longer `#call`, extract the loop body into a private `enqueue_target(url, type:)` returning `[id, ok]` rather than adding an inline disable.

- [ ] **Step 6: README**

In the outbound section, after the bullet beginning `* **Fan-out**:`, add:

```markdown
* **`failed_count`** counts deliveries that came back failed — but **only on the synchronous
  fallback path**, and it is **always `0` when an async adapter is configured**, because at `emit`
  time nothing has failed yet: the deliveries are enqueued, and a later failure is reported by
  `Deliver` itself (exhaustion via `on_exception`, a permanent 4xx via its own result). `emit`'s
  result stays `ok` even when every delivery failed — fan-out succeeded, and a subscriber being down
  is not an emit failure. `target_count - failed_count` is the sync-path success count.
```

- [ ] **Step 7: CHANGELOG**

```markdown
- **`emit` now exposes `failed_count`.** The synchronous fallback path called `Deliver.call` and
  discarded the result, so a failed delivery still left `emit` `ok` with the target counted as
  delivered. `failed_count` is always `0` on the async path (nothing has failed at emit time), and
  `emit`'s own result deliberately stays `ok` regardless — the count is the surface, not the outcome.
```

- [ ] **Step 8: Commit**

```bash
git add lib/axn/webhooks/outbound/emit.rb spec/axn/webhooks/outbound/ README.md CHANGELOG.md
git commit -m "feat: expose failed_count from emit's sync fallback path"
```

---

### Task 3: `sign :hmac` preset

**Files:**
- Modify: `lib/axn/webhooks/outbound/signer.rb`
- Create: `spec/axn/webhooks/outbound/hmac_signer_spec.rb`
- Modify: `spec/axn/webhooks/outbound/integration_spec.rb` (round-trip against `verify :hmac`)
- Modify: `README.md`, `CHANGELOG.md`

**Interfaces:**
- Consumes: `Axn::Webhooks::Signature.compute(secret:, payload:, digest:, encoding:)`; `Outbound::CallableArity.accepts?(callable, count)`.
- Produces: `Signer::HmacSigner`, reachable as `sign :hmac, secret:, header:, digest:, encoding:, prefix:, signing_string:, timestamp_header:`. Like every signer it responds to `call(id:, timestamp:, body:) -> Hash` (it ignores `id:`).

- [ ] **Step 1: Write the failing test**

Create `spec/axn/webhooks/outbound/hmac_signer_spec.rb`:

```ruby
# frozen_string_literal: true

RSpec.describe Axn::Webhooks::Outbound::Signer do
  def build(**opts)
    described_class.build(strategy: :hmac, opts:, block: nil)
  end

  describe "the minimal form" do
    it "emits one hex sha256 header over the raw body" do
      headers = build(secret: "s3kr1t", header: "X-Signature").call(id: "msg_1", timestamp: 1_755_740_000, body: "{}")

      expected = Axn::Webhooks::Signature.compute(secret: "s3kr1t", payload: "{}", digest: :sha256, encoding: :hex)
      expect(headers).to eq("X-Signature" => expected)
    end

    it "resolves a callable secret fresh on every call" do
      secrets = %w[first second]
      signer = build(secret: -> { secrets.shift }, header: "X-Signature")

      first = signer.call(id: "m", timestamp: 1, body: "b")
      second = signer.call(id: "m", timestamp: 1, body: "b")

      expect(first).not_to eq(second)
    end

    it "honors digest, encoding and prefix" do
      headers = build(secret: "s", header: "X-Sig", digest: :sha1, encoding: :base64, prefix: "v1=")
        .call(id: "m", timestamp: 1, body: "b")

      expected = Axn::Webhooks::Signature.compute(secret: "s", payload: "b", digest: :sha1, encoding: :base64)
      expect(headers["X-Sig"]).to eq("v1=#{expected}")
    end
  end

  describe "the timestamped form" do
    it "renders the template and emits the timestamp header alongside the signature" do
      headers = build(
        secret: "s", header: "X-Signature", timestamp_header: "X-Timestamp",
        signing_string: "v0:{timestamp}:{body}", prefix: "v0=",
      ).call(id: "m", timestamp: 1_755_740_000, body: "{\"a\":1}")

      expected = Axn::Webhooks::Signature.compute(
        secret: "s", payload: "v0:1755740000:{\"a\":1}", digest: :sha256, encoding: :hex,
      )
      expect(headers).to eq("X-Signature" => "v0=#{expected}", "X-Timestamp" => "1755740000")
    end
  end

  describe "boot-time validation" do
    it "requires a header to emit" do
      expect { build(secret: "s") }.to raise_error(ArgumentError, /requires a `header:`/)
    end

    it "rejects an unknown template placeholder" do
      expect { build(secret: "s", header: "X-Sig", signing_string: "{nope}:{body}") }
        .to raise_error(ArgumentError, /unknown placeholder.*\{nope\}/)
    end

    it "rejects {timestamp} with no timestamp_header to carry it" do
      expect { build(secret: "s", header: "X-Sig", signing_string: "{timestamp}:{body}") }
        .to raise_error(ArgumentError, /timestamp_header/)
    end

    it "rejects a secret callable that requires an argument" do
      expect { build(secret: ->(x) { x }, header: "X-Sig") }
        .to raise_error(ArgumentError, /must accept zero arguments/)
    end
  end

  describe "runtime secret validation" do
    it "refuses to sign with a blank secret, without leaking it" do
      signer = build(secret: -> { "" }, header: "X-Sig")

      expect { signer.call(id: "m", timestamp: 1, body: "b") }
        .to raise_error(Axn::Webhooks::Error, /secret must be a non-empty String/)
    end

    it "never interpolates the secret into the error message" do
      signer = build(secret: -> { :not_a_string }, header: "X-Sig")

      expect { signer.call(id: "m", timestamp: 1, body: "b") }
        .to raise_error(Axn::Webhooks::Error) { |e| expect(e.message).not_to include("not_a_string") }
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bundle exec rspec spec/axn/webhooks/outbound/hmac_signer_spec.rb`

Expected: FAIL, every example, with `ArgumentError: unknown sign strategy :hmac`.

- [ ] **Step 3: Implement**

In `lib/axn/webhooks/outbound/signer.rb`, add to the `case` in `build`, above the `:standard_webhooks` line:

```ruby
          when :hmac then HmacSigner.new(**opts)
```

Add the class inside `module Signer`, after `CustomSigner`:

```ruby
        # Parametric HMAC, the outbound face of `verify :hmac`. Emits ONE signature header plus an
        # optional timestamp header. `header:` is required: unlike Standard Webhooks there is no
        # universal header name, which is exactly why the inbound verifier requires `signature:`.
        class HmacSigner
          PLACEHOLDERS = %w[timestamp body].freeze
          DEFAULT_SIGNING_STRING = "{body}"

          def initialize(secret:, header:, digest: :sha256, encoding: :hex, prefix: nil,
                         signing_string: DEFAULT_SIGNING_STRING, timestamp_header: nil)
            raise ArgumentError, "sign :hmac requires a `header:` naming the signature header to emit" if header.to_s.empty?

            # Same reasoning as :standard_webhooks — `resolve_secret` calls with NO arguments, so a
            # callable needing one boots fine and raises on every real signing attempt.
            if secret.respond_to?(:call) && !CallableArity.accepts?(secret, 0)
              raise ArgumentError, "sign :hmac secret callable must accept zero arguments (resolved with no args per signing attempt)"
            end

            validate_template!(signing_string, timestamp_header)

            @secret = secret
            @header = header
            @digest = digest
            @encoding = encoding
            @prefix = prefix
            @signing_string = signing_string
            @timestamp_header = timestamp_header
          end

          # `id:` is part of the signer contract but unused here — an id-bearing signature is what
          # :standard_webhooks is for, and this preset emits no id header for a receiver to read
          # one back from. Absorbed by `**` rather than named, so it isn't an unused argument.
          def call(timestamp:, body:, **)
            sig = Signature.compute(
              secret: resolved_secret,
              payload: render(timestamp:, body:),
              digest: @digest,
              encoding: @encoding,
            )

            headers = { @header => "#{@prefix}#{sig}" }
            headers[@timestamp_header] = timestamp.to_s if @timestamp_header
            headers
          end

          private

          def render(timestamp:, body:)
            @signing_string.gsub(/\{(\w+)\}/) { Regexp.last_match(1) == "timestamp" ? timestamp.to_s : body }
          end

          # A template (not a callable) so an unknown placeholder is caught HERE, at declaration
          # time — impossible with a lambda. Anyone needing real logic has the custom `sign { … }`
          # block already; a callable option would be a worse-ergonomics duplicate of it.
          def validate_template!(template, timestamp_header)
            raise ArgumentError, "sign :hmac `signing_string:` must be a String template (got #{template.class})" unless template.is_a?(String)

            found = template.scan(/\{(\w+)\}/).flatten.uniq
            unknown = found - PLACEHOLDERS
            unless unknown.empty?
              raise ArgumentError,
                    "sign :hmac `signing_string:` has unknown placeholder(s) " \
                    "#{unknown.map { |p| "{#{p}}" }.join(', ')} (known: {timestamp}, {body})"
            end

            return unless found.include?("timestamp") && timestamp_header.nil?

            raise ArgumentError,
                  "sign :hmac `signing_string:` references {timestamp} but no `timestamp_header:` is " \
                  "declared — the receiver would have no way to reconstruct the signed string"
          end

          # A blank or non-String secret would otherwise sign every delivery with an empty/garbage
          # key, and the receiver's 401 is indistinguishable from any other misconfiguration. The
          # message NEVER carries the secret's bytes: a callable secret is re-resolved per attempt,
          # so this can raise on every delivery and would flow the live credential into whatever
          # Axn.config.on_exception is wired to.
          def resolved_secret
            secret = @secret.respond_to?(:call) ? @secret.call : @secret
            return secret if secret.is_a?(String) && !secret.empty?

            raise Axn::Webhooks::Error,
                  "sign :hmac secret must be a non-empty String (got #{secret.is_a?(String) ? 'an empty String' : secret.class})"
          end
        end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bundle exec rspec spec/axn/webhooks/outbound/hmac_signer_spec.rb`

Expected: PASS, all examples.

- [ ] **Step 5: Add the round-trip integration test**

The point of mirroring inbound's option names is that the two halves agree. Append to `spec/axn/webhooks/outbound/integration_spec.rb`, inside the existing `describe`:

```ruby
  it "an outbound sign :hmac request passes the inbound verify :hmac verifier" do
    signer = Axn::Webhooks::Outbound::Signer.build(
      strategy: :hmac, opts: { secret: "shared-hmac-secret", header: "X-Signature" }, block: nil,
    )
    body = Axn::Webhooks::Outbound::Envelope.build(id: "msg_1", type: "lead_signed", data: { lead_id: 1 })
    headers = signer.call(id: "msg_1", timestamp: Time.now.to_i, body:)

    request = Axn::Webhooks::Request.new(raw_body: body, headers: { "X-Signature" => headers["X-Signature"] })

    verifier = Axn::Webhooks::Verifiers.build(
      strategy: :hmac,
      opts: { secret: "shared-hmac-secret", signature: Axn::Webhooks::Resolvers.header("X-Signature") },
      block: nil,
    )
    expect(verifier.call(request)).to be_ok
  end

  it "round-trips the timestamped form, including the replay window" do
    ts = Time.now.to_i
    signer = Axn::Webhooks::Outbound::Signer.build(
      strategy: :hmac,
      opts: { secret: "shared", header: "X-Signature", timestamp_header: "X-Timestamp",
              signing_string: "v0:{timestamp}:{body}", prefix: "v0=" },
      block: nil,
    )
    body = %({"a":1})
    headers = signer.call(id: "msg_1", timestamp: ts, body:)

    request = Axn::Webhooks::Request.new(
      raw_body: body,
      headers: { "X-Signature" => headers["X-Signature"], "X-Timestamp" => headers["X-Timestamp"] },
    )

    verifier = Axn::Webhooks::Verifiers.build(
      strategy: :hmac,
      opts: {
        secret: "shared",
        signature: Axn::Webhooks::Resolvers.header("X-Signature"),
        signing_string: ->(req) { "v0:#{req.header('X-Timestamp')}:#{req.raw_body}" },
        prefix: "v0=",
        replay: { timestamp: Axn::Webhooks::Resolvers.header("X-Timestamp"), within: 300 },
      },
      block: nil,
    )
    expect(verifier.call(request)).to be_ok
  end
```

- [ ] **Step 6: Run the full suite**

Run: `bundle exec rake`

Expected: PASS, no offenses. `HmacSigner#initialize` takes seven keywords, which is fine: this repo inherits axn core's shared config, which sets `Metrics/ParameterLists: Max: 11`. Do not add a local exemption.

- [ ] **Step 7: README**

In the outbound "Envelope & signing" area, after the `sign :standard_webhooks` discussion, add:

````markdown
#### `sign :hmac`

For a receiver that expects a plain signature header rather than the Standard Webhooks envelope:

```ruby
# minimal — one header, signature over the raw body
sign :hmac, secret: -> { ENV.fetch("PARTNER_SECRET") }, header: "X-Signature"
# => X-Signature: 3f9a1c…

# …or a replay-protectable signature, Slack-style
sign :hmac,
     secret:           -> { ENV.fetch("PARTNER_SECRET") },
     header:           "X-Signature",
     timestamp_header: "X-Timestamp",
     signing_string:   "v0:{timestamp}:{body}",
     prefix:           "v0="
# => X-Timestamp: 1755740000
#    X-Signature: v0=3f9a1c…
```

`secret:` (plain or zero-arity callable, re-resolved per attempt) and `header:` are required —
there is no universal signature-header name, the same reason inbound's `verify :hmac` requires
`signature:`. `digest:` (`:sha256`), `encoding:` (`:hex`), `prefix:` (`nil`) and `signing_string:`
(`"{body}"`) mirror the inbound verifier's options, so a `sign :hmac` sender and a `verify :hmac`
receiver configured alike round-trip.

`signing_string:` is a **template**, not a callable: `{timestamp}` and `{body}` are the only
placeholders, and an unknown one is rejected at declaration time — which a lambda would make
impossible. Referencing `{timestamp}` without declaring `timestamp_header:` is also rejected: the
receiver would have no way to reconstruct the signed string. If you need logic a template can't
express, use the custom `sign { |id:, timestamp:, body:| … }` block, which has always been there.

Note there is no id header — a signature bound to a per-message id is what `:standard_webhooks` is
for.
````

- [ ] **Step 8: CHANGELOG**

```markdown
- **Added `sign :hmac`**, a parametric outbound HMAC preset mirroring inbound's `verify :hmac`
  (`digest:`/`encoding:`/`prefix:`/`signing_string:`), so a receiver expecting a plain
  `X-Signature: <hex>` no longer needs a hand-written signer block. `header:` is required; an
  optional `timestamp_header:` plus a `{timestamp}`/`{body}` template covers Slack-style
  `v0:ts:body` schemes. The template is validated at declaration time — unknown placeholders, and
  `{timestamp}` with no header to carry it, are both rejected at boot.
```

- [ ] **Step 9: Commit**

```bash
git add lib/axn/webhooks/outbound/signer.rb spec/axn/webhooks/outbound/ README.md CHANGELOG.md
git commit -m "feat: add sign :hmac outbound signing preset"
```

---

### Task 4: Per-emit `to:` and `async:` overrides

**Files:**
- Modify: `lib/axn/webhooks.rb:50-58` (`self.emit`)
- Modify: `lib/axn/webhooks/outbound/emit.rb`
- Create: `spec/axn/webhooks/outbound/emit_overrides_spec.rb`
- Modify: `README.md`, `CHANGELOG.md`

**Interfaces:**
- Consumes: `Config.url_problem(url)` from Task 1; `Emit#enqueue` and `exposes :failed_count` from Task 2.
- Produces: `Axn::Webhooks.emit(event, data: {}, to: nil, async: nil)`.

`headers:` is deliberately NOT part of this task — see the spec's "Per-emit overrides" section and PRO-3214.

- [ ] **Step 1: Write the failing test**

Create `spec/axn/webhooks/outbound/emit_overrides_spec.rb`:

```ruby
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bundle exec rspec spec/axn/webhooks/outbound/emit_overrides_spec.rb`

Expected: FAIL with `ArgumentError: unknown keyword: :to` from `Axn::Webhooks.emit`.

- [ ] **Step 3: Widen the public entrypoint**

In `lib/axn/webhooks.rb`, replace `self.emit` (keeping its existing doc comment above, and appending to it):

```ruby
    # `to:` and `async:` are per-call overrides. `to:` REPLACES the event's declared targets for
    # this call only (never merges) — the event must still be declared, since it supplies the wire
    # `type` and `vendor`. `async: true` requires a configured adapter and raises without one;
    # `async: false` forces the inline path. Omitted means today's `:auto`.
    def self.emit(event, data: {}, to: nil, async: nil)
      Outbound::Emit.call!(event:, data:, to:, async:)
    end
```

- [ ] **Step 4: Implement the overrides in `Emit`**

In `lib/axn/webhooks/outbound/emit.rb`, add below `expects :data`:

```ruby
        # Per-call overrides (both nil = declaration-time behavior). `to:` is a String or an Array
        # of them; `async:` is a tri-state — nil (:auto), true (demand async), false (force sync).
        expects :to, allow_nil: true, default: nil
        expects :async, allow_nil: true, default: nil
```

Replace `#call`:

```ruby
        def call
          config = Axn::Webhooks::Outbound.config
          type = config.wire_type(event)
          use_async = resolve_async_mode
          warn_sync_fallback(type) if async.nil? && !use_async

          ids = []
          failed = 0
          resolve_targets(config).each do |url|
            id = Envelope.new_id
            body = Envelope.build(id:, type:, data:)
            failed += 1 unless enqueue(use_async, url:, webhook_id: id, body:, event: type, vendor:)
            ids << id
          end
          expose(webhook_ids: ids, target_count: ids.size, failed_count: failed)
        end
```

Replace `#enqueue` (Task 2's version) with one taking the already-resolved decision, so the mode is decided once per emit rather than re-derived per target:

```ruby
        # Returns whether the delivery is (so far) not-failed: an enqueue can't know the eventual
        # outcome, so it always counts as not-failed; the sync path reads Deliver's own result.
        def enqueue(use_async, **)
          if use_async
            Deliver.call_async(**)
            true
          else
            Deliver.call(**).ok?
          end
        end
```

Add to the `private` section:

```ruby
        # A per-call `to:` REPLACES resolution entirely — the declared `to:`/`subscribers` is not
        # consulted and not appended to, the same no-silent-merge stance Config#targets_for takes
        # for a declared resolver that returns nil. Validated here rather than at boot (it can't be
        # known earlier) and as an Axn::Webhooks::Error, not the ArgumentError a declaration
        # mistake gets: this one is raised per call, on caller-supplied runtime data.
        def resolve_targets(config)
          return config.targets_for(event) if to.nil?

          Array(to).each do |url|
            problem = Config.url_problem(url)
            raise Axn::Webhooks::Error, "emit(#{event.inspect}, to:) URL #{problem}" if problem
          end
        end

        # Tri-state. An explicit `true` with no adapter RAISES rather than degrading: a missing
        # adapter falls back to sync only under `:auto`, never under an explicit request (the same
        # rule inbound's Dispatch#dispatch_async enforces). An explicit `false` forces inline and
        # is not a degraded mode, so #call suppresses the fallback warning for it.
        def resolve_async_mode
          return async_configured? if async.nil?
          return false unless async

          unless async_configured?
            raise Axn::Webhooks::Error,
                  "emit(#{event.inspect}, async: true) requires an axn async adapter, but none is " \
                  "configured for #{Deliver} (add `async :sidekiq`/`async :active_job` to it, or set a global default)"
          end

          true
        end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bundle exec rspec spec/axn/webhooks/outbound/emit_overrides_spec.rb`

Expected: PASS, all examples.

- [ ] **Step 6: Run the full suite**

Run: `bundle exec rake`

Expected: PASS, no offenses. `#call` has grown across Tasks 2 and 4 — if `Metrics/AbcSize` or `Metrics/MethodLength` fires, extract the loop body:

```ruby
        def fan_out(config, type, use_async)
          resolve_targets(config).each_with_object({ ids: [], failed: 0 }) do |url, acc|
            id = Envelope.new_id
            body = Envelope.build(id:, type:, data:)
            acc[:failed] += 1 unless enqueue(use_async, url:, webhook_id: id, body:, event: type, vendor:)
            acc[:ids] << id
          end
        end
```

- [ ] **Step 7: README**

In the outbound section, after the `failed_count` bullet added in Task 2:

````markdown
* **Per-call overrides.** `emit` accepts `to:` and `async:`:

  ```ruby
  Axn::Webhooks.emit(:lead_signed, data: { lead_id: 42 },
                     to:    "https://one-off.example/hook",  # String or Array
                     async: false)
  ```

  `to:` **replaces** the event's declared targets for that call — it never merges with them, the
  same stance a declared `to:` resolver returning nil takes. The event must still be declared (it
  supplies the wire `type` and `vendor`), and a one-off URL is validated as http(s) at emit time,
  raising `Axn::Webhooks::Error`. `async: true` **raises** when no adapter is configured rather
  than running inline — a missing adapter degrades to sync only under `:auto`, never under an
  explicit request (same rule as an inbound route marked `async`). `async: false` forces the inline
  path and suppresses the degraded-mode warning, since a caller asking for sync isn't degraded.

  There is deliberately no per-call `headers:`: it is the obvious place to hang a bearer token, and
  it would be serialized into the async job's args and persist in the queue for the whole retry
  lifetime — the opposite of the convention `secret:` follows (a callable re-resolved per attempt,
  never stored). Per-destination config belongs with the DB-backed subscription store.
````

- [ ] **Step 8: CHANGELOG**

```markdown
- **`emit` accepts per-call `to:` and `async:` overrides.** `to:` (a String or Array) replaces the
  event's declared targets for one call — never merges — and validates the one-off URL at emit time
  as an `Axn::Webhooks::Error`. `async: true` raises when no adapter is configured rather than
  silently running inline (a missing adapter degrades only under `:auto`, never under an explicit
  request); `async: false` forces the inline path and suppresses the degraded-mode warning. No
  per-call `headers:` — per-destination config is deferred to the DB-backed subscription store,
  since a Hash of headers would persist a bearer token in async job args for the whole retry
  lifetime.
```

- [ ] **Step 9: Commit**

```bash
git add lib/axn/webhooks.rb lib/axn/webhooks/outbound/emit.rb \
        spec/axn/webhooks/outbound/emit_overrides_spec.rb README.md CHANGELOG.md
git commit -m "feat: per-emit to:/async: overrides"
```

---

### Task 5: Nested `inbound` declarations

Registration is already flat (`Inbound.register(name, Endpoint.new(…))`), so this is purely a declaration-time fan-out: one `inbound` call producing N `Endpoint`s. No `Endpoint` or `Router` changes.

**Files:**
- Modify: `lib/axn/webhooks/inbound/dsl.rb`
- Modify: `lib/axn/webhooks/inbound.rb:23-42`
- Create: `spec/axn/webhooks/inbound/nested_endpoints_spec.rb`
- Modify: `README.md`, `CHANGELOG.md`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `Inbound::DSL#endpoint(name, &block)`; `Inbound::DSL#__children__ -> Hash{Symbol => Proc}`; `Inbound::DSL#__child_dsl__(block) -> DSL`; `Inbound::DSL#__dispatch_declared__ -> Boolean`.

- [ ] **Step 1: Write the failing test**

Create `spec/axn/webhooks/inbound/nested_endpoints_spec.rb`:

```ruby
# frozen_string_literal: true

RSpec.describe "nested inbound endpoints" do
  after { Axn::Webhooks::Inbound.reset! }

  it "registers one endpoint per child, named parent_child, and NOT the parent" do
    Axn::Webhooks.inbound :slack do
      verify :hmac, secret: "s", signature: header("X-Sig")

      endpoint(:interactivity) { dispatch to: "HandlerA" }
      endpoint(:events) { dispatch to: "HandlerB" }
    end

    expect(Axn::Webhooks::Inbound.registered).to contain_exactly(:slack_interactivity, :slack_events)
    expect { Axn::Webhooks::Inbound[:slack] }.to raise_error(KeyError)
  end

  it "gives every child the parent's declarations" do
    Axn::Webhooks.inbound :slack do
      verify :hmac, secret: "parent-secret", signature: header("X-Sig")
      unauthorized_headers "WWW-Authenticate" => "Basic realm=\"Webhook\""

      endpoint(:events) { dispatch to: "HandlerB" }
    end

    endpoint = Axn::Webhooks::Inbound[:slack_events]
    expect(endpoint.unauthorized_headers).to eq("WWW-Authenticate" => "Basic realm=\"Webhook\"")

    # Endpoint exposes no `verifier` reader — `verify(request)` is the public seam, returning an
    # Axn::Result (ok? when verified).
    body = "{}"
    sig = Axn::Webhooks::Signature.compute(secret: "parent-secret", payload: body)
    request = Axn::Webhooks::Request.new(raw_body: body, headers: { "X-Sig" => sig })
    expect(endpoint.verify(request)).to be_ok
  end

  it "lets a child override an inherited declaration by re-declaring it" do
    Axn::Webhooks.inbound :slack do
      verify :hmac, secret: "parent-secret", signature: header("X-Sig")

      endpoint(:events) do
        dispatch to: "HandlerB"
        verify :hmac, secret: "child-secret", signature: header("X-Sig")
      end
    end

    body = "{}"
    request = lambda do |secret|
      Axn::Webhooks::Request.new(
        raw_body: body,
        headers: { "X-Sig" => Axn::Webhooks::Signature.compute(secret:, payload: body) },
      )
    end

    endpoint = Axn::Webhooks::Inbound[:slack_events]
    expect(endpoint.verify(request.call("child-secret"))).to be_ok
    expect(endpoint.verify(request.call("parent-secret"))).not_to be_ok
  end

  it "isolates siblings — a declaration in one child does not leak into another" do
    Axn::Webhooks.inbound :slack do
      verify :hmac, secret: "s", signature: header("X-Sig")

      endpoint(:interactivity) do
        dispatch to: "HandlerA"
        respond { |result| text(result.to_s) }
      end
      endpoint(:events) { dispatch to: "HandlerB" }
    end

    # Endpoint exposes no `respond` reader; read the ivar rather than adding one for a test's sake.
    expect(Axn::Webhooks::Inbound[:slack_interactivity].instance_variable_get(:@respond)).not_to be_nil
    expect(Axn::Webhooks::Inbound[:slack_events].instance_variable_get(:@respond)).to be_nil
  end

  it "rejects a parent that both declares endpoints and dispatches itself" do
    expect do
      Axn::Webhooks.inbound :slack do
        verify :hmac, secret: "s", signature: header("X-Sig")
        dispatch to: "HandlerA"

        endpoint(:events) { dispatch to: "HandlerB" }
      end
    end.to raise_error(ArgumentError, /registers nothing itself/)
  end

  it "rejects an endpoint nested inside an endpoint" do
    expect do
      Axn::Webhooks.inbound :slack do
        verify :hmac, secret: "s", signature: header("X-Sig")

        endpoint(:events) do
          dispatch to: "HandlerB"
          endpoint(:deeper) { dispatch to: "HandlerC" }
        end
      end
    end.to raise_error(ArgumentError, /cannot be nested/)
  end

  it "rejects a duplicate child name" do
    expect do
      Axn::Webhooks.inbound :slack do
        verify :hmac, secret: "s", signature: header("X-Sig")

        endpoint(:events) { dispatch to: "HandlerB" }
        endpoint(:events) { dispatch to: "HandlerC" }
      end
    end.to raise_error(ArgumentError, /duplicate/)
  end

  it "requires a block" do
    expect do
      Axn::Webhooks.inbound(:slack) { endpoint(:events) }
    end.to raise_error(ArgumentError, /requires a block/)
  end

  it "still runs each child through the existing per-endpoint validation" do
    # `verify` is required whenever `dispatch` is declared — that check lives in __verifier__ and
    # must run per child, not once for the parent.
    expect do
      Axn::Webhooks.inbound :slack do
        endpoint(:events) { dispatch to: "HandlerB" }
      end
    end.to raise_error(Axn::Webhooks::Error, /declared no `verify`/)
  end

  it "leaves a plain (unnested) inbound block registering exactly as before" do
    Axn::Webhooks.inbound :codat do
      verify :hmac, secret: "s", signature: header("X-Sig")
      dispatch to: "HandlerA"
    end

    expect(Axn::Webhooks::Inbound.registered).to eq([:codat])
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bundle exec rspec spec/axn/webhooks/inbound/nested_endpoints_spec.rb`

Expected: FAIL with `NoMethodError: undefined method 'endpoint'` for most examples; the last one ("plain inbound block") passes as a regression guard.

- [ ] **Step 3: Add `endpoint` to the inbound DSL**

In `lib/axn/webhooks/inbound/dsl.rb`, add after the `sync`/`async` sugar methods and before `__verifier__`:

```ruby
        # endpoint(:events) { dispatch … } — declares a CHILD endpoint that inherits everything the
        # parent block declared and may override any of it by re-declaring. One `inbound :slack`
        # block with two `endpoint` blocks registers Inbound[:slack_interactivity] and
        # Inbound[:slack_events]; the parent itself registers nothing.
        def endpoint(name, &block)
          raise ArgumentError, "`endpoint #{name.inspect}` requires a block" unless block
          raise ArgumentError, "`endpoint #{name.inspect}` cannot be nested inside another `endpoint` — one level only" if @nested

          @child_endpoints ||= {}
          raise ArgumentError, "duplicate `endpoint #{name.inspect}` in the same inbound block" if @child_endpoints.key?(name.to_sym)

          @child_endpoints[name.to_sym] = block
        end
```

Add to the internal (`__`-prefixed) section, next to `__verifier__` and friends:

```ruby
        # Internal: declared child endpoints, name => block. Empty for a plain `inbound` block.
        def __children__ = @child_endpoints || {}

        # Internal: whether `dispatch` was declared directly on THIS DSL. Read instead of
        # `__dispatch__` so the parent-with-children check doesn't build a Router just to ask.
        def __dispatch_declared__ = !@dispatch_spec.nil?

        # Internal: a fresh DSL seeded with this one's captured declarations, with `block`
        # evaluated against it — so a child inherits everything and overrides by re-declaring.
        #
        # Copies the ivars rather than re-`instance_exec`ing the parent block per child (the
        # obvious alternative): replaying the parent block would re-run any side effects in it and
        # would re-enter `endpoint` recursively, registering each child once per sibling.
        def __child_dsl__(block)
          child = self.class.new
          INHERITED_IVARS.each do |ivar|
            child.instance_variable_set(ivar, instance_variable_get(ivar)) if instance_variable_defined?(ivar)
          end
          child.instance_variable_set(:@nested, true)
          child.instance_exec(&block)
          child
        end
```

Add the constant at the very top of the class body, above `def verify`:

```ruby
        # Every declaration a child inherits — uniformly, not a curated subset, so there is one
        # rule to remember ("children inherit everything, override by re-declaring") rather than a
        # list to check. Deliberately excludes @child_endpoints (nesting is one level) and @nested.
        INHERITED_IVARS = %i[
          @verify_spec @unauthorized_headers @challenge_required
          @dispatch_spec @respond_block @static_respond_block @challenge_spec
        ].freeze
```

- [ ] **Step 4: Fan out at registration**

In `lib/axn/webhooks/inbound.rb`, replace `self.inbound` entirely:

```ruby
    # Declare an inbound webhook endpoint. Evaluated at boot (e.g. a Rails initializer)
    # so registration is deterministic, in or out of Rails.
    #
    # With one or more nested `endpoint` blocks, this registers one endpoint per child, named
    # :"#{name}_#{child}", and does NOT register `name` itself — see Inbound::DSL#endpoint.
    def self.inbound(name, &block)
      raise ArgumentError, "Axn::Webhooks.inbound requires a block" unless block

      dsl = Inbound::DSL.new
      dsl.instance_exec(&block)
      children = dsl.__children__
      return register_endpoint(name, dsl) if children.empty?

      # A parent with children is a container, not an endpoint. Registering it too would leave a
      # third endpoint nobody mounted, silently — so a top-level dispatch/respond alongside
      # `endpoint` blocks is a declaration mistake, caught at boot.
      if dsl.__dispatch_declared__ || dsl.__respond__ || dsl.__static_respond__
        raise ArgumentError,
              "inbound #{name.inspect} declares `endpoint` blocks AND its own dispatch/respond — a parent " \
              "with endpoints registers nothing itself; move those declarations into an endpoint"
      end

      children.each { |child, child_block| register_endpoint(:"#{name}_#{child}", dsl.__child_dsl__(child_block)) }
    end

    # Each child is a complete, independently valid endpoint by the time it gets here, so the
    # existing per-endpoint validation (__verifier__'s "declared no `verify`" check, Endpoint's
    # respond/static_respond exclusivity) runs per child, unchanged.
    def self.register_endpoint(name, dsl)
      Inbound.register(
        name,
        Inbound::Endpoint.new(
          name:,
          verifier: dsl.__verifier__,
          dispatch: dsl.__dispatch__,
          respond: dsl.__respond__,
          static_respond: dsl.__static_respond__,
          challenge: dsl.__challenge__,
          unauthorized_headers: dsl.__unauthorized_headers__,
          challenge_required: dsl.__challenge_required__,
        ),
      )
    end
    private_class_method :register_endpoint
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bundle exec rspec spec/axn/webhooks/inbound/nested_endpoints_spec.rb`

Expected: PASS, all examples. Note `Endpoint`'s public surface is narrow — `name`, `unauthorized_headers`, `challenge_required?`, `verify`, `handle`, `to_response`, `call` — with no `verifier`/`respond`/`dispatch` readers. The tests above are written against that surface; do not add readers to `Endpoint` to make a test easier.

- [ ] **Step 6: Run the full suite**

Run: `bundle exec rake`

Expected: PASS, no offenses. This includes `spec_rails/` — confirm the dummy app's mounts still resolve.

- [ ] **Step 7: README**

In the inbound section, after the per-route sync/async subsection, add:

````markdown
### Nested endpoints

When several endpoints share a vendor's verification, declare it once and nest the endpoints that
differ:

```ruby
Axn::Webhooks.inbound :slack do
  verify :hmac, secret: ENV.fetch("SLACK_SIGNING_SECRET"), prefix: "v0=",
                replay: { timestamp: header("X-Slack-Request-Timestamp"), within: 300 }
  challenge_required { |req| req.params["type"] == "url_verification" }

  endpoint :interactivity do
    dispatch on: ->(e) { e["type"] }, to: { "block_actions" => async("Actions::Slack::HandleBlockActions") }
    respond { |result| json(result.response_action) }
  end

  endpoint :events do
    dispatch on: ->(e) { e.dig("event", "type") }, to: { "app_mention" => "Actions::Slack::HandleMention" }
  end
end
# => registers Inbound[:slack_interactivity] and Inbound[:slack_events]
```

* **Each child registers as `:"#{parent}_#{child}"`.** The parent (`Inbound[:slack]`) is **not**
  registered — a parent with `endpoint` blocks is a container, and declaring a top-level
  `dispatch`/`respond` alongside them raises at boot rather than leaving a third endpoint nobody
  mounted.
* **Children inherit everything the parent declared** — `verify`, `challenge`, `challenge_required`,
  `unauthorized_headers`, `dispatch`, `respond`, `static_respond` — and override any of it by
  re-declaring it. Siblings are independent; a declaration in one child never leaks into another.
* **One level only.** An `endpoint` inside an `endpoint` raises.

Nesting is sugar, not a new capability: a shared options hash splatted with `**`, or a shared lambda
passed to `verify(&lambda)`, expresses the same thing and remains a fine choice.
````

- [ ] **Step 8: CHANGELOG**

```markdown
- **Nested `inbound` endpoints.** An `inbound` block may now contain `endpoint(name) { … }` blocks,
  each registering as `:"#{parent}_#{child}"` and inheriting every parent declaration (overridable
  by re-declaring). Lets one vendor's `verify`/`challenge` be written once across several endpoints.
  The parent itself registers nothing; declaring a top-level `dispatch`/`respond` alongside
  `endpoint` blocks raises at boot, as does nesting an `endpoint` inside an `endpoint`.
```

- [ ] **Step 9: Commit**

```bash
git add lib/axn/webhooks/inbound/dsl.rb lib/axn/webhooks/inbound.rb \
        spec/axn/webhooks/inbound/nested_endpoints_spec.rb README.md CHANGELOG.md
git commit -m "feat: nested inbound endpoint declarations"
```

---

## Final verification

- [ ] `bundle exec rake` green (specs + RuboCop, including `spec_rails/`).
- [ ] `## [Unreleased]` in CHANGELOG.md has an entry for each of Tasks 1–5.
- [ ] The README's outbound section documents `failed_count`, per-call `to:`/`async:`, and
      `sign :hmac`; the inbound section documents nested endpoints.
- [ ] `git log --oneline` shows five feature commits.
- [ ] Re-read the spec's "Out of scope" section and confirm nothing from PRO-3214 crept in — in
      particular, no per-emit `headers:` and no per-subscriber secret.
