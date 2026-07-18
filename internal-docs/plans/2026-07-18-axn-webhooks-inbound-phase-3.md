# axn-webhooks Inbound — Phase 3 (dispatch DSL) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the `dispatch` half of the inbound DSL: after `verify`, parse the body into an `event`, route it to a handler Axn (explicit map, single handler, or name-from-key convention), and reflect the handler's outcome — built as a `Dispatch` Axn so every "loud" failure is reported and cleanly returned, never an unhandled exception.

**Architecture:** The DSL gains `dispatch`. `Endpoint` gains `handle(request)` = `verify → parse → Dispatch`. A plain `Router` resolves an event to `[handler_class, kwargs]` (or `:ack`), raising on a missing handler class or an unmatched key with no `otherwise:`. The `Dispatch` Axn parses the body, calls `Router#resolve`, and invokes the handler with `Handler.call!` — so a handler `fail!` becomes a quiet dispatch failure, a handler crash (or a resolution raise) becomes a loud dispatch exception reported once to `on_exception`.

**Tech Stack:** Ruby ≥ 3.2.1, `axn`, `JSON`/`Base64` (stdlib). No Rails required.

**Spec:** `internal-docs/specs/2026-07-17-axn-webhooks-inbound-design.md` — read **"Amendment — Phase 3 dispatch (settled 2026-07-18)"**; it is the binding decision set. Phases 1–2 (`Request`, `Signature`, `Resolvers`, `Verify`, the `inbound` registry/DSL, and the `:hmac`/`:standard_webhooks` strategies) are merged to `main`.

## Global Constraints

- **Ruby ≥ 3.2.1.** Dependencies: `axn` + stdlib only. No teamshares-rails/ActionController; no unguarded `Rails`/`ActiveRecord`/`ActiveJob`.
- **Nothing escapes the Axn boundary.** All dispatch resolution + handler invocation runs inside the `Dispatch` Axn, so a missing handler, an unmatched key, a parse error, or a handler crash lands in axn's exception bucket (→ `on_exception`/Honeybadger + a formatted `result.error`), never an unhandled raise up the stack.
- **Staged outcomes (verify + dispatch):** verify mismatch → `failure`; missing handler / unmatched-key-no-`otherwise` / parse error / handler crash → `exception` (reported **once**); handler business `fail!` → `failure`; `otherwise: :ack` → `success`. (HTTP status mapping is Phase 4/5; this phase produces the right `Axn::Result` outcome.)
- **Handler invocation is `Handler.call!(**args)`** inside `Dispatch` — verified: a nested `fail!` settles the parent as a prefixed `failure`; a nested raise settles it as an `exception` reported once. Never rescue to convert a crash into a failure.
- **Sync only this phase.** No `.call_async`/`mode:` — the async seam is Phase 4 and will delegate to axn's async interface (never branch on `:sidekiq`/`:active_job`). See the async memory.
- **`event` is the parsed body:** `JSON.parse(raw_body)` by default (string keys), or a per-endpoint `parse:` override (a proc, e.g. `->(req){ req.params }` for form bodies). `on:`/`with:` procs and the handler `event:` receive it.
- **Registry stays test-resettable** (`Axn::Webhooks::Inbound.reset!`); reset in an `after` hook.
- **CHANGELOG** under `## [Unreleased]`. **Done =** `bundle exec rake verify` green. **TDD** always.

## Grounding notes (verified against the installed `axn` this session)

- Live probe confirmed: `Parent#call` doing `Child.call!` →
  - `Child` does `fail!("x")` → `parent.outcome == "failure"`, `parent.error == "<Parent base error>: x"`, `parent.exception` is `Axn::Failure`. **Quiet.**
  - `Child` raises `RuntimeError` → `parent.outcome == "exception"`, `parent.error == "<Parent base error>"`, `parent.exception` is the `RuntimeError`, and `on_exception` fired **once** (`[RuntimeError]`). **Loud.**
- `Object.const_get("A::B::C")` resolves a nested constant and raises `NameError` if any segment is missing (and triggers Zeitwerk autoload under Rails). This is the loud path for a missing handler — caught by the `Dispatch` Axn.
- `done!("msg")` early-returns as `success`.

---

## File Structure (Phase 3)

- Create `lib/axn/webhooks/inbound/router.rb` — `Router` (plain object): `resolve(event) → [handler_class, kwargs] | :ack`, raising on missing/unmatched. Holds `to`/`on`/`otherwise`/`via`.
- Create `lib/axn/webhooks/inbound/parsers.rb` — `Parsers.build(option) → ->(request){ event }` (default JSON; proc passthrough).
- Create `lib/axn/webhooks/dispatch.rb` — the `Dispatch` Axn (parse → resolve → `Handler.call!`).
- Modify `lib/axn/webhooks/inbound/dsl.rb` — add `dispatch(...)` capture + `__dispatch__` builder.
- Modify `lib/axn/webhooks/inbound/endpoint.rb` — accept `dispatch:`; add `handle(request)`.
- Modify `lib/axn/webhooks/inbound.rb` — pass `dispatch:` when building the `Endpoint`.
- Modify `lib/axn/webhooks.rb` — require the new files.
- Modify `CHANGELOG.md`, `README.md`.
- Tests under `spec/axn/webhooks/`.

---

## Task 1: `Router` — resolve an event to a handler

Pure resolution logic, no axn. Three shapes: single `to:` handler; keyed `on:` + `to:` map; keyed `on:` + `to:` String namespace (name-from-key convention via `via:`). A map entry is a class-name String or `{ call:, with: }`. Missing constant or unmatched-key-no-`otherwise` **raises** (the `Dispatch` Axn turns that into a reported exception).

**Files:**
- Create: `lib/axn/webhooks/inbound/router.rb`
- Test: `spec/axn/webhooks/inbound/router_spec.rb`

**Interfaces:**
- Consumes: `Axn::Webhooks::Error`.
- Produces:
  - `Axn::Webhooks::Inbound::Router.new(to:, on: nil, otherwise: nil, via: nil)` — raises `Axn::Webhooks::Error` if `to:` is nil.
  - `#resolve(event) → [handler_class, kwargs]` for a matched handler; `:ack` for `otherwise: :ack` or after a user `otherwise:` proc runs; raises `NameError` (missing constant) or `Axn::Webhooks::Error` (unmatched key, no `otherwise`; invalid target).
  - Default handler kwargs are `{ event: event }`; a `{ call:, with: }` entry uses `with.call(event)`.
  - Default key→class transform (when `to:` is a String namespace and no `via:`): `key.split(/[._]/).reject(&:empty?).map(&:capitalize).join`.

- [ ] **Step 1: Write the failing test**

```ruby
# spec/axn/webhooks/inbound/router_spec.rb
# frozen_string_literal: true

RSpec.describe Axn::Webhooks::Inbound::Router do
  # Stand-in handler classes (any object works; Router only resolves + returns them).
  before do
    stub_const("HandleWebhook", Class.new)
    stub_const("Actions::Codat::ConnectionUpdated", Class.new)
    stub_const("PaymentOrders::DispatchCompleted", Class.new)
  end

  it "resolves a single string handler with the whole event" do
    router = described_class.new(to: "HandleWebhook")
    expect(router.resolve({ "any" => 1 })).to eq([HandleWebhook, { event: { "any" => 1 } }])
  end

  it "resolves a keyed handler from an explicit map" do
    router = described_class.new(
      on: ->(e) { e["eventType"] },
      to: { "connection.updated" => "Actions::Codat::ConnectionUpdated" },
    )
    expect(router.resolve({ "eventType" => "connection.updated" }))
      .to eq([Actions::Codat::ConnectionUpdated, { event: { "eventType" => "connection.updated" } }])
  end

  it "extracts scalar handler args via a with: proc" do
    router = described_class.new(
      on: ->(e) { e["event"] },
      to: { "reconciled" => { call: "PaymentOrders::DispatchCompleted",
                              with: ->(e) { { payment_order_id: e.dig("data", "id") } } } },
    )
    event = { "event" => "reconciled", "data" => { "id" => 42 } }
    expect(router.resolve(event)).to eq([PaymentOrders::DispatchCompleted, { payment_order_id: 42 }])
  end

  it "derives the class from the key via convention (default transform)" do
    router = described_class.new(on: ->(e) { e["eventType"] }, to: "Actions::Codat")
    stub_const("Actions::Codat::ConnectionUpdated", Actions::Codat::ConnectionUpdated) # ensure defined
    expect(router.resolve({ "eventType" => "connection.updated" }).first)
      .to eq(Actions::Codat::ConnectionUpdated)
  end

  it "applies a custom via: transform" do
    stub_const("Codat::ConnectionUpdatedHandler", Class.new)
    router = described_class.new(
      on: ->(e) { e["eventType"] }, to: "Codat",
      via: ->(k) { "#{k.split('.').map(&:capitalize).join}Handler" },
    )
    expect(router.resolve({ "eventType" => "connection.updated" }).first)
      .to eq(Codat::ConnectionUpdatedHandler)
  end

  it "raises NameError for a missing handler constant (loud)" do
    router = described_class.new(to: "Actions::Nope::Missing")
    expect { router.resolve({}) }.to raise_error(NameError)
  end

  it "raises for an unmatched key with no otherwise (loud)" do
    router = described_class.new(on: ->(e) { e["eventType"] }, to: { "known" => "HandleWebhook" })
    expect { router.resolve({ "eventType" => "surprise" }) }
      .to raise_error(Axn::Webhooks::Error, /surprise/)
  end

  it "returns :ack for an unmatched key when otherwise: :ack" do
    router = described_class.new(on: ->(e) { e["eventType"] }, to: { "known" => "HandleWebhook" }, otherwise: :ack)
    expect(router.resolve({ "eventType" => "surprise" })).to eq(:ack)
  end

  it "runs an otherwise: proc for an unmatched key then acks" do
    seen = []
    router = described_class.new(
      on: ->(e) { e["eventType"] }, to: { "known" => "HandleWebhook" },
      otherwise: ->(e) { seen << e["eventType"] },
    )
    expect(router.resolve({ "eventType" => "surprise" })).to eq(:ack)
    expect(seen).to eq(["surprise"])
  end

  it "requires a to: target" do
    expect { described_class.new(to: nil) }.to raise_error(Axn::Webhooks::Error, /to:/)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/webhooks/inbound/router_spec.rb`
Expected: FAIL — `uninitialized constant Axn::Webhooks::Inbound::Router`.

- [ ] **Step 3: Write minimal implementation**

```ruby
# lib/axn/webhooks/inbound/router.rb
# frozen_string_literal: true

module Axn
  module Webhooks
    module Inbound
      # Resolves a parsed webhook event to the handler to invoke. Pure logic (no Axn) —
      # a missing constant or an unmatched key with no `otherwise:` raises, and the
      # Dispatch Axn turns that raise into a reported exception + formatted result.
      class Router
        def initialize(to:, on: nil, otherwise: nil, via: nil)
          raise Axn::Webhooks::Error, "dispatch needs a `to:` target" if to.nil?

          @to = to
          @on = on
          @otherwise = otherwise
          @via = via
        end

        # → [handler_class, kwargs] for a matched handler, or :ack.
        def resolve(event)
          return handler_for(@to, event) if @on.nil?

          key = @on.call(event)
          @to.is_a?(Hash) ? resolve_mapped(key, event) : resolve_by_convention(key, event)
        end

        private

        def resolve_mapped(key, event)
          entry = @to.fetch(key) { return unmatched(key, event) }
          handler_for(entry, event)
        end

        def resolve_by_convention(key, event)
          transform = @via || method(:default_transform)
          [constantize("#{@to}::#{transform.call(key)}"), { event: }]
        end

        def handler_for(entry, event)
          case entry
          when String then [constantize(entry), { event: }]
          when Hash
            args = entry.key?(:with) ? entry.fetch(:with).call(event) : { event: }
            [constantize(entry.fetch(:call)), args]
          else
            raise Axn::Webhooks::Error, "invalid dispatch target: #{entry.inspect}"
          end
        end

        def unmatched(key, event)
          case @otherwise
          when :ack then :ack
          when nil  then raise Axn::Webhooks::Error, "no handler for webhook event #{key.inspect} (and no `otherwise:`)"
          else
            @otherwise.call(event) # user callable (e.g. alerting); return value ignored
            :ack
          end
        end

        def constantize(name) = name.is_a?(Module) ? name : Object.const_get(name)

        def default_transform(key) = key.to_s.split(/[._]/).reject(&:empty?).map(&:capitalize).join
      end
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/axn/webhooks/inbound/router_spec.rb`
Expected: PASS.

- [ ] **Step 5: Update CHANGELOG and commit**

Add under `## [Unreleased]` → `### Added`:

```markdown
- `Axn::Webhooks::Inbound::Router` — resolves a parsed webhook event to a handler (single `to:`, keyed `on:`+map, or name-from-key convention with `via:`), with a `with:` scalar extractor and `otherwise:` (`:ack` or a user callable). Missing/unmatched targets raise loudly.
```

```bash
git add lib/axn/webhooks/inbound/router.rb spec/axn/webhooks/inbound/router_spec.rb CHANGELOG.md
git commit -m "feat: add dispatch Router (event -> handler resolution)"
```

---

## Task 2: `Dispatch` Axn + `Parsers`

The Axn that turns a verified request into a handler invocation: parse the body into `event`, resolve via the `Router`, and call the handler with `Handler.call!`. Every failure mode routes through axn's outcome buckets (verified in Grounding). `Parsers.build` turns the `parse:` option into a `->(request){ event }` callable (default JSON).

**Files:**
- Create: `lib/axn/webhooks/inbound/parsers.rb`
- Create: `lib/axn/webhooks/dispatch.rb`
- Modify: `lib/axn/webhooks.rb`
- Test: `spec/axn/webhooks/dispatch_spec.rb`

**Interfaces:**
- Consumes: `Router` (Task 1), `Axn::Webhooks::Request`.
- Produces:
  - `Axn::Webhooks::Parsers.build(option) → callable` — `nil`/`:json` → `->(req){ JSON.parse(req.raw_body) }`; a `Proc` → itself; else raises `Axn::Webhooks::Error`.
  - `Axn::Webhooks::Dispatch.call(request:, router:, parse:) → Axn::Result` — parses, resolves, invokes. `otherwise: :ack` → `success` (`done!`). Handler `fail!` → `failure`. Missing handler / unmatched / parse error / handler crash → `exception` (reported once), `result.error` = `"Webhook dispatch failed"`.

- [ ] **Step 1: Write the failing test**

```ruby
# spec/axn/webhooks/dispatch_spec.rb
# frozen_string_literal: true

RSpec.describe Axn::Webhooks::Dispatch do
  def request(body) = Axn::Webhooks::Request.new(raw_body: body)
  let(:json_parse) { Axn::Webhooks::Parsers.build(:json) }

  # Real handler Axns exercising each outcome.
  before do
    stub_const("OkHandler", Class.new { include Axn; expects :event; def call = nil })
    stub_const("FailHandler", Class.new { include Axn; expects :event; def call = fail!("we don't care") })
    stub_const("BoomHandler", Class.new { include Axn; expects :event; def call = raise("handler crashed") })
  end

  it "invokes the matched handler and succeeds when it succeeds" do
    router = Axn::Webhooks::Inbound::Router.new(to: "OkHandler")
    result = described_class.call(request: request('{"a":1}'), router:, parse: json_parse)
    expect(result).to be_ok
  end

  it "settles as a quiet failure when the handler fail!s" do
    router = Axn::Webhooks::Inbound::Router.new(to: "FailHandler")
    result = described_class.call(request: request("{}"), router:, parse: json_parse)
    expect(result.outcome).to be_failure
    expect(result.outcome).not_to be_exception
    expect(result.error).to include("we don't care")
  end

  it "settles as a loud exception when the handler crashes" do
    router = Axn::Webhooks::Inbound::Router.new(to: "BoomHandler")
    result = described_class.call(request: request("{}"), router:, parse: json_parse)
    expect(result.outcome).to be_exception
    expect(result.exception).to be_a(RuntimeError)
  end

  it "settles as a loud exception for a missing handler class" do
    router = Axn::Webhooks::Inbound::Router.new(to: "Totally::Missing::Handler")
    result = described_class.call(request: request("{}"), router:, parse: json_parse)
    expect(result.outcome).to be_exception
    expect(result.exception).to be_a(NameError)
  end

  it "settles as a loud exception for an unmatched key with no otherwise" do
    router = Axn::Webhooks::Inbound::Router.new(on: ->(e) { e["t"] }, to: { "known" => "OkHandler" })
    result = described_class.call(request: request('{"t":"surprise"}'), router:, parse: json_parse)
    expect(result.outcome).to be_exception
  end

  it "acknowledges (success) an unmatched key when otherwise: :ack" do
    router = Axn::Webhooks::Inbound::Router.new(on: ->(e) { e["t"] }, to: { "known" => "OkHandler" }, otherwise: :ack)
    result = described_class.call(request: request('{"t":"surprise"}'), router:, parse: json_parse)
    expect(result).to be_ok
  end

  it "settles as a loud exception on a body that fails to parse" do
    router = Axn::Webhooks::Inbound::Router.new(to: "OkHandler")
    result = described_class.call(request: request("not json"), router:, parse: json_parse)
    expect(result.outcome).to be_exception
  end

  describe Axn::Webhooks::Parsers do
    it "defaults to JSON and passes a proc through" do
      req = Axn::Webhooks::Request.new(raw_body: '{"k":"v"}', params: { "p" => 1 })
      expect(described_class.build(:json).call(req)).to eq("k" => "v")
      expect(described_class.build(nil).call(req)).to eq("k" => "v")
      expect(described_class.build(->(r) { r.params }).call(req)).to eq("p" => 1)
    end

    it "rejects an unknown parse option" do
      expect { described_class.build(:xml) }.to raise_error(Axn::Webhooks::Error, /parse/)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/webhooks/dispatch_spec.rb`
Expected: FAIL — `uninitialized constant Axn::Webhooks::Dispatch`.

- [ ] **Step 3: Write minimal implementation**

```ruby
# lib/axn/webhooks/inbound/parsers.rb
# frozen_string_literal: true

require "json"

module Axn
  module Webhooks
    # Builds the callable that turns a Request into the parsed `event` a dispatcher routes on.
    module Parsers
      module_function

      def build(option)
        case option
        when nil, :json then ->(request) { JSON.parse(request.raw_body) }
        when Proc       then option
        else raise Axn::Webhooks::Error, "unknown parse option #{option.inspect} (use :json or a proc)"
        end
      end
    end
  end
end
```

```ruby
# lib/axn/webhooks/dispatch.rb
# frozen_string_literal: true

module Axn
  module Webhooks
    # Routes a verified request to its handler Axn. Built as an Axn so every loud failure
    # (missing handler, unmatched key, parse error, handler crash) lands in axn's exception
    # bucket — reported once via on_exception, returned as a formatted result — and a handler
    # business `fail!` stays a quiet failure. Handler is invoked with `call!` so its outcome
    # propagates: fail! → this failure (prefixed), raise → this exception (reported once).
    class Dispatch
      include Axn

      expects :request, type: Axn::Webhooks::Request
      expects :router
      expects :parse
      error "Webhook dispatch failed"

      def call
        event = parse.call(request)
        resolution = router.resolve(event)
        return done!("acknowledged") if resolution == :ack

        handler_class, args = resolution
        handler_class.call!(**args)
      end
    end
  end
end
```

```ruby
# lib/axn/webhooks.rb — add below `require_relative "webhooks/inbound"`
require_relative "webhooks/inbound/parsers"
require_relative "webhooks/dispatch"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/axn/webhooks/dispatch_spec.rb`
Expected: PASS. (Handler INFO logs are silenced by the spec_helper null logger from Phase 2.)

- [ ] **Step 5: Update CHANGELOG and commit**

```markdown
- `Axn::Webhooks::Dispatch` — the dispatch stage as an Axn (parse → resolve → `Handler.call!`): a handler `fail!` is a quiet failure; a missing/unmatched handler, parse error, or handler crash is a loud exception reported once. `Axn::Webhooks::Parsers` builds the body parser (`:json` default or a proc).
```

```bash
git add lib/axn/webhooks/inbound/parsers.rb lib/axn/webhooks/dispatch.rb lib/axn/webhooks.rb spec/axn/webhooks/dispatch_spec.rb CHANGELOG.md
git commit -m "feat: add Dispatch axn and body parsers"
```

---

## Task 3: `dispatch` DSL + `Endpoint#handle` (end-to-end)

Wire it into the block DSL and the endpoint pipeline. `dispatch to:/on:/otherwise:/via:/parse:` in an `inbound` block builds a `Router` + parse callable; `Endpoint#handle(request)` runs `verify → Dispatch`.

**Files:**
- Modify: `lib/axn/webhooks/inbound/dsl.rb`
- Modify: `lib/axn/webhooks/inbound/endpoint.rb`
- Modify: `lib/axn/webhooks/inbound.rb`
- Test: `spec/axn/webhooks/inbound/handle_spec.rb`

**Interfaces:**
- Consumes: `Router`, `Parsers`, `Dispatch`, `Verify`.
- Produces:
  - DSL `dispatch(to: nil, on: nil, otherwise: nil, via: nil, parse: :json)` captures the spec; `__dispatch__ → { router:, parse: } | nil`.
  - `Endpoint.new(name:, verifier:, dispatch: nil)`; `Endpoint#handle(request) → Axn::Result` — returns the verify result if verification fails or if no dispatch is declared; otherwise runs `Dispatch`.

- [ ] **Step 1: Write the failing test**

```ruby
# spec/axn/webhooks/inbound/handle_spec.rb
# frozen_string_literal: true

require "openssl"

RSpec.describe "Axn::Webhooks endpoint#handle (verify + dispatch)" do
  after { Axn::Webhooks::Inbound.reset! }

  let(:secret) { "shh" }

  before do
    stub_const("Handlers", Module.new)
    stub_const("Handlers::Created",
               Class.new { include Axn; expects :event; exposes :seen_id; def call = expose(seen_id: event.dig("data", "id")) })
  end

  def signed_request(body)
    sig = OpenSSL::HMAC.hexdigest("SHA256", secret, body)
    Axn::Webhooks::Request.new(raw_body: body, headers: { "X-Sig" => sig })
  end

  it "verifies then dispatches to the keyed handler" do
    Axn::Webhooks.inbound(:vendor) do
      verify :hmac, secret: "shh", signature: header("X-Sig")
      dispatch on: ->(e) { e["type"] }, to: { "created" => "Handlers::Created" }
    end

    body = '{"type":"created","data":{"id":99}}'
    result = Axn::Webhooks::Inbound[:vendor].handle(signed_request(body))
    expect(result).to be_ok
    expect(result.seen_id).to eq(99)
  end

  it "short-circuits to the verify failure without dispatching on a bad signature" do
    Axn::Webhooks.inbound(:vendor) do
      verify :hmac, secret: "shh", signature: header("X-Sig")
      dispatch to: "Handlers::Created"
    end

    bad = Axn::Webhooks::Request.new(raw_body: '{"type":"created"}', headers: { "X-Sig" => "deadbeef" })
    result = Axn::Webhooks::Inbound[:vendor].handle(bad)
    expect(result).not_to be_ok
    expect(result.outcome).to be_failure # verify mismatch, not a dispatch exception
  end

  it "supports a form-body parse: override" do
    stub_const("Handlers::Sms", Class.new { include Axn; expects :event; exposes :from; def call = expose(from: event["From"]) })
    Axn::Webhooks.inbound(:twilio) do
      verify { |_req| true }
      dispatch to: "Handlers::Sms", parse: ->(req) { req.params }
    end

    req = Axn::Webhooks::Request.new(raw_body: "From=+15550001111", params: { "From" => "+15550001111" })
    result = Axn::Webhooks::Inbound[:twilio].handle(req)
    expect(result).to be_ok
    expect(result.from).to eq("+15550001111")
  end

  it "returns the verify result for a verify-only endpoint (no dispatch)" do
    Axn::Webhooks.inbound(:probe) { verify { |_req| true } }
    result = Axn::Webhooks::Inbound[:probe].handle(Axn::Webhooks::Request.new(raw_body: ""))
    expect(result).to be_ok
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/webhooks/inbound/handle_spec.rb`
Expected: FAIL — `undefined method 'handle'` / `unknown keyword: :dispatch`.

- [ ] **Step 3: Write minimal implementation**

Add to `DSL` (`lib/axn/webhooks/inbound/dsl.rb`), below `verify`:

```ruby
        # dispatch to: "Handler" | dispatch on: ->(e){…}, to: {map}, otherwise:, via: | parse:
        def dispatch(to: nil, on: nil, otherwise: nil, via: nil, parse: :json)
          @dispatch_spec = { to:, on:, otherwise:, via:, parse: }
        end
```

And add a `__dispatch__` builder to `DSL` (below `__verifier__`):

```ruby
        # Internal: build the { router:, parse: } dispatch config, or nil if none declared.
        def __dispatch__
          return nil unless @dispatch_spec

          spec = @dispatch_spec
          router = Router.new(to: spec[:to], on: spec[:on], otherwise: spec[:otherwise], via: spec[:via])
          { router:, parse: Parsers.build(spec[:parse]) }
        end
```

Update `Endpoint` (`lib/axn/webhooks/inbound/endpoint.rb`):

```ruby
        def initialize(name:, verifier:, dispatch: nil)
          @name = name.to_sym
          @verifier = verifier
          @dispatch = dispatch
        end

        attr_reader :name

        # Verify only. Returns an Axn::Result.
        def verify(request)
          Verify.call(request:, verifier: @verifier)
        end

        # Full pipeline: verify, then (if a dispatch is declared and verification passed)
        # parse + route to the handler. Returns the final Axn::Result.
        def handle(request)
          verified = verify(request)
          return verified unless verified.ok? && @dispatch

          Dispatch.call(request:, router: @dispatch[:router], parse: @dispatch[:parse])
        end
```

Update `Axn::Webhooks.inbound` (`lib/axn/webhooks/inbound.rb`) to pass the dispatch config:

```ruby
      dsl = Inbound::DSL.new
      dsl.instance_exec(&block)
      Inbound.register(name, Inbound::Endpoint.new(name:, verifier: dsl.__verifier__, dispatch: dsl.__dispatch__))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/axn/webhooks/inbound/handle_spec.rb`
Expected: PASS.

- [ ] **Step 5: Update CHANGELOG and commit**

```markdown
- `dispatch` DSL + `Axn::Webhooks::Inbound::Endpoint#handle` — declare routing in an `inbound` block (`dispatch to:`/`on:`/`otherwise:`/`via:`/`parse:`); `handle(request)` runs verify then dispatch and returns the final `Axn::Result`.
```

```bash
git add lib/axn/webhooks/inbound/dsl.rb lib/axn/webhooks/inbound/endpoint.rb lib/axn/webhooks/inbound.rb spec/axn/webhooks/inbound/handle_spec.rb CHANGELOG.md
git commit -m "feat: add dispatch DSL and Endpoint#handle pipeline"
```

---

## Task 4: Phase 3 wrap-up — full verify + README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Run the full dual suite**

Run: `bundle exec rake verify`
Expected: all library specs + Rails dummy-app specs pass, rubocop clean, output pristine. Fix any rubocop offenses in the new files.

- [ ] **Step 2: Extend the README "Inbound endpoints" section**

After the existing verify examples (and before the "Note on block scoping"), add a dispatch subsection:

```markdown
### Dispatch to a handler

Add `dispatch` to route the (verified, parsed) event to a handler Axn. The body is parsed as
JSON by default (string keys) — pass `parse:` for other bodies. Handlers receive the whole
event as `event:`, or scalar args via a `with:` extractor.

​```ruby
Axn::Webhooks.inbound :codat do
  verify :standard_webhooks, secret: ENV.fetch("CODAT_WEBHOOK_SECRET")
  dispatch on: ->(e) { e["eventType"] },
           to: { "connection.updated" => "Actions::Codat::ConnectionUpdated" },
           otherwise: :ack        # unknown-but-expected events: log + 2xx (omit to raise loudly)
end

# One endpoint, one handler; form-encoded body:
Axn::Webhooks.inbound :twilio do
  verify { |req| Twilio::Security::RequestValidator.new(ENV.fetch("TWILIO_AUTH_TOKEN"))
                   .validate(req.url, req.params, req.header("X-Twilio-Signature")) }
  dispatch to: "Actions::Twilio::HandleSms", parse: ->(req) { req.params }
end

result = Axn::Webhooks::Inbound[:codat].handle(request)  # verify + dispatch => Axn::Result
​```

A missing handler class or an unmatched event with no `otherwise:` is reported to your
`Axn.config.on_exception` and returned as a failed result — never an unhandled exception.
Handlers run **synchronously** for now; async dispatch arrives in a later phase.
```

**Write standard triple-backtick fences — the leading zero-width space is a docs-escaping artifact; do not copy it.**

- [ ] **Step 3: Re-run `bundle exec rake verify`, then commit**

```bash
git add README.md
git commit -m "docs: document dispatch; close Phase 3"
```

---

## Self-Review (Phase 3)

- **Spec coverage:** single `to:` ✅ Task 1/3; keyed `on:`+map ✅ Task 1/3; convention `to:` String + `via:` ✅ Task 1; `with:` scalar extractor ✅ Task 1; `otherwise:` `:ack`/proc/loud-default ✅ Task 1/2; body→`event` JSON default + `parse:` override ✅ Task 2/3; Dispatch-as-Axn with staged outcomes (verify mismatch / missing handler / unmatched / handler fail! / handler crash / ack) ✅ Task 2/3; `Endpoint#handle` pipeline ✅ Task 3. Deferred: `respond` + HTTP status mapping + async `mode:` (Phase 4), Rack mount + `challenge` + `vendor_facet` (Phase 5).
- **Placeholder scan:** none — every code step is complete with exact commands.
- **Type consistency:** `Router#resolve → [handler_class, kwargs] | :ack`, `Parsers.build → callable`, `Dispatch.call(request:, router:, parse:)`, `Endpoint.new(…, dispatch:)`, `Endpoint#handle(request)`, `dsl.__dispatch__ → {router:, parse:}|nil` are used identically across tasks.
- **Boundary invariant:** all raises (missing handler, unmatched, parse error, handler crash) occur inside the `Dispatch` Axn → reported once + formatted result; verified against axn's `call!` semantics in Grounding.
```
