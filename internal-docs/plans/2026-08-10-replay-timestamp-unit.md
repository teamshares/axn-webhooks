# Replay timestamp `unit:` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `unit:` option (default `:seconds`) to replay-window timestamp handling, so vendors sending epoch milliseconds (Lob) or microseconds don't need a fragile hand-rolled string-slice conversion at the call site.

**Architecture:** Thread a new `unit:` keyword from `Verifiers.register(:hmac)`'s `replay:` hash down through `Signature.hmac` → `Signature.within_tolerance?` → `Signature.coerce_epoch`, which divides the raw epoch value by a divisor looked up from a new frozen `UNITS` constant (mirroring the existing `DIGESTS` constant/`openssl_digest` lookup pattern already in the file). Fully backward-compatible: every new keyword defaults to `:seconds`, so omitting `unit:` reproduces today's behavior exactly.

**Tech Stack:** Ruby, RSpec. No new dependencies.

## Global Constraints

- TDD: failing test first (per `AGENTS.md`).
- `bundle exec rake` (specs + rubocop) must pass before any task is considered done.
- CHANGELOG entry under `## [Unreleased]` for this user-visible change (per `AGENTS.md`).
- Spec doc: `internal-docs/specs/2026-08-10-replay-timestamp-unit-design.md` (source of truth for design decisions referenced below).

---

### Task 1: `Signature` primitive — `unit:` on `coerce_epoch`/`within_tolerance?`/`hmac`

**Files:**
- Modify: `lib/axn/webhooks/signature.rb`
- Test: `spec/axn/webhooks/signature_spec.rb`

**Interfaces:**
- Produces: `Axn::Webhooks::Signature::UNITS` (frozen `Hash`, unit symbol → Integer divisor: `{ seconds: 1, ms: 1_000, milliseconds: 1_000, microseconds: 1_000_000 }`).
- Produces: `Signature.hmac(..., unit: :seconds)` — new optional keyword, passed through to `within_tolerance?`.
- Produces: `Signature.within_tolerance?(timestamp:, tolerance:, now: nil, unit: :seconds)` — new optional keyword, passed to `coerce_epoch`.
- Produces: `Signature.coerce_epoch(timestamp, unit)` (private) — now takes a required second positional arg.

- [ ] **Step 1: Write the failing tests**

Add to the `describe "replay window"` block in `spec/axn/webhooks/signature_spec.rb` (after the existing `"rejects timestamps just outside the inclusive boundary"` test, before the closing `end` of that `describe`):

```ruby
    it "accepts an epoch-ms timestamp within tolerance when unit: :ms" do
      ts_ms = (now - 60).to_i * 1_000
      expect(described_class.hmac(secret:, payload:, signature: hex, timestamp: ts_ms, tolerance: 300, now:,
                                   unit: :ms)).to be(true)
    end

    it "rejects an epoch-ms timestamp outside tolerance when unit: :ms" do
      ts_ms = (now - 600).to_i * 1_000
      expect(described_class.hmac(secret:, payload:, signature: hex, timestamp: ts_ms, tolerance: 300, now:,
                                   unit: :ms)).to be(false)
    end

    it "treats :ms and :milliseconds identically" do
      ts_ms = ((now - 60).to_i * 1_000).to_s
      expect(described_class.within_tolerance?(timestamp: ts_ms, tolerance: 300, now:, unit: :ms)).to be(true)
      expect(described_class.within_tolerance?(timestamp: ts_ms, tolerance: 300, now:, unit: :milliseconds)).to be(true)
    end

    it "supports :microseconds" do
      ts_us = (now - 60).to_i * 1_000_000
      expect(described_class.within_tolerance?(timestamp: ts_us, tolerance: 300, now:, unit: :microseconds)).to be(true)
    end

    it "defaults unit to :seconds when omitted (regression)" do
      ts = (now - 60).to_i
      expect(described_class.within_tolerance?(timestamp: ts, tolerance: 300, now:)).to be(true)
    end

    it "ignores unit for a Time timestamp (already unambiguous)" do
      expect(described_class.within_tolerance?(timestamp: now - 60, tolerance: 300, now:, unit: :ms)).to be(true)
    end

    it "raises ArgumentError for an unsupported unit" do
      expect do
        described_class.within_tolerance?(timestamp: (now - 60).to_i, tolerance: 300, now:, unit: :fortnights)
      end.to raise_error(ArgumentError, /unsupported unit/)
    end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec rspec spec/axn/webhooks/signature_spec.rb`
Expected: FAIL — `ArgumentError: unknown keyword: :unit` (or similar) on every new example, since `hmac`/`within_tolerance?` don't accept `unit:` yet.

- [ ] **Step 3: Implement `UNITS` and thread `unit:` through**

In `lib/axn/webhooks/signature.rb`, add the constant next to `DIGESTS`:

```ruby
      DIGESTS = { sha256: "SHA256", sha1: "SHA1", md5: "MD5" }.freeze
      UNITS = { seconds: 1, ms: 1_000, milliseconds: 1_000, microseconds: 1_000_000 }.freeze
```

Update `hmac`'s signature and its replay-window call:

```ruby
      def hmac(secret:, payload:, signature:, digest: :sha256, encoding: :hex, prefix: nil,
               timestamp: nil, tolerance: nil, now: nil, unit: :seconds)
        return false if signature.nil? || signature.to_s.empty?
        return false if tolerance && !within_tolerance?(timestamp:, tolerance:, now: now || Time.now, unit:)

        expected = compute(secret:, payload:, digest:, encoding:)
        candidates(signature, prefix:).any? { |candidate| secure_compare(candidate, expected) }
      end
```

Update `within_tolerance?`:

```ruby
      def within_tolerance?(timestamp:, tolerance:, now: nil, unit: :seconds)
        epoch = coerce_epoch(timestamp, unit)
        return false if epoch.nil?

        ((now || Time.now).to_i - epoch).abs <= tolerance.to_i
      end
```

Update `coerce_epoch` (still private, now takes `unit`):

```ruby
      def coerce_epoch(timestamp, unit)
        divisor = UNITS.fetch(unit) { raise ArgumentError, "unsupported unit: #{unit.inspect}" }

        case timestamp
        when Time    then timestamp.to_i
        when Integer then timestamp / divisor
        when String  then (Integer(timestamp, 10) / divisor if timestamp.match?(/\A-?\d+\z/))
        end
      end
      private_class_method :coerce_epoch
```

Note: the `divisor` lookup (and its `ArgumentError`) runs before the `case`, so an unsupported `unit:` raises regardless of the timestamp's type — including for a `Time` timestamp, even though a valid unit would otherwise be ignored for `Time`. This is intentional: it catches a typo'd `unit:` immediately rather than only when someone happens to pass an Integer/String timestamp.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bundle exec rspec spec/axn/webhooks/signature_spec.rb`
Expected: PASS, all examples (including all pre-existing ones — this must stay a pure addition).

- [ ] **Step 5: Rubocop and full suite**

Run: `bundle exec rake`
Expected: PASS (specs + rubocop), no new offenses.

- [ ] **Step 6: Commit**

```bash
git add lib/axn/webhooks/signature.rb spec/axn/webhooks/signature_spec.rb
git commit -m "feat: add unit: option to Signature replay-window timestamp coercion"
```

---

### Task 2: `verify :hmac` — thread `replay[:unit]` through, plus docs

**Files:**
- Modify: `lib/axn/webhooks/verifiers/hmac.rb`
- Modify: `README.md`
- Modify: `CHANGELOG.md`
- Test: `spec/axn/webhooks/verifiers/hmac_spec.rb`

**Interfaces:**
- Consumes: `Signature.hmac(..., unit:)` from Task 1.
- Produces: `verify :hmac, replay: { timestamp:, within:, unit: :ms }` — the end-user-facing surface for this ticket.

- [ ] **Step 1: Write the failing tests**

Add to `spec/axn/webhooks/verifiers/hmac_spec.rb`, after the existing `"accepts a fresh timestamp when replay protection is configured"` test (before the `"raises a loud developer error..."` test):

```ruby
  it "accepts a fresh epoch-ms timestamp when replay protection specifies unit: :ms (Lob-style)" do
    fresh_ms = (Time.now.to_i * 1_000).to_s
    sig = OpenSSL::HMAC.hexdigest("SHA256", secret, body)
    Axn::Webhooks.inbound(:lob_ms) do
      verify :hmac, secret: "shh", signature: header("X-Sig"),
                    replay: { timestamp: header("X-Ts"), within: 300, unit: :ms }
    end
    req = request(headers: { "X-Sig" => sig, "X-Ts" => fresh_ms })
    expect(Axn::Webhooks::Inbound[:lob_ms].verify(req)).to be_ok
  end

  it "rejects a stale epoch-ms timestamp when replay protection specifies unit: :ms" do
    stale_ms = ((Time.now - 10_000).to_i * 1_000).to_s
    sig = OpenSSL::HMAC.hexdigest("SHA256", secret, body)
    Axn::Webhooks.inbound(:lob_ms_stale) do
      verify :hmac, secret: "shh", signature: header("X-Sig"),
                    replay: { timestamp: header("X-Ts"), within: 300, unit: :ms }
    end
    req = request(headers: { "X-Sig" => sig, "X-Ts" => stale_ms })
    expect(Axn::Webhooks::Inbound[:lob_ms_stale].verify(req)).not_to be_ok
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec rspec spec/axn/webhooks/verifiers/hmac_spec.rb`
Expected: FAIL on both new examples — the ms timestamp is compared as raw seconds (since `unit:` isn't threaded through yet), so `fresh_ms` (a ~13-digit number, wildly outside any tolerance in seconds since epoch) fails the freshness check, and the "stale" test spuriously passes for the wrong reason. Confirm the first new test fails; that's sufficient to prove the missing wiring.

- [ ] **Step 3: Implement**

In `lib/axn/webhooks/verifiers/hmac.rb`:

```ruby
      register(:hmac) do |secret:, signature:, signing_string: :raw_body, digest: :sha256,
                          encoding: :hex, prefix: nil, replay: nil|
        lambda do |request|
          timestamp = replay && Resolvers.resolve(replay.fetch(:timestamp), request)
          Signature.hmac(
            secret: Resolvers.resolve(secret, request),
            payload: Resolvers.resolve(signing_string, request),
            signature: Resolvers.resolve(signature, request),
            digest:,
            encoding:,
            prefix:,
            timestamp:,
            tolerance: replay&.fetch(:within),
            unit: replay&.fetch(:unit, :seconds) || :seconds,
          )
        end
      end
```

(`|| :seconds` covers the `replay: nil` case, where `&.fetch` short-circuits to `nil` rather than `:seconds` — harmless either way since `tolerance` is also `nil` there and `Signature.hmac` never reaches `within_tolerance?`/`coerce_epoch`, but passing an explicit `:seconds` keeps the call site honest.)

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bundle exec rspec spec/axn/webhooks/verifiers/hmac_spec.rb`
Expected: PASS, all examples.

- [ ] **Step 5: Update README**

In `README.md`, insert a new subsection immediately after the `Signature primitive` code block's closing line (`It always uses a constant-time comparison and supports multi-signature (key-rotation) headers.`, currently line 33) and before `## Inbound endpoints` (currently line 35):

```markdown

### Replay protection

Pass `timestamp:` and `tolerance:` to guard against replayed requests — `hmac` returns `false` if
the timestamp is more than `tolerance` seconds from now, in either direction. Vendors that send
epoch **milliseconds** (not seconds) — e.g. Lob — pass `unit:`:

```ruby
Axn::Webhooks::Signature.hmac(
  secret:, payload:, signature:,
  timestamp: request.header("X-Timestamp"),  # epoch ms
  tolerance: 300,
  unit:      :ms,                            # :seconds (default) | :ms | :milliseconds | :microseconds
)
```

The same `unit:` option is available on `verify :hmac`'s `replay:` hash:

```ruby
Axn::Webhooks.inbound :lob do
  verify :hmac, secret: ENV.fetch("LOB_WEBHOOK_SECRET"), signature: header("X-Lob-Signature"),
                replay: { timestamp: header("X-Lob-Signature-Timestamp"), within: 300, unit: :ms }
end
```
```

(That's the markdown to insert verbatim, including its own nested ` ```ruby ` fences — the outer ` ``` ` fences shown here are just this plan document's quoting.)

- [ ] **Step 6: Update CHANGELOG**

In `CHANGELOG.md`, add a new bullet at the end of the existing `### Added` list under `## [Unreleased]` (after the `Endpoint#to_response` bullet, currently the last line of that section):

```markdown
- `unit:` option on `replay:` (`verify :hmac`) and on `Signature.hmac`/`.within_tolerance?` directly — `:seconds` (default), `:ms`/`:milliseconds`, or `:microseconds`. Vendors sending epoch milliseconds (Lob) or finer resolutions no longer need a hand-rolled `timestamp[0, 10]`-style slice to fake seconds; the raw epoch value is divided by the unit's divisor before the tolerance comparison. A `Time` timestamp ignores `unit:` (already unambiguous); an unrecognized `unit:` raises `ArgumentError` immediately, regardless of timestamp type.
```

- [ ] **Step 7: Full suite**

Run: `bundle exec rake`
Expected: PASS (specs + rubocop).

- [ ] **Step 8: Commit**

```bash
git add lib/axn/webhooks/verifiers/hmac.rb spec/axn/webhooks/verifiers/hmac_spec.rb README.md CHANGELOG.md
git commit -m "feat: thread unit: through verify :hmac replay option, document it"
```

---

## Self-Review Notes

- **Spec coverage:** Task 1 covers `Signature.coerce_epoch`/`within_tolerance?`/`hmac` (spec's "Where conversion happens" + "Supported units" + "Rejected alternatives" sections — no auto-detection added). Task 2 covers the `verify :hmac` `replay:` surface, README, and CHANGELOG (spec's "Docs" section). The spec's "Scope" note (no `unit:` for `standard_webhooks`) requires no task — nothing to change there.
- **Type consistency:** `unit:` is a `Symbol` end-to-end (`:seconds`/`:ms`/`:milliseconds`/`:microseconds`); `UNITS` keys match exactly what's documented in the spec and README. `coerce_epoch(timestamp, unit)` signature is used consistently by its one caller (`within_tolerance?`).
- **No placeholders:** every step above contains literal code/markdown to add, not a description of what to add.
