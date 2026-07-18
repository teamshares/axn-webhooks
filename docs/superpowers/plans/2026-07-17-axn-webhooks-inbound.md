# axn-webhooks Inbound — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the inbound half of the `axn-webhooks` gem — a Rails-agnostic library that DRYs the `verify signature → parse → dispatch to a handler Axn → ack` pattern for inbound vendor webhooks.

**Architecture:** Bottom-up layers. A pure crypto core (`Signature` primitive + a Rack-agnostic `Request` wrapper) is built and hardened first, then the verifier registry / `verify` DSL, then `dispatch`, then `respond` + the staged-outcome Axn pipeline, then the Rack mount that ties it to HTTP. Each layer is unit-tested in isolation before the next depends on it.

**Tech Stack:** Ruby ≥ 3.2.1, `axn` (the `axn-*` family base), Rack, `OpenSSL`/`Base64` (stdlib). No teamshares-rails, no ActionController.

**Spec:** `docs/superpowers/specs/2026-07-17-axn-webhooks-inbound-design.md` (settled design, PRO-2947).

## Global Constraints

Every task's requirements implicitly include these:

- **Ruby ≥ 3.2.1** (`required_ruby_version` already set in the gemspec).
- **Dependencies:** `axn` (`>= 0.1.0-alpha.4.3`, `< 0.2.0`) + Rack only. Never require teamshares-rails, ActionController, or an `ApplicationController`.
- **Works outside Rails:** guard every `Rails` / `ActiveRecord` / `ActiveJob` reference with `defined?(...)`. The whole test suite runs with no Rails loaded.
- **Signature comparison is ALWAYS constant-time.** Never use `==` to compare a candidate signature against an expected one. This is the single most important security property of the library.
- **CHANGELOG:** every user-visible change gets an entry under `## [Unreleased]`.
- **Definition of done for any task:** `bundle exec rake` (specs + rubocop) is green.
- **TDD:** failing test first, always.
- **Namespace:** everything lives under `Axn::Webhooks` (already scaffolded with `extend Axn::Configurable` + `config_namespace :webhooks`).

## Grounding notes (verified against the installed `axn` this session)

These pin design terms to axn's *actual* current contract — read before Phases 2–5:

- **`dimension` is real.** `dimension :vendor, <name>` resolves into axn's metrics/OTel/exception facets (`_dimensions`, `lib/axn/executor.rb`). Decision 7 is supported as written.
- **There is no `mode:` async kwarg.** axn exposes `async :sidekiq` (config) + `.call_async` (`lib/axn/async.rb`). The design's `mode: :async` / `:sync` is a **webhook-DSL concept the gem implements** by choosing `.call_async` vs `.call` at dispatch time — not a passthrough to axn.
- **axn's `Mountable` ≠ the webhook Rack mount.** `mount_axn` / `step` compose *actions into classes* (`lib/axn/mountable.rb`) — useful for building the verify→dispatch→respond pipeline via `steps`. The HTTP `mount … at: "/webhooks/codat"` endpoint is a Rack app (`call(env)`) **this gem builds itself** (Phase 5).
- **`on:` subfields** are indifferent to string/symbol keys and support dotted paths (`on: "event.payload.connection"`) — exactly what "payload → handler args" (Decision 5) relies on. Source: `lib/axn/core/field_resolvers/extract.rb`.
- **`fail!` vs unhandled-raise buckets** map 1:1 onto the staged-outcome table: `fail!` → `failure` (quiet, no `on_exception`); any other raise → `exception` (loud, global report). Source: AGENTS-consuming.md "Failure semantics".
- **Config uses axn's `Axn::Configurable`, exactly as the sibling gems do** (`axn-mcp`, `axn-ruby_llm` on disk at `/Users/kali/code/core/`). The scaffold already `extend Axn::Configurable` + `config_namespace :webhooks`. Declare tunables with `setting(name, default:, one_of:, validate:, callable:, overridable:)`; read via `Axn::Webhooks.config.<name>`; the block-form `Axn::Webhooks.configure { |c| … }` yields the config, and per-consuming-class overrides use `configure(:webhooks) { |c| c.<name> = … }` (mints override accessors only when `overridable: true`). Standard API is `.config` / `reset_config!`. **Do not invent a bespoke config DSL** where a `setting` (or axn's `Mountable` / tool-adapter registry) already fits. Precedents: `axn-mcp` `setting :present_as, default: :structured, one_of: %i[structured message], overridable: true`; `axn-ruby_llm` `setting :default_model` + `include Axn::Mountable` + `mount_axn :ask, Ask`.

---

## Phase Map

Each phase produces working, testable software on its own and gets its **own detailed plan** written when its predecessor lands (so its API is designed via TDD against real, existing lower layers rather than guessed at up front).

| Phase | Deliverable | Plan status |
| -- | -- | -- |
| **1** | `Request` wrapper + `Signature` primitive (parametric HMAC: digests, encodings, prefix, multi-candidate, replay window, constant-time) | **Detailed below** |
| 2 | Verifier registry (`Axn::Webhooks.configure` / `c.verifier`) + `verify` DSL + `:hmac` and `:standard_webhooks` strategies + custom/SDK-delegating slot | Roadmap below → detailed after Phase 1 |
| 3 | `dispatch` DSL (`to` / `on` / `otherwise` / `with` / `via`) as an Axn; explicit-map baseline + convention sugar | Roadmap below |
| 4 | `respond` + staged-outcome model; wire verify→dispatch→respond as a composed Axn pipeline; `mode:` sync/async seam | Roadmap below |
| 5 | Rack mount (`Axn::Webhooks::Inbound[:vendor]`, `call(env)`), `challenge` GET branch, config-driven `vendor_facet` (`setting`, default `false`) | Roadmap below |

Phases 2–5 roadmaps are at the end of this document — enough to see the whole arc and validate Phase 1's interfaces, without fabricated complete-code tasks for APIs that don't exist yet.

---

## File Structure (Phase 1)

- Create `lib/axn/webhooks/request.rb` — the Rails-agnostic `Request` value object (`raw_body`, `header`, `params`, `url`, `http_method`). One responsibility: normalize an inbound request into what verifiers/dispatchers read. Phase 5 will add a `.from_rack(env)` constructor; Phase 1 constructs it directly.
- Create `lib/axn/webhooks/signature.rb` — the `Signature` module: the pure parametric-HMAC primitive + constant-time compare + encoders. No Request, no Rack, no axn — just bytes in, boolean out. This is the shared primitive both inbound `verify` and future outbound `sign` build on (Decision 8).
- Modify `lib/axn/webhooks.rb` — `require_relative` the two new files.
- Modify `CHANGELOG.md` — `## [Unreleased]` entries.
- Test `spec/axn/webhooks/request_spec.rb`
- Test `spec/axn/webhooks/signature_spec.rb`

---

## Task 1: `Request` wrapper

A thin, immutable value object. Header lookup is **case-insensitive** (Rack upcases/prefixes headers; vendors document mixed case). Everything else is a plain reader.

**Files:**
- Create: `lib/axn/webhooks/request.rb`
- Modify: `lib/axn/webhooks.rb`
- Test: `spec/axn/webhooks/request_spec.rb`

**Interfaces:**
- Consumes: nothing (leaf).
- Produces:
  - `Axn::Webhooks::Request.new(raw_body:, headers: {}, params: {}, url: nil, http_method: "POST")`
  - `#raw_body → String` (may be binary; never re-encoded)
  - `#header(name) → String | nil` (case-insensitive)
  - `#params → Hash` (frozen dup)
  - `#url → String | nil`
  - `#http_method → String` (upcased, e.g. `"POST"`)

- [ ] **Step 1: Write the failing test**

```ruby
# spec/axn/webhooks/request_spec.rb
# frozen_string_literal: true

RSpec.describe Axn::Webhooks::Request do
  subject(:request) do
    described_class.new(
      raw_body: '{"a":1}',
      headers: { "Content-Type" => "application/json", "X-Merge-Webhook-Signature" => "abc" },
      params: { "challenge" => "xyz" },
      url: "https://example.com/webhooks/merge",
      http_method: "post",
    )
  end

  it "exposes the raw body verbatim" do
    expect(request.raw_body).to eq('{"a":1}')
  end

  it "looks up headers case-insensitively" do
    expect(request.header("x-merge-webhook-signature")).to eq("abc")
    expect(request.header("X-MERGE-WEBHOOK-SIGNATURE")).to eq("abc")
    expect(request.header("Content-Type")).to eq("application/json")
  end

  it "returns nil for an unknown header" do
    expect(request.header("X-Absent")).to be_nil
  end

  it "exposes params, url, and an upcased http_method" do
    expect(request.params).to eq("challenge" => "xyz")
    expect(request.url).to eq("https://example.com/webhooks/merge")
    expect(request.http_method).to eq("POST")
  end

  it "defaults params to empty and http_method to POST" do
    bare = described_class.new(raw_body: "")
    expect(bare.params).to eq({})
    expect(bare.http_method).to eq("POST")
    expect(bare.header("anything")).to be_nil
  end

  it "does not let callers mutate internal params" do
    expect { request.params["injected"] = true }.to raise_error(FrozenError)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/webhooks/request_spec.rb`
Expected: FAIL — `uninitialized constant Axn::Webhooks::Request`.

- [ ] **Step 3: Write minimal implementation**

```ruby
# lib/axn/webhooks/request.rb
# frozen_string_literal: true

module Axn
  module Webhooks
    # A Rails-agnostic view of an inbound webhook request. Verifiers and dispatchers read
    # only from this object, so the same pipeline works behind a Rack mount, a controller,
    # or a plain test constructor. Header lookup is case-insensitive.
    class Request
      def initialize(raw_body:, headers: {}, params: {}, url: nil, http_method: "POST")
        @raw_body = raw_body
        @headers = headers.each_with_object({}) { |(k, v), h| h[k.to_s.downcase] = v }
        @params = (params || {}).dup.freeze
        @url = url
        @http_method = http_method.to_s.upcase
      end

      attr_reader :raw_body, :params, :url, :http_method

      def header(name)
        @headers[name.to_s.downcase]
      end
    end
  end
end
```

Then wire it up:

```ruby
# lib/axn/webhooks.rb — add below the existing `require_relative "webhooks/version"`
require_relative "webhooks/request"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/axn/webhooks/request_spec.rb`
Expected: PASS (6 examples, 0 failures).

- [ ] **Step 5: Update CHANGELOG and commit**

Add under `## [Unreleased]` in `CHANGELOG.md`:

```markdown
### Added
- `Axn::Webhooks::Request` — a Rails-agnostic wrapper (`raw_body`, `header`, `params`, `url`, `http_method`) that verifiers and dispatchers read from.
```

```bash
git add lib/axn/webhooks/request.rb lib/axn/webhooks.rb spec/axn/webhooks/request_spec.rb CHANGELOG.md
git commit -m "feat: add Rails-agnostic Request wrapper"
```

---

## Task 2: `Signature.hmac` — compute, encode, and constant-time compare

The parametric HMAC core: given the already-assembled signing bytes (`payload`) and the candidate `signature` header value, compute the expected HMAC and constant-time-compare. Supports multiple digests, three encodings, an optional per-candidate `prefix` (e.g. Slack's `v0=`), and **multiple candidate signatures** in one header (space/comma separated — key rotation & Standard Webhooks). Replay/timestamp handling is added in Task 3.

**Design decisions locked here:**
- The primitive takes **concrete bytes**, not procs or a `Request`. The Phase 2 `verify` DSL resolves `signing_string: ->(r){…}` and `signature: header("…")` against a `Request` and calls this with plain strings. Clean separation: this file has zero knowledge of requests.
- Empty/nil `signature` → `false` (never raises on hostile input).
- Comparison is `OpenSSL.fixed_length_secure_compare`, guarded by a bytesize check (it raises on length mismatch) — the length guard returns `false`, never leaks via exception.

**Files:**
- Create: `lib/axn/webhooks/signature.rb`
- Modify: `lib/axn/webhooks.rb`
- Test: `spec/axn/webhooks/signature_spec.rb`

**Interfaces:**
- Consumes: nothing (leaf; stdlib only).
- Produces:
  - `Axn::Webhooks::Signature.hmac(secret:, payload:, signature:, digest: :sha256, encoding: :hex, prefix: nil) → Boolean`
  - `Axn::Webhooks::Signature.compute(secret:, payload:, digest: :sha256, encoding: :hex) → String` (the encoded expected signature; reused by future outbound `sign`)
  - `Axn::Webhooks::Signature.secure_compare(a, b) → Boolean` (constant-time; `false` on length mismatch or nil)
  - Supported `digest:` — `:sha256` (default), `:sha1`, `:md5`. Supported `encoding:` — `:hex` (default), `:base64`, `:base64_urlsafe`.

- [ ] **Step 1: Write the failing test**

The hardcoded anchor is **RFC 4231 Test Case 2** (`key="Jefe"`, `data="what do ya want for nothing?"`), whose HMAC-SHA256 hex is a published, trustworthy value — it catches any digest/encoding regression. Base64 variants are cross-checked against stdlib within the test.

```ruby
# spec/axn/webhooks/signature_spec.rb
# frozen_string_literal: true

require "openssl"
require "base64"

RSpec.describe Axn::Webhooks::Signature do
  # RFC 4231 Test Case 2 — a published, independent HMAC-SHA256 vector.
  let(:secret)  { "Jefe" }
  let(:payload) { "what do ya want for nothing?" }
  let(:hex)     { "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843" }

  describe ".compute" do
    it "produces the RFC 4231 hex vector for sha256" do
      expect(described_class.compute(secret:, payload:, digest: :sha256, encoding: :hex)).to eq(hex)
    end

    it "encodes as standard and url-safe base64 of the same digest bytes" do
      raw = OpenSSL::HMAC.digest("SHA256", secret, payload)
      expect(described_class.compute(secret:, payload:, encoding: :base64)).to eq(Base64.strict_encode64(raw))
      expect(described_class.compute(secret:, payload:, encoding: :base64_urlsafe)).to eq(Base64.urlsafe_encode64(raw))
    end

    it "supports sha1 and md5 digests" do
      expect(described_class.compute(secret:, payload:, digest: :sha1))
        .to eq(OpenSSL::HMAC.hexdigest("SHA1", secret, payload))
      expect(described_class.compute(secret:, payload:, digest: :md5))
        .to eq(OpenSSL::HMAC.hexdigest("MD5", secret, payload))
    end
  end

  describe ".hmac" do
    it "accepts a matching signature" do
      expect(described_class.hmac(secret:, payload:, signature: hex)).to be(true)
    end

    it "rejects a tampered signature" do
      bad = hex.sub(/.\z/, "0" == hex[-1] ? "1" : "0")
      expect(described_class.hmac(secret:, payload:, signature: bad)).to be(false)
    end

    it "rejects a wrong secret" do
      expect(described_class.hmac(secret: "wrong", payload:, signature: hex)).to be(false)
    end

    it "rejects nil / empty signatures without raising" do
      expect(described_class.hmac(secret:, payload:, signature: nil)).to be(false)
      expect(described_class.hmac(secret:, payload:, signature: "")).to be(false)
    end

    it "strips a prefix before comparing (Slack-style v0=)" do
      expect(described_class.hmac(secret:, payload:, signature: "v0=#{hex}", prefix: "v0=")).to be(true)
      expect(described_class.hmac(secret:, payload:, signature: hex, prefix: "v0=")).to be(false)
    end

    it "passes if ANY candidate in a multi-signature header matches (key rotation)" do
      expect(described_class.hmac(secret:, payload:, signature: "deadbeef #{hex}")).to be(true)
      expect(described_class.hmac(secret:, payload:, signature: "deadbeef,#{hex}")).to be(true)
      expect(described_class.hmac(secret:, payload:, signature: "deadbeef cafebabe")).to be(false)
    end

    it "verifies a base64-urlsafe signature (Merge-style)" do
      raw = OpenSSL::HMAC.digest("SHA256", secret, payload)
      sig = Base64.urlsafe_encode64(raw)
      expect(described_class.hmac(secret:, payload:, signature: sig, encoding: :base64_urlsafe)).to be(true)
    end
  end

  describe ".secure_compare" do
    it "is true only for identical strings" do
      expect(described_class.secure_compare("abc", "abc")).to be(true)
      expect(described_class.secure_compare("abc", "abd")).to be(false)
    end

    it "is false (never raises) for length mismatch or nil" do
      expect(described_class.secure_compare("abc", "abcd")).to be(false)
      expect(described_class.secure_compare(nil, "abc")).to be(false)
      expect(described_class.secure_compare("abc", nil)).to be(false)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/webhooks/signature_spec.rb`
Expected: FAIL — `uninitialized constant Axn::Webhooks::Signature`.

- [ ] **Step 3: Write minimal implementation**

```ruby
# lib/axn/webhooks/signature.rb
# frozen_string_literal: true

require "openssl"
require "base64"

module Axn
  module Webhooks
    # The shared HMAC primitive. Pure functions over bytes — no Request, no Rack, no axn.
    # Both inbound `verify` and (future) outbound `sign` build on this. ALWAYS constant-time.
    module Signature
      DIGESTS = { sha256: "SHA256", sha1: "SHA1", md5: "MD5" }.freeze

      module_function

      # Verify a candidate signature header against the HMAC of `payload`.
      # `signature` may hold several whitespace/comma-separated candidates (key rotation);
      # returns true if ANY matches. Never raises on hostile input.
      def hmac(secret:, payload:, signature:, digest: :sha256, encoding: :hex, prefix: nil)
        return false if signature.nil? || signature.to_s.empty?

        expected = compute(secret:, payload:, digest:, encoding:)
        candidates(signature, prefix:).any? { |candidate| secure_compare(candidate, expected) }
      end

      # The encoded expected signature for `payload`. Reused by future outbound signing.
      def compute(secret:, payload:, digest: :sha256, encoding: :hex)
        raw = OpenSSL::HMAC.digest(openssl_digest(digest), secret, payload.to_s)
        encode(raw, encoding)
      end

      # Constant-time comparison. False (never raises) on nil or length mismatch.
      def secure_compare(candidate, expected)
        return false if candidate.nil? || expected.nil?
        return false unless candidate.bytesize == expected.bytesize

        OpenSSL.fixed_length_secure_compare(candidate, expected)
      end

      def openssl_digest(digest)
        DIGESTS.fetch(digest) { raise ArgumentError, "unsupported digest: #{digest.inspect}" }
      end
      private_class_method :openssl_digest

      def encode(raw, encoding)
        case encoding
        when :hex            then raw.unpack1("H*")
        when :base64         then Base64.strict_encode64(raw)
        when :base64_urlsafe then Base64.urlsafe_encode64(raw)
        else raise ArgumentError, "unsupported encoding: #{encoding.inspect}"
        end
      end
      private_class_method :encode

      def candidates(signature, prefix:)
        signature.to_s.split(/[\s,]+/).reject(&:empty?).map do |token|
          prefix && token.start_with?(prefix) ? token.delete_prefix(prefix) : token
        end
      end
      private_class_method :candidates
    end
  end
end
```

Then wire it up:

```ruby
# lib/axn/webhooks.rb — add below `require_relative "webhooks/request"`
require_relative "webhooks/signature"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/axn/webhooks/signature_spec.rb`
Expected: PASS (all examples green).

- [ ] **Step 5: Update CHANGELOG and commit**

Add under `## [Unreleased]` → `### Added` in `CHANGELOG.md`:

```markdown
- `Axn::Webhooks::Signature` — parametric HMAC primitive (`hmac` / `compute` / `secure_compare`) with sha256/sha1/md5 digests; hex, base64, and base64-urlsafe encodings; prefix stripping; multi-candidate (key-rotation) headers; always constant-time.
```

```bash
git add lib/axn/webhooks/signature.rb lib/axn/webhooks.rb spec/axn/webhooks/signature_spec.rb CHANGELOG.md
git commit -m "feat: add parametric HMAC Signature primitive"
```

---

## Task 3: `Signature` replay window

Add optional timestamp/tolerance replay protection (Lob & Slack require a 5-minute window; Standard Webhooks uses a bidirectional tolerance). This is a **separate, composable check** layered onto `hmac` — the timestamp value is passed in by the caller (the Phase 2 DSL resolves it from a header), and the window check is independent of the secret.

**Files:**
- Modify: `lib/axn/webhooks/signature.rb`
- Test: `spec/axn/webhooks/signature_spec.rb`

**Interfaces:**
- Consumes: `Signature.hmac` (Task 2).
- Produces:
  - `Signature.hmac(..., timestamp: nil, tolerance: nil, now: Time.now) → Boolean` — when `tolerance` is set, returns `false` if `timestamp` is missing/unparseable or `|now - timestamp| > tolerance` seconds; the HMAC check still runs. `timestamp` accepts an epoch Integer, an epoch String, or a `Time`.
  - `Signature.within_tolerance?(timestamp:, tolerance:, now: Time.now) → Boolean`

- [ ] **Step 1: Write the failing test**

```ruby
# spec/axn/webhooks/signature_spec.rb — append inside the top-level describe
  describe "replay window" do
    let(:secret)  { "Jefe" }
    let(:payload) { "what do ya want for nothing?" }
    let(:hex)     { "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843" }
    let(:now)     { Time.at(1_700_000_000) }

    it "accepts a signature whose timestamp is within tolerance" do
      ts = (now - 60).to_i
      expect(described_class.hmac(secret:, payload:, signature: hex, timestamp: ts, tolerance: 300, now:)).to be(true)
    end

    it "rejects a signature whose timestamp is outside tolerance (replay)" do
      ts = (now - 600).to_i
      expect(described_class.hmac(secret:, payload:, signature: hex, timestamp: ts, tolerance: 300, now:)).to be(false)
    end

    it "rejects future timestamps beyond tolerance (bidirectional)" do
      ts = (now + 600).to_i
      expect(described_class.hmac(secret:, payload:, signature: hex, timestamp: ts, tolerance: 300, now:)).to be(false)
    end

    it "rejects a missing or unparseable timestamp when tolerance is set" do
      expect(described_class.hmac(secret:, payload:, signature: hex, timestamp: nil, tolerance: 300, now:)).to be(false)
      expect(described_class.hmac(secret:, payload:, signature: hex, timestamp: "not-a-time", tolerance: 300, now:)).to be(false)
    end

    it "accepts a String epoch and a Time" do
      expect(described_class.within_tolerance?(timestamp: (now - 10).to_i.to_s, tolerance: 300, now:)).to be(true)
      expect(described_class.within_tolerance?(timestamp: now - 10, tolerance: 300, now:)).to be(true)
    end

    it "ignores the window entirely when tolerance is nil" do
      expect(described_class.hmac(secret:, payload:, signature: hex, timestamp: nil, tolerance: nil, now:)).to be(true)
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/webhooks/signature_spec.rb -e "replay window"`
Expected: FAIL — `unknown keyword: :timestamp` (and `within_tolerance?` undefined).

- [ ] **Step 3: Write minimal implementation**

Update `hmac` and add `within_tolerance?` in `lib/axn/webhooks/signature.rb`:

```ruby
      def hmac(secret:, payload:, signature:, digest: :sha256, encoding: :hex, prefix: nil,
               timestamp: nil, tolerance: nil, now: nil)
        return false if signature.nil? || signature.to_s.empty?
        return false if tolerance && !within_tolerance?(timestamp:, tolerance:, now: now || Time.now)

        expected = compute(secret:, payload:, digest:, encoding:)
        candidates(signature, prefix:).any? { |candidate| secure_compare(candidate, expected) }
      end

      # True when `timestamp` is present, parseable, and within ±tolerance seconds of `now`.
      def within_tolerance?(timestamp:, tolerance:, now: nil)
        epoch = coerce_epoch(timestamp)
        return false if epoch.nil?

        ((now || Time.now).to_i - epoch).abs <= tolerance.to_i
      end

      def coerce_epoch(timestamp)
        case timestamp
        when Time    then timestamp.to_i
        when Integer then timestamp
        when String  then (Integer(timestamp, 10) if timestamp.match?(/\A-?\d+\z/))
        end
      end
      private_class_method :coerce_epoch
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/axn/webhooks/signature_spec.rb`
Expected: PASS (all examples, including the new `replay window` group).

- [ ] **Step 5: Update CHANGELOG and commit**

Append to the `Signature` bullet under `## [Unreleased]`:

```markdown
- `Axn::Webhooks::Signature` replay protection — optional `timestamp:` / `tolerance:` bidirectional window (`within_tolerance?`), accepting epoch Integer/String or `Time`.
```

```bash
git add lib/axn/webhooks/signature.rb spec/axn/webhooks/signature_spec.rb CHANGELOG.md
git commit -m "feat: add replay-window protection to Signature"
```

---

## Task 4: Phase 1 wrap-up — full suite + rubocop + README seam

Confirm the crypto core is green end-to-end and document the two public entry points so Phase 2 has a stable surface to build on.

**Files:**
- Modify: `README.md`
- (No new code.)

- [ ] **Step 1: Run the full default task**

Run: `bundle exec rake`
Expected: all specs pass, rubocop clean. Fix any rubocop offenses in the new files (e.g. frozen-string, method length) before proceeding.

- [ ] **Step 2: Add a short "Signature primitive" section to `README.md`**

```markdown
## Signature primitive

`Axn::Webhooks::Signature` is a standalone, Rails-agnostic HMAC verifier:

​```ruby
Axn::Webhooks::Signature.hmac(
  secret:    ENV["WEBHOOK_SECRET"],
  payload:   request.raw_body,                 # exact bytes the vendor signed
  signature: request.header("X-Signature"),
  digest:    :sha256,                           # :sha256 (default) | :sha1 | :md5
  encoding:  :hex,                              # :hex (default) | :base64 | :base64_urlsafe
  prefix:    nil,                               # e.g. "v0=" for Slack
  timestamp: request.header("X-Timestamp"),     # optional replay guard
  tolerance: 300,
)
​```

It always uses a constant-time comparison and supports multi-signature (key-rotation) headers.
```

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: document Signature primitive; close Phase 1"
```

---

# Phases 2–5 Roadmap

Each becomes its own fully-detailed plan (TDD, complete code) once the prior phase lands. Interfaces below are the contract Phase 1 was designed against — validate them as you go.

## Phase 2 — Verifier registry + `verify` DSL

- **Registry — reconcile the spec's illustrative `c.verifier` with axn's real primitives (design task).** The spec sketches `Axn::Webhooks.configure do |c| c.verifier :merge, … end`, but that's *illustrative*, not a mandate to hand-roll a config DSL. A vendor endpoint is a named, mountable unit (verify + dispatch + respond) — closer to `axn-ruby_llm`'s `include Axn::Mountable` + `mount_axn :ask, Ask` than to a scalar `setting`. Prefer: define each vendor endpoint as its own mountable Axn definition, register/look it up via `Axn::Webhooks::Inbound[:vendor]`, and keep scalar tunables (below) as `setting`s. Only the per-vendor **secret/verifier wiring** needs a small registry; build it on axn affordances (`Mountable`, per-class `configure(:webhooks)`, or a process-global registry à la `Axn.register_tool_adapter`) rather than a bespoke block DSL. Resolve the exact shape via TDD at the top of Phase 2 and record the decision. One auditable crypto/secrets surface remains the goal.
- **Scalar settings (declare via `setting`, `config_namespace :webhooks` already set):** e.g. `default_tolerance` (replay window), `error_headline` (cf. `axn-ruby_llm`). Add as needed, each with `default:` and `one_of:`/`validate:` where a small enum applies.
- **`:hmac` strategy:** resolves `signing_string:` / `signature:` / `timestamp:` procs against a `Request`, then calls `Signature.hmac`. Covers Merge/Lob/MT/Slack/Nylas in a few lines each.
- **`:standard_webhooks` preset:** `whsec_`-strip + base64-decode secret, `id.timestamp.body` signing string, per-candidate `v1,` version handling, bidirectional tolerance (reuses `Signature`/`within_tolerance?`). Drops the `svix` gem.
- **Custom / SDK-delegating slot:** a block verifier (`c.verifier(:twilio) { |req| Twilio::Security::RequestValidator... }`) is a first-class registry entry — same slot as any preset.
- **Outcome:** verification yields a `fail!` on mismatch (→ 401, quiet) vs a raise on verifier crash (→ 401 external, loud/reported) — the first two rows of the staged-outcome table.
- **Interface Phase 3 consumes:** `Axn::Webhooks::Inbound[:vendor]` grows a `verify`-capable definition; a `Verify` Axn taking `request:` and failing/ok-ing.

## Phase 3 — `dispatch` DSL

- `dispatch to:` (one endpoint → one handler), `dispatch on: ->(e){…}, to: {map}, otherwise: :ack|:notify`, tuple keys, `via:` convention transform, `with:` extractor proc (adapts a reused scalar domain axn at the boundary).
- Baseline is the **explicit map** (greppable; avoids `const_get` fragility). Convention sugar (String namespace + `via:`) resolves a class from the key with a **loud miss** on failure.
- Payload → handler: pass the raw parsed body as `event:`; webhook-native handlers destructure with axn `on:` subfields; missing handler class → exception (5xx + report).
- Built as an Axn; separates verify from parse (parse the raw bytes only *after* verification).

## Phase 4 — `respond` + staged-outcome pipeline

- Compose verify → dispatch → respond as an axn pipeline (via `steps`/`mount_axn`).
- `respond ->(r){…}` maps a handler `Result` to an HTTP response; default is a bare 2xx ack. Two real variants: DropboxSign literal string, Twilio TwiML.
- Implement the **`mode:` seam** — `:async` default calls `.call_async`; a result-reading `respond` forces `:sync` (`.call`). (No axn `mode:` kwarg exists — the gem owns this choice.)
- Wire the full staged-outcome table: `fail!` (quiet 2xx/401) vs raise (loud 5xx/401 + `on_exception`). **Fixes Lob's 422-on-failure retry-storm bug.**

## Phase 5 — Rack mount + challenge + observability

- `Axn::Webhooks::Inbound[:vendor]` → a Rack app (`call(env)`) that builds a `Request` from `env` (pristine `rack.input` raw body — the reason for mount-first) and runs the pipeline. `Request.from_rack(env)` constructor added here.
- `mount Axn::Webhooks::Inbound[:codat], at: "/webhooks/codat"` — routes.rb becomes the single greppable webhook registry.
- `challenge ->(req){…}` installs the endpoint's `GET` branch internally (echo `?challenge=`, optional `if:` token check); `GET` w/o challenge → 405; `POST` → pipeline.
- **Vendor facet is config-driven, off by default.** Declare `setting :vendor_facet, default: false, one_of: [false, :dimension, :tag], overridable: true`. When set, the mount stamps the registry name onto the pipeline as that facet — `:dimension` → `dimension :vendor, <name>` (bounded, low-cardinality; feeds PRO-2818 Datadog/OTel), `:tag` → `tag :vendor, <name>` (higher-cardinality path), `false` → no facet. **Teamshares usage sets `:dimension`**; the gem ships `false` so a standalone consumer opts in. (Revises the spec's "auto-`dimension`, zero-config" to a config switch per updated decision.)
- Confirm no vendor forces the controller concern over the mount.

---

## Self-Review (Phase 1)

- **Spec coverage (Phase 1 scope):** `Request` wrapper (`raw_body`/`header`/`params`/`url`) ✅ Task 1; parametric HMAC with digest/signing_string/encoding/prefix/multi-sig ✅ Task 2; replay window ✅ Task 3; constant-time always ✅ Task 2/3; shared `Signature` primitive for future outbound `sign` ✅ (`compute` is the reusable face). Phases 2–5 spec sections are mapped in the roadmap, each to a future plan.
- **Placeholder scan:** none — every code step carries complete, runnable code and exact commands.
- **Type consistency:** `Request.new` kwargs and readers match between Task 1 and the roadmap's Phase 2/5 consumers; `Signature.hmac`/`compute`/`secure_compare`/`within_tolerance?` signatures are identical across Tasks 2–3 and the README. `http_method` (not `method`, to avoid shadowing `Object#method`) used consistently.
```
