# axn-webhooks Inbound — Phase 2 (verifier registry + `verify` DSL) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the verify half of `axn-webhooks` inbound: a block-per-endpoint registration DSL (`Axn::Webhooks.inbound :vendor do verify … end`), an endpoint registry (`Axn::Webhooks::Inbound[:vendor]`), and the `:hmac` + `:standard_webhooks` verifier strategies plus a custom/SDK verifier slot — all built as Axns on top of the Phase 1 `Signature` primitive.

**Architecture:** Each `inbound` block is evaluated at boot against a small DSL that captures a `verify` declaration and exposes request resolvers (`header`, `raw_body`, …). The declaration is compiled into a verifier callable `->(request){ Boolean }` (custom block verbatim, or a registered strategy built from resolved options calling `Signature.hmac`). An `Endpoint` runs that verifier through a `Verify` Axn so a mismatch is a quiet `fail!` and a verifier crash is a loud exception (the first two rows of the staged-outcome model). Endpoints register in a process-global registry keyed by vendor symbol.

**Tech Stack:** Ruby ≥ 3.2.1, `axn`, `OpenSSL`/`Base64` (stdlib). No Rails required.

**Spec:** `docs/superpowers/specs/2026-07-17-axn-webhooks-inbound-design.md` — read the **"Amendment — Phase 2 public API (settled 2026-07-18)"** section at the top; it is the binding API decision this plan implements. Phase 1 (`Request`, `Signature`) is already merged to `main`.

## Global Constraints

Every task's requirements implicitly include these:

- **Ruby ≥ 3.2.1.** Dependencies: `axn` + stdlib only. No teamshares-rails/ActionController; no unguarded `Rails`/`ActiveRecord`/`ActiveJob`.
- **All signature comparison goes through Phase 1's `Axn::Webhooks::Signature`** (which is constant-time). Never compare signatures with `==`, and never re-implement HMAC — build strategies on `Signature.hmac`/`Signature.compute`/`Signature.secure_compare`.
- **Public API is block-per-endpoint:** `Axn::Webhooks.inbound(:vendor) { verify … }` registers; `Axn::Webhooks::Inbound[:vendor]` looks up. Not nested inside `configure` (axn's `Configurable` owns `configure`/`config` for scalar settings).
- **Staged outcome (verify rows):** a signature **mismatch** is a `fail!` (quiet — no `on_exception`); a verifier that **raises** stays an exception (loud/reported). This falls out of building verify as an Axn — do not rescue inside the verifier to convert crashes into `false`.
- **Secrets:** options accept a literal (boot-time `ENV.fetch`) or a callable resolved at request time; the DSL never reads secrets itself.
- **Registry is process-global and test-resettable** (`Axn::Webhooks::Inbound.reset!`); every spec that registers endpoints must reset in an `after` hook for isolation.
- **CHANGELOG:** every user-visible change under `## [Unreleased]`.
- **Definition of done for any task:** `bundle exec rake verify` (library specs + Rails dummy-app specs + rubocop) is green.
- **TDD:** failing test first, always.

## Grounding notes (verified against the installed `axn`)

- `include Axn` gives the `expects`/`exposes`/`call` contract; `Foo.call(**kw)` returns an `Axn::Result` and never raises for ordinary failures. `fail!("msg")` → `outcome.failure?` (quiet); any other raise → `outcome.exception?` with the original on `result.exception` (reported to `Axn.config.on_exception`). This is exactly the verify staged-outcome split. Source: axn `AGENTS-consuming.md`.
- A **non-lambda Proc with required keyword args raises `ArgumentError`** when a required key is missing or an unknown key is passed — we rely on this so a strategy builder block surfaces a missing/typo'd `verify` option as a loud developer error.
- `Result#outcome` is a string-inquirer: `outcome.success?`/`failure?`/`exception?`. `result.exception` holds a swallowed exception (for tests).

---

## File Structure (Phase 2)

- Create `lib/axn/webhooks/resolvers.rb` — `Resolver` value + `Resolvers.{header,raw_body,params,url,resolve}`. One responsibility: deferred request-value lookup used inside an `inbound` block.
- Create `lib/axn/webhooks/verify.rb` — the `Verify` Axn (mismatch → `fail!`; crash → exception).
- Create `lib/axn/webhooks/verifiers.rb` — the strategy registry + `build` (custom block verbatim; strategy lookup).
- Create `lib/axn/webhooks/verifiers/hmac.rb` — the `:hmac` strategy.
- Create `lib/axn/webhooks/verifiers/standard_webhooks.rb` — the `:standard_webhooks` strategy + `StandardWebhooks` helpers.
- Create `lib/axn/webhooks/inbound.rb` — the `Inbound` registry + `Axn::Webhooks.inbound` entry point.
- Create `lib/axn/webhooks/inbound/endpoint.rb` — the `Endpoint` (`#verify(request) => Axn::Result`).
- Create `lib/axn/webhooks/inbound/dsl.rb` — the block receiver (captures `verify`; exposes resolvers).
- Modify `lib/axn/webhooks.rb` — `require_relative` the new files (in dependency order).
- Modify `CHANGELOG.md`.
- Tests under `spec/axn/webhooks/`.

Require order in `lib/axn/webhooks.rb` (each task adds its line as it lands): `resolvers`, `verify`, `verifiers`, `verifiers/hmac`, `verifiers/standard_webhooks`, `inbound`.

---

## Task 1: Resolvers

Deferred request-value lookups. `header("X-Sig")` inside an `inbound` block returns a `Resolver` that, at verify time, pulls that header off the `Request`. `Resolvers.resolve` also passes through literals and no-arg callables so `secret:` can be a string or a `-> { ENV.fetch(...) }`.

**Files:**
- Create: `lib/axn/webhooks/resolvers.rb`
- Modify: `lib/axn/webhooks.rb`
- Test: `spec/axn/webhooks/resolvers_spec.rb`

**Interfaces:**
- Consumes: `Axn::Webhooks::Request` (Phase 1).
- Produces:
  - `Axn::Webhooks::Resolver.new { |request| … }` with `#call(request)`.
  - `Axn::Webhooks::Resolvers.header(name) / .raw_body / .params / .url → Resolver`
  - `Axn::Webhooks::Resolvers.resolve(value, request)` — `Resolver` → `call(request)`; `Symbol` → `request.public_send(sym)`; `Proc` → `call(request)` (arity 0 → `call`); else the literal.

- [ ] **Step 1: Write the failing test**

```ruby
# spec/axn/webhooks/resolvers_spec.rb
# frozen_string_literal: true

RSpec.describe Axn::Webhooks::Resolvers do
  let(:request) do
    Axn::Webhooks::Request.new(
      raw_body: '{"a":1}',
      headers: { "X-Sig" => "abc" },
      params: { "challenge" => "xyz" },
      url: "https://example.com/hook",
    )
  end

  describe "request resolvers" do
    it "reads a header at resolve time" do
      expect(described_class.header("X-Sig").call(request)).to eq("abc")
    end

    it "reads raw_body, params, and url" do
      expect(described_class.raw_body.call(request)).to eq('{"a":1}')
      expect(described_class.params.call(request)).to eq("challenge" => "xyz")
      expect(described_class.url.call(request)).to eq("https://example.com/hook")
    end
  end

  describe ".resolve" do
    it "calls a Resolver with the request" do
      expect(described_class.resolve(described_class.header("X-Sig"), request)).to eq("abc")
    end

    it "treats a Symbol as a request reader" do
      expect(described_class.resolve(:raw_body, request)).to eq('{"a":1}')
    end

    it "calls a 1-arg proc with the request and a 0-arg proc with nothing" do
      expect(described_class.resolve(->(r) { r.url }, request)).to eq("https://example.com/hook")
      expect(described_class.resolve(-> { "boot-secret" }, request)).to eq("boot-secret")
    end

    it "passes literals through unchanged" do
      expect(described_class.resolve("literal", request)).to eq("literal")
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/webhooks/resolvers_spec.rb`
Expected: FAIL — `uninitialized constant Axn::Webhooks::Resolvers`.

- [ ] **Step 3: Write minimal implementation**

```ruby
# lib/axn/webhooks/resolvers.rb
# frozen_string_literal: true

module Axn
  module Webhooks
    # A deferred request-value lookup used inside an `inbound` block, e.g.
    # `verify :hmac, signature: header("X-Sig")`. Called with the Request at verify time.
    class Resolver
      def initialize(&blk)
        @blk = blk
      end

      def call(request) = @blk.call(request)
    end

    module Resolvers
      module_function

      def header(name) = Resolver.new { |req| req.header(name) }
      def raw_body     = Resolver.new(&:raw_body)
      def params       = Resolver.new(&:params)
      def url          = Resolver.new(&:url)

      # Resolve a declared value against the request:
      #   Resolver -> call(request); Symbol -> request.public_send(sym);
      #   Proc -> call(request) (or call for a 0-arity proc); else the literal.
      def resolve(value, request)
        case value
        when Resolver then value.call(request)
        when Symbol   then request.public_send(value)
        when Proc     then value.arity.zero? ? value.call : value.call(request)
        else value
        end
      end
    end
  end
end
```

```ruby
# lib/axn/webhooks.rb — add below `require_relative "webhooks/signature"`
require_relative "webhooks/resolvers"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/axn/webhooks/resolvers_spec.rb`
Expected: PASS.

- [ ] **Step 5: Update CHANGELOG and commit**

Add under `## [Unreleased]` → `### Added`:

```markdown
- `Axn::Webhooks::Resolvers` — deferred request-value lookups (`header`/`raw_body`/`params`/`url`) and a `resolve` helper used by the `inbound` DSL and verifier strategies.
```

```bash
git add lib/axn/webhooks/resolvers.rb lib/axn/webhooks.rb spec/axn/webhooks/resolvers_spec.rb CHANGELOG.md
git commit -m "feat: add request resolvers for the inbound DSL"
```

---

## Task 2: `Verify` Axn

The verify stage as an Axn, so the staged-outcome split is axn's native failure-vs-exception semantics: a signature **mismatch** is a `fail!` (quiet), a verifier that **raises** stays an exception (loud/reported). It takes the `Request` and an already-built verifier callable.

**Files:**
- Create: `lib/axn/webhooks/verify.rb`
- Modify: `lib/axn/webhooks.rb`
- Test: `spec/axn/webhooks/verify_spec.rb`

**Interfaces:**
- Consumes: `Axn::Webhooks::Request`; a verifier callable `->(request){ Boolean }`.
- Produces:
  - `Axn::Webhooks::Verify.call(request:, verifier:) → Axn::Result` — `ok?` true when the verifier returns truthy; `outcome.failure?` on falsey (mismatch); `outcome.exception?` when the verifier raises (original on `result.exception`).

- [ ] **Step 1: Write the failing test**

```ruby
# spec/axn/webhooks/verify_spec.rb
# frozen_string_literal: true

RSpec.describe Axn::Webhooks::Verify do
  let(:request) { Axn::Webhooks::Request.new(raw_body: "body", headers: { "X-Token" => "ok" }) }

  it "succeeds when the verifier returns truthy" do
    result = described_class.call(request:, verifier: ->(req) { req.header("X-Token") == "ok" })
    expect(result).to be_ok
  end

  it "fails quietly (failure, not exception) on a signature mismatch" do
    result = described_class.call(request:, verifier: ->(_req) { false })
    expect(result).not_to be_ok
    expect(result.outcome).to be_failure
    expect(result.outcome).not_to be_exception
    expect(result.error).to include("verification failed")
  end

  it "surfaces a verifier crash as an exception (loud), preserving the error" do
    boom = Class.new(StandardError)
    result = described_class.call(request:, verifier: ->(_req) { raise boom, "bad header" })
    expect(result).not_to be_ok
    expect(result.outcome).to be_exception
    expect(result.exception).to be_a(boom)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/webhooks/verify_spec.rb`
Expected: FAIL — `uninitialized constant Axn::Webhooks::Verify`.

- [ ] **Step 3: Write minimal implementation**

```ruby
# lib/axn/webhooks/verify.rb
# frozen_string_literal: true

module Axn
  module Webhooks
    # The verify stage, as an Axn. A signature mismatch is a quiet failure (`fail!` →
    # 401 later, no on_exception page); a verifier that raises is a loud exception
    # (reported to Axn.config.on_exception). The first two rows of the staged-outcome model.
    class Verify
      include Axn

      expects :request, type: Axn::Webhooks::Request
      expects :verifier
      error "Webhook signature verification failed"

      def call
        fail!("signature mismatch") unless verifier.call(request)
      end
    end
  end
end
```

```ruby
# lib/axn/webhooks.rb — add below `require_relative "webhooks/resolvers"`
require_relative "webhooks/verify"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/axn/webhooks/verify_spec.rb`
Expected: PASS.

- [ ] **Step 5: Update CHANGELOG and commit**

```markdown
- `Axn::Webhooks::Verify` — the verify stage as an Axn: a signature mismatch fails quietly (no exception report); a verifier that raises is surfaced as a loud exception.
```

```bash
git add lib/axn/webhooks/verify.rb lib/axn/webhooks.rb spec/axn/webhooks/verify_spec.rb CHANGELOG.md
git commit -m "feat: add Verify axn with quiet-mismatch/loud-crash semantics"
```

---

## Task 3: Endpoint registry + `inbound` DSL (custom-block verify end-to-end)

Wire the whole registration path with the simplest verifier — a **custom block** — so the machinery is proven before strategies land. `Axn::Webhooks.inbound(:demo) { verify { |req| … } }` registers an `Endpoint`; `Axn::Webhooks::Inbound[:demo].verify(request)` runs it through `Verify`.

**Files:**
- Create: `lib/axn/webhooks/verifiers.rb`
- Create: `lib/axn/webhooks/inbound.rb`
- Create: `lib/axn/webhooks/inbound/endpoint.rb`
- Create: `lib/axn/webhooks/inbound/dsl.rb`
- Modify: `lib/axn/webhooks.rb`
- Test: `spec/axn/webhooks/inbound_spec.rb`

**Interfaces:**
- Consumes: `Verify` (Task 2), `Resolvers` (Task 1), `Axn::Webhooks::Error` (scaffold).
- Produces:
  - `Axn::Webhooks.inbound(name, &block)` — evaluates the block, builds + registers an `Endpoint`. Raises `ArgumentError` without a block.
  - `Axn::Webhooks::Inbound[:vendor] → Endpoint` (raises `KeyError` if unregistered); `Inbound.register(name, endpoint)`; `Inbound.registered → [Symbol]`; `Inbound.reset!`.
  - `Endpoint#verify(request) → Axn::Result`; `Endpoint#name → Symbol`.
  - `Verifiers.build(strategy:, opts:, block:) → callable` — returns `block` verbatim if present; else looks up a registered strategy (none yet — Tasks 4–5 add them) and raises `Axn::Webhooks::Error` on an unknown strategy. `Verifiers.register(name, &builder)`.
  - DSL: `verify(strategy = nil, **opts, &block)` captures the spec; `header/raw_body/params/url` return resolvers; `__verifier__` builds the callable (raises `Axn::Webhooks::Error` if `verify` was never declared).

- [ ] **Step 1: Write the failing test**

```ruby
# spec/axn/webhooks/inbound_spec.rb
# frozen_string_literal: true

RSpec.describe "Axn::Webhooks.inbound (registration + custom verify)" do
  after { Axn::Webhooks::Inbound.reset! }

  def request(token)
    Axn::Webhooks::Request.new(raw_body: "b", headers: { "X-Token" => token })
  end

  it "registers an endpoint verified by a custom block" do
    Axn::Webhooks.inbound(:demo) { verify { |req| req.header("X-Token") == "sekret" } }

    expect(Axn::Webhooks::Inbound.registered).to include(:demo)
    expect(Axn::Webhooks::Inbound[:demo].verify(request("sekret"))).to be_ok
    expect(Axn::Webhooks::Inbound[:demo].verify(request("nope"))).not_to be_ok
  end

  it "exposes the endpoint name" do
    Axn::Webhooks.inbound(:demo) { verify { |_req| true } }
    expect(Axn::Webhooks::Inbound[:demo].name).to eq(:demo)
  end

  it "raises a clear error looking up an unregistered vendor" do
    expect { Axn::Webhooks::Inbound[:missing] }.to raise_error(KeyError, /missing/)
  end

  it "requires a block" do
    expect { Axn::Webhooks.inbound(:x) }.to raise_error(ArgumentError, /block/)
  end

  it "requires a verify declaration inside the block" do
    expect { Axn::Webhooks.inbound(:x) { nil } }.to raise_error(Axn::Webhooks::Error, /verify/)
  end

  it "raises on an unknown strategy" do
    expect { Axn::Webhooks.inbound(:x) { verify :nope, secret: "s" } }
      .to raise_error(Axn::Webhooks::Error, /unknown verify strategy/)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/webhooks/inbound_spec.rb`
Expected: FAIL — `undefined method 'inbound'` / `uninitialized constant Axn::Webhooks::Inbound`.

- [ ] **Step 3: Write minimal implementation**

```ruby
# lib/axn/webhooks/verifiers.rb
# frozen_string_literal: true

module Axn
  module Webhooks
    # Builds a verifier callable (->(request){ Boolean }) from a `verify` declaration.
    # A custom block is used verbatim; a strategy symbol is looked up in STRATEGIES
    # (populated by verifiers/*.rb).
    module Verifiers
      STRATEGIES = {}

      module_function

      def register(name, &builder) = STRATEGIES[name.to_sym] = builder

      def build(strategy:, opts:, block:)
        return block if block

        builder = STRATEGIES.fetch(strategy) do
          raise Axn::Webhooks::Error, "unknown verify strategy #{strategy.inspect}"
        end
        builder.call(**opts)
      end
    end
  end
end
```

```ruby
# lib/axn/webhooks/inbound/dsl.rb
# frozen_string_literal: true

module Axn
  module Webhooks
    module Inbound
      # Receiver for an `inbound` block: captures declarations (Phase 2: `verify`) and
      # exposes request resolvers. Later phases add dispatch/challenge/respond here.
      class DSL
        # verify :hmac, **opts | verify :standard_webhooks, **opts | verify { |req| ... }
        def verify(strategy = nil, **opts, &block)
          @verify_spec = { strategy:, opts:, block: }
        end

        def header(name) = Resolvers.header(name)
        def raw_body     = Resolvers.raw_body
        def params       = Resolvers.params
        def url          = Resolvers.url

        # Internal: build the verifier callable from the captured declaration.
        def __verifier__
          raise Axn::Webhooks::Error, "inbound endpoint declared no `verify`" unless @verify_spec

          Verifiers.build(**@verify_spec)
        end
      end
    end
  end
end
```

```ruby
# lib/axn/webhooks/inbound/endpoint.rb
# frozen_string_literal: true

module Axn
  module Webhooks
    module Inbound
      # A registered inbound webhook endpoint. Phase 2 carries only the verifier;
      # later phases add dispatch/challenge/respond.
      class Endpoint
        def initialize(name:, verifier:)
          @name = name.to_sym
          @verifier = verifier
        end

        attr_reader :name

        # Verify the request's signature. Returns an Axn::Result: ok? when verified,
        # a failure on mismatch, an exception if the verifier raises.
        def verify(request)
          Verify.call(request:, verifier: @verifier)
        end
      end
    end
  end
end
```

```ruby
# lib/axn/webhooks/inbound.rb
# frozen_string_literal: true

require_relative "inbound/dsl"
require_relative "inbound/endpoint"

module Axn
  module Webhooks
    # Process-global registry of inbound webhook endpoints, populated by
    # `Axn::Webhooks.inbound(:vendor) { ... }` and looked up as `Inbound[:vendor]`.
    module Inbound
      @registry = {}

      class << self
        def register(name, endpoint) = @registry[name.to_sym] = endpoint
        def [](name) = @registry.fetch(name.to_sym) { raise KeyError, "no inbound webhook registered for #{name.inspect}" }
        def registered = @registry.keys
        def reset! = @registry.clear
      end
    end

    # Declare an inbound webhook endpoint. Evaluated at boot (e.g. a Rails initializer)
    # so registration is deterministic, in or out of Rails.
    def self.inbound(name, &block)
      raise ArgumentError, "Axn::Webhooks.inbound requires a block" unless block

      dsl = Inbound::DSL.new
      dsl.instance_exec(&block)
      Inbound.register(name, Inbound::Endpoint.new(name:, verifier: dsl.__verifier__))
    end
  end
end
```

```ruby
# lib/axn/webhooks.rb — add below `require_relative "webhooks/verify"`
require_relative "webhooks/verifiers"
require_relative "webhooks/inbound"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/axn/webhooks/inbound_spec.rb`
Expected: PASS.

- [ ] **Step 5: Update CHANGELOG and commit**

```markdown
- `Axn::Webhooks.inbound(:vendor) { … }` + `Axn::Webhooks::Inbound[:vendor]` — block-per-endpoint registration and lookup, with a custom-block verifier slot and the `Verifiers` strategy registry.
```

```bash
git add lib/axn/webhooks/verifiers.rb lib/axn/webhooks/inbound.rb lib/axn/webhooks/inbound/endpoint.rb lib/axn/webhooks/inbound/dsl.rb lib/axn/webhooks.rb spec/axn/webhooks/inbound_spec.rb CHANGELOG.md
git commit -m "feat: add inbound endpoint registry and DSL (custom verify)"
```

---

## Task 4: `:hmac` strategy

Compile `verify :hmac, secret:, signature:, …` into a verifier that resolves its options against the request and calls `Signature.hmac`. Covers Merge/Lob/MT/Slack/Nylas.

**Files:**
- Create: `lib/axn/webhooks/verifiers/hmac.rb`
- Modify: `lib/axn/webhooks.rb`
- Test: `spec/axn/webhooks/verifiers/hmac_spec.rb`

**Interfaces:**
- Consumes: `Verifiers.register`, `Resolvers.resolve`, `Signature.hmac`.
- Produces: registers strategy `:hmac` accepting `secret:` (required), `signature:` (required, a resolver/literal), `signing_string:` (default `:raw_body`), `digest:` (default `:sha256`), `encoding:` (default `:hex`), `prefix:` (default `nil`), `replay:` (default `nil`; `{ timestamp: <resolver>, within: <seconds> }`). Missing/unknown option → `ArgumentError` (loud dev error).

- [ ] **Step 1: Write the failing test**

```ruby
# spec/axn/webhooks/verifiers/hmac_spec.rb
# frozen_string_literal: true

require "openssl"

RSpec.describe "verify :hmac strategy" do
  after { Axn::Webhooks::Inbound.reset! }

  let(:secret) { "shh" }
  let(:body)   { '{"ok":true}' }

  def request(headers:, body: '{"ok":true}')
    Axn::Webhooks::Request.new(raw_body: body, headers:)
  end

  it "verifies a hex sha256 signature over the raw body (Merge/MT-style)" do
    sig = OpenSSL::HMAC.hexdigest("SHA256", secret, body)
    Axn::Webhooks.inbound(:merge) { verify :hmac, secret: "shh", signature: header("X-Sig") }

    expect(Axn::Webhooks::Inbound[:merge].verify(request(headers: { "X-Sig" => sig }))).to be_ok
    expect(Axn::Webhooks::Inbound[:merge].verify(request(headers: { "X-Sig" => "deadbeef" }))).not_to be_ok
  end

  it "supports base64_urlsafe encoding" do
    raw = OpenSSL::HMAC.digest("SHA256", secret, body)
    sig = [raw].pack("m0").tr("+/", "-_") # urlsafe base64, no padding stripped by pack
    Axn::Webhooks.inbound(:merge) do
      verify :hmac, secret: "shh", signature: header("X-Sig"), encoding: :base64_urlsafe
    end
    expect(Axn::Webhooks::Inbound[:merge].verify(request(headers: { "X-Sig" => sig }))).to be_ok
  end

  it "supports a custom signing_string and a v0= prefix (Slack-style)" do
    ts = "1700000000"
    signed = "v0:#{ts}:#{body}"
    sig = "v0=#{OpenSSL::HMAC.hexdigest('SHA256', secret, signed)}"
    Axn::Webhooks.inbound(:slack) do
      verify :hmac,
        secret: "shh",
        signing_string: ->(r) { "v0:#{r.header('X-Ts')}:#{r.raw_body}" },
        signature: header("X-Slack-Sig"),
        prefix: "v0="
    end
    req = request(headers: { "X-Ts" => ts, "X-Slack-Sig" => sig })
    expect(Axn::Webhooks::Inbound[:slack].verify(req)).to be_ok
  end

  it "rejects a stale timestamp when replay protection is configured" do
    stale = (Time.now - 10_000).to_i.to_s
    sig = OpenSSL::HMAC.hexdigest("SHA256", secret, body)
    Axn::Webhooks.inbound(:lob) do
      verify :hmac, secret: "shh", signature: header("X-Sig"),
                    replay: { timestamp: header("X-Ts"), within: 300 }
    end
    req = request(headers: { "X-Sig" => sig, "X-Ts" => stale })
    expect(Axn::Webhooks::Inbound[:lob].verify(req)).not_to be_ok
  end

  it "raises a loud developer error when a required option is missing" do
    expect { Axn::Webhooks.inbound(:x) { verify :hmac, secret: "s" } } # no signature:
      .to raise_error(ArgumentError, /signature/)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/webhooks/verifiers/hmac_spec.rb`
Expected: FAIL — `unknown verify strategy :hmac`.

- [ ] **Step 3: Write minimal implementation**

```ruby
# lib/axn/webhooks/verifiers/hmac.rb
# frozen_string_literal: true

module Axn
  module Webhooks
    module Verifiers
      # Parametric HMAC strategy. Resolves each option against the request at verify time
      # and delegates to the constant-time Signature primitive.
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
            tolerance: replay && replay.fetch(:within),
          )
        end
      end
    end
  end
end
```

```ruby
# lib/axn/webhooks.rb — add below `require_relative "webhooks/verifiers"`
require_relative "webhooks/verifiers/hmac"
```

(Place it before `require_relative "webhooks/inbound"` is fine either way; the strategy only needs to be registered before an `inbound` block using `:hmac` runs.)

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/axn/webhooks/verifiers/hmac_spec.rb`
Expected: PASS.

- [ ] **Step 5: Update CHANGELOG and commit**

```markdown
- `verify :hmac` strategy — parametric HMAC (digest/encoding/prefix/custom signing string/replay window) over a `Request`, built on `Axn::Webhooks::Signature`.
```

```bash
git add lib/axn/webhooks/verifiers/hmac.rb lib/axn/webhooks.rb spec/axn/webhooks/verifiers/hmac_spec.rb CHANGELOG.md
git commit -m "feat: add :hmac verify strategy"
```

---

## Task 5: `:standard_webhooks` strategy

The Standard Webhooks / Svix scheme: secret is `whsec_<base64>`; signed string is `id.timestamp.body`; the signature header carries space-separated `v1,<base64sig>` candidates (key rotation); ±tolerance replay window. **Extract the `v1,` candidates in the strategy** (not via `Signature`'s generic `/[\s,]+/` splitter, which would break `v1,<sig>` on the comma — the Phase-1 note in `signature.rb`), then delegate to `Signature.hmac` for the constant-time compare + window.

**Files:**
- Create: `lib/axn/webhooks/verifiers/standard_webhooks.rb`
- Modify: `lib/axn/webhooks.rb`
- Test: `spec/axn/webhooks/verifiers/standard_webhooks_spec.rb`

**Interfaces:**
- Consumes: `Verifiers.register`, `Resolvers`, `Signature.hmac`, stdlib `Base64`.
- Produces: registers strategy `:standard_webhooks` accepting `secret:` (required, `whsec_…`), `tolerance:` (default `300`), and overridable `id:`/`timestamp:`/`signature:` resolvers (default headers `webhook-id`/`webhook-timestamp`/`webhook-signature`; Svix/Codat consumers override to `svix-*`). Helper module `Verifiers::StandardWebhooks` with `decode_secret` and `extract_v1`.

- [ ] **Step 1: Write the failing test**

```ruby
# spec/axn/webhooks/verifiers/standard_webhooks_spec.rb
# frozen_string_literal: true

require "openssl"
require "base64"

RSpec.describe "verify :standard_webhooks strategy" do
  after { Axn::Webhooks::Inbound.reset! }

  let(:key)    { "raw-signing-key" }
  let(:whsec)  { "whsec_#{Base64.strict_encode64(key)}" }
  let(:id)     { "msg_123" }
  let(:body)   { '{"hello":"world"}' }

  def sign(id:, ts:, body:, key:)
    Base64.strict_encode64(OpenSSL::HMAC.digest("SHA256", key, "#{id}.#{ts}.#{body}"))
  end

  def request(headers:, body: '{"hello":"world"}')
    Axn::Webhooks::Request.new(raw_body: body, headers:)
  end

  it "verifies a v1, candidate over id.timestamp.body (whsec_ secret)" do
    ts = Time.now.to_i.to_s
    headers = {
      "webhook-id" => id, "webhook-timestamp" => ts,
      "webhook-signature" => "v1,#{sign(id:, ts:, body:, key:)}",
    }
    Axn::Webhooks.inbound(:codat) { verify :standard_webhooks, secret: whsec }
    expect(Axn::Webhooks::Inbound[:codat].verify(request(headers:))).to be_ok
  end

  it "passes if ANY space-separated v1 candidate matches (key rotation) and this proves the v1, comma isn't split naively" do
    ts = Time.now.to_i.to_s
    good = sign(id:, ts:, body:, key:)
    headers = {
      "webhook-id" => id, "webhook-timestamp" => ts,
      "webhook-signature" => "v1,AAAA v1,#{good}",
    }
    Axn::Webhooks.inbound(:codat) { verify :standard_webhooks, secret: whsec }
    expect(Axn::Webhooks::Inbound[:codat].verify(request(headers:))).to be_ok
  end

  it "rejects a tampered signature" do
    ts = Time.now.to_i.to_s
    headers = { "webhook-id" => id, "webhook-timestamp" => ts, "webhook-signature" => "v1,#{Base64.strict_encode64('nope-nope-nope-nope-nope-nope!!')}" }
    Axn::Webhooks.inbound(:codat) { verify :standard_webhooks, secret: whsec }
    expect(Axn::Webhooks::Inbound[:codat].verify(request(headers:))).not_to be_ok
  end

  it "rejects a timestamp outside the tolerance window" do
    ts = (Time.now - 10_000).to_i.to_s
    headers = {
      "webhook-id" => id, "webhook-timestamp" => ts,
      "webhook-signature" => "v1,#{sign(id:, ts:, body:, key:)}",
    }
    Axn::Webhooks.inbound(:codat) { verify :standard_webhooks, secret: whsec, tolerance: 300 }
    expect(Axn::Webhooks::Inbound[:codat].verify(request(headers:))).not_to be_ok
  end

  describe Axn::Webhooks::Verifiers::StandardWebhooks do
    it "decodes a whsec_ secret to its raw bytes" do
      expect(described_class.decode_secret("whsec_#{Base64.strict_encode64('abc')}")).to eq("abc")
    end

    it "extracts only v1, candidates, stripped to the bare signature" do
      expect(described_class.extract_v1("v1,AAA v2,BBB v1,CCC")).to eq(%w[AAA CCC])
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/webhooks/verifiers/standard_webhooks_spec.rb`
Expected: FAIL — `unknown verify strategy :standard_webhooks` (and the helper constant is undefined).

- [ ] **Step 3: Write minimal implementation**

```ruby
# lib/axn/webhooks/verifiers/standard_webhooks.rb
# frozen_string_literal: true

require "base64"

module Axn
  module Webhooks
    module Verifiers
      # Standard Webhooks (Svix) scheme. Secret is `whsec_<base64>`; the signed string is
      # `id.timestamp.body`; the signature header holds space-separated `v1,<base64sig>`
      # candidates; a ±tolerance replay window applies.
      module StandardWebhooks
        module_function

        def decode_secret(secret) = Base64.decode64(secret.to_s.delete_prefix("whsec_"))

        # Keep only `v1,<sig>` candidates, stripped to the bare base64 signature.
        # Done here (not via Signature's generic splitter) because that splitter treats
        # the comma as a separator and would break `v1,<sig>` into two tokens.
        def extract_v1(header)
          header.to_s.split(/\s+/).select { |t| t.start_with?("v1,") }.map { |t| t.delete_prefix("v1,") }
        end
      end

      register(:standard_webhooks) do |secret:, tolerance: 300,
                                       id: Resolvers.header("webhook-id"),
                                       timestamp: Resolvers.header("webhook-timestamp"),
                                       signature: Resolvers.header("webhook-signature")|
        lambda do |request|
          ts = Resolvers.resolve(timestamp, request)
          payload = "#{Resolvers.resolve(id, request)}.#{ts}.#{request.raw_body}"
          candidates = StandardWebhooks.extract_v1(Resolvers.resolve(signature, request))

          Signature.hmac(
            secret: StandardWebhooks.decode_secret(Resolvers.resolve(secret, request)),
            payload:,
            signature: candidates.join(" "),
            digest: :sha256,
            encoding: :base64,
            timestamp: ts,
            tolerance:,
          )
        end
      end
    end
  end
end
```

```ruby
# lib/axn/webhooks.rb — add below `require_relative "webhooks/verifiers/hmac"`
require_relative "webhooks/verifiers/standard_webhooks"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/axn/webhooks/verifiers/standard_webhooks_spec.rb`
Expected: PASS.

- [ ] **Step 5: Update CHANGELOG and commit**

```markdown
- `verify :standard_webhooks` strategy — the Standard Webhooks / Svix scheme (`whsec_` secret, `id.timestamp.body` signing, `v1,` candidate extraction with key rotation, ±tolerance window). Removes any need for the `svix` gem.
```

```bash
git add lib/axn/webhooks/verifiers/standard_webhooks.rb lib/axn/webhooks.rb spec/axn/webhooks/verifiers/standard_webhooks_spec.rb CHANGELOG.md
git commit -m "feat: add :standard_webhooks verify strategy"
```

---

## Task 6: Phase 2 wrap-up — full verify + README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Run the full dual suite**

Run: `bundle exec rake verify`
Expected: all library specs + Rails dummy-app specs pass, rubocop clean. Fix any rubocop offenses in the new files.

- [ ] **Step 2: Add an "Inbound endpoints" section to `README.md`**

Add after the "Signature primitive" section:

```markdown
## Inbound endpoints

Declare each vendor webhook in one place (e.g. a Rails initializer), grouped by vendor:

​```ruby
Axn::Webhooks.inbound :merge do
  verify :hmac,
    secret:    ENV.fetch("MERGE_WEBHOOK_SIGNATURE_KEY"),
    signature: header("X-Merge-Webhook-Signature"),
    encoding:  :base64_urlsafe
end

Axn::Webhooks.inbound :codat do
  verify :standard_webhooks, secret: ENV.fetch("CODAT_WEBHOOK_SECRET")
end

Axn::Webhooks.inbound :twilio do
  verify { |req| Twilio::Security::RequestValidator.new(ENV.fetch("TWILIO_AUTH_TOKEN"))
                   .validate(req.url, req.params, req.header("X-Twilio-Signature")) }
end
​```

Verify a request (dispatch/respond and HTTP mounting land in later phases):

​```ruby
result = Axn::Webhooks::Inbound[:merge].verify(request)  # => Axn::Result
result.ok?  # signature valid?
​```
```

**Write standard triple-backtick fences — the leading zero-width space above is a docs-escaping artifact; do not copy it.**

- [ ] **Step 3: Re-run `bundle exec rake verify` if anything lintable changed, then commit**

```bash
git add README.md
git commit -m "docs: document inbound endpoints; close Phase 2"
```

---

## Self-Review (Phase 2)

- **Spec coverage:** block-per-endpoint `inbound` DSL ✅ Task 3; `Inbound[:vendor]` lookup ✅ Task 3; `:hmac` strategy ✅ Task 4; `:standard_webhooks` preset (whsec_/`v1,`/window, no `svix` gem) ✅ Task 5; custom/SDK verifier slot ✅ Task 3; verify staged outcome (mismatch quiet `fail!` vs crash loud exception) ✅ Task 2; secrets literal-or-callable, resolved via `Resolvers` ✅ Tasks 1/4. Deferred to later phases: dispatch/challenge/respond, Rack mount, `vendor_facet` dimension.
- **Placeholder scan:** none — every code step carries complete code and exact commands.
- **Type consistency:** `Verifiers.build(strategy:, opts:, block:)` shape matches the DSL's `@verify_spec` keys (Task 3) and the strategy builders' keyword signatures (Tasks 4–5); `Endpoint#verify(request) → Result`, `Inbound[:vendor]`, `Inbound.reset!`, `Resolvers.resolve` used identically across tasks and the README.
- **Phase-1 note discharged:** Task 5 handles `v1,` extraction in-strategy rather than via `Signature`'s `/[\s,]+/` splitter, closing the item the Phase-1 final review flagged.
```
