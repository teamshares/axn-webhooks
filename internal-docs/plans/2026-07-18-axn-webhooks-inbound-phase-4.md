# axn-webhooks Inbound — Phase 4 (respond + staged HTTP outcome + async seam) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Status (2026-07-18):** all decisions RESOLVED with the user — see the "## Decisions (resolved)" section below. Key calls: dynamic async mode (Decision D — async when an adapter is configured, else sync; a custom `respond` forces sync), and the endpoint method is `Endpoint#to_response` (Decision C). Ready to execute.

**Goal:** Add the `respond` half of the inbound DSL and the staged HTTP outcome mapping: a Rails-agnostic `Response` (status/body/headers) built from the verify→dispatch pipeline's `Axn::Result`, plus the `dispatch mode: :async | :sync` seam that delegates to the handler's own `.call_async`/`.call!` — never branching on which async adapter the app configured.

**Architecture:** A new `Axn::Webhooks::Response` value object (status/body/headers). A `respond` DSL declaration captures a block that maps a **genuine handler success** to a `Response`; it runs `instance_exec`'d against a small `RespondContext` exposing `ack`/`text`/`xml` helpers, mirroring how `verify`'s custom block gets `header`/`params`/etc. from the `DSL`. `Endpoint` gains `#to_response(request) → Response`, a *third* pipeline-depth method alongside `#verify`/`#handle` — it re-runs verify→dispatch (not reusing `#handle`'s return value, since the HTTP mapping needs to know which *stage* produced the `Axn::Result`, not just its outcome) and maps each stage's `Axn::Result` to a `Response` per the spec's staged table. `Dispatch` resolves sync-vs-async **at dispatch time** (Decision D): explicit `mode:` wins; else a custom `respond` forces sync; else async when an adapter is configured for the resolved handler (presence check only), else sync — then invokes `call!` or `call_async`. The adapter (`:sidekiq`/`:active_job`/none) is 100% axn's concern; this gem never branches on adapter type.

**Tech Stack:** Ruby ≥ 3.2.1, `axn` + stdlib only. No Rails/Rack required (Rack mount is Phase 5).

**Spec:** `internal-docs/specs/2026-07-17-axn-webhooks-inbound-design.md` — read **"### 4. Respond + staged outcome model"** (the staged HTTP + `on_exception` table) and **"Amendment — Phase 3 dispatch"** (the async seam paragraph: "designed against axn's async interface, never branching on `:sidekiq`/`:active_job`"). Phases 1–3 (`Request`, `Signature`, `Verify`, `verify`/`dispatch` DSL, `Router`, `Parsers`, `Dispatch`, `Endpoint#handle`) are merged to `main`; this repo is currently on that branch.

---

## Decisions (resolved)

All five points below were resolved with the user on 2026-07-18. The tasks implement these settled choices.

### A. The `Response` shape + respond-block helpers — `Response.new` + `.ack`/`.text`/`.xml`, no fourth escape hatch yet (YAGNI)

**Settled:** a small frozen value object plus three factory helpers, no more:

```ruby
Axn::Webhooks::Response.new(status: 200, body: "", headers: {})  # low-level constructor
Axn::Webhooks::Response.ack(status: 200)                          # bare ack — the default
Axn::Webhooks::Response.text(body, status: 200, headers: {})      # DropboxSign
Axn::Webhooks::Response.xml(body, status: 200, headers: {})       # Twilio TwiML
```

Inside a `respond { |result| ... }` block, these are available as **bare calls** (`ack`, `text("...")`, `xml(result.twiml)`) via `instance_exec` against a `RespondContext` that just delegates to the `Response` class methods — this matches the spec's literal syntax (`render xml: r.twiml` → `xml(r.twiml)`) and mirrors the existing pattern where `verify`'s custom block gets `header`/`params`/`raw_body`/`url` as bare calls from the `DSL`.

**Rationale:** the spec names exactly two real custom cases (a literal string, an XML body) plus the default ack — three helpers cover 100% of the surveyed vendors with no speculative generality (no `json`/`html` helpers invented ahead of a real need).

**Settled:** helper names are `ack`/`text`/`xml`; no fourth escape hatch ships now (add only when a vendor needs it — YAGNI).

### B. What `respond`'s proc receives — the handler's own `Axn::Result`, only on genuine success

**Settled:** `respond`'s block receives the handler's own `Axn::Result` (`dispatch_result.handler_result`) — **and only fires for a genuine handler success** (a real handler ran and its own result is `ok?`). Every other 2xx-bound path — `otherwise: :ack` (no handler ran), a handler business `fail!` (a handler ran but didn't succeed), and a verify-only endpoint with no `dispatch` declared — always gets the **default bare ack**, regardless of whether a custom `respond` was declared.

**Rationale:** this follows the spec's staged table literally — only the **"success"** row says "the respond body"; the `otherwise: :ack` row and the handler-`fail!` row each specify a bare 2xx directly, with no mention of `respond`. It also sidesteps a nil-handling footgun: if `respond`'s block always ran (even on `otherwise: :ack`, where there's no handler result), a block like `->(r){ xml(r.twiml) }` would raise `NoMethodError` on `nil` for that path — small enough to be exactly the kind of accidental behavior TDD should catch, so the plan tests it explicitly (Task 3).

**How the endpoint threads it:** already possible with zero changes to `Dispatch` — it already exposes `handler_result` (`allow_nil: true`), confirmed reading the current `lib/axn/webhooks/dispatch.rb` on this branch. **No Phase 3 code change is needed for this.** The subtlety is on the `Endpoint` side: `#handle`'s existing short-circuit (`return verified unless verified.ok? && @dispatch`) returns the bare *Verify* `Axn::Result` on the no-dispatch/verify-failure paths, which has no `handler_result` field at all — so the new HTTP-mapping method must not call `.handler_result` on a result that might be a `Verify` result. See Decision C for how that's avoided structurally rather than by duck-typing.

### C. Where the HTTP mapping lives — `Endpoint#to_response(request) → Response`

**Settled:** `Endpoint#to_response(request) → Response` — a third method alongside the existing `#verify(request) → Axn::Result` and `#handle(request) → Axn::Result`. The name is `to_response` (not `respond`) to avoid conceptual overlap with the `respond` DSL declaration verb. It does **not** reuse `#handle`: it re-runs verify, then (if verification passed and a dispatch is declared) re-runs `Dispatch`, but keeps the two stages in **separate code branches** — verify's branch always maps `!ok? → 401`; dispatch's branch maps `exception? → 500`, `failure? → ack`, `handler_result.nil? → ack`, else runs the custom `respond`. This is what makes the mapping **stage-aware by construction**: a verify failure and a handler `fail!` are both `outcome.failure?`, but they're handled in different branches that were never at risk of being unified into one `outcome → status` rule. **`call(env)` is reserved for Phase 5's Rack app and is not used here.**

### D. Async default — RESOLVED 2026-07-18 (dynamic, not static)

**Settled model (supersedes the spec's literal "`:async` is the default" AND the earlier static-`:sync` recommendation). Two classes of hooks; mode is resolved at dispatch time:**

1. **Explicit `dispatch mode: :sync | :async`** → always honored (the escape hatch).
2. **Otherwise, a hook with a custom `respond`** (a result-returning hook — TwiML, literal text) → **`:sync`**. You can't read a handler result you enqueued, so a declared `respond` forces sync. ("Declared a custom `respond`" is the proxy for "class 2"; the rare static-body-but-async hook uses explicit `mode: :async`.)
3. **Otherwise (default bare ack — class 1)** → **`:async` if an axn async adapter is configured for the resolved handler, else `:sync` fallback.**

**"Adapter configured" detection** (grounded): async is available for a handler when `handler_class._async_adapter` is non-nil (an explicit `async :sidekiq`/`async :active_job` on the handler) **OR** `Axn.config._default_async_adapter` is truthy (a host-app global default; defaults to `false`). This is a **presence** check only — it decides async-vs-sync, and never branches on *which* adapter. This is why the "never branch on the adapter" constraint is relaxed to "never branch on adapter **type**" (see Global Constraints): detecting whether *any* adapter exists is required by this model and is adapter-agnostic.

**Why dynamic (grounded):** `call_async` on a handler with no adapter (and no global default) raises `NotImplementedError` immediately (`lib/axn/async.rb`; `_default_async_adapter` defaults to `false` in `lib/axn/configuration.rb`). A static `:async` default would 500 every request in a standalone/no-adapter context; a static `:sync` default would never use async even where it's configured and wanted. The dynamic rule gives the best of both: async-preferred **when available**, safe sync fallback otherwise, and forced sync for result-returning hooks.

- **Internal `mode:` sentinel:** the DSL's `dispatch mode:` defaults to `:auto` (the dynamic case). A consumer only ever writes `:sync`/`:async` explicitly; `:auto` is the internal default that triggers rule 2/3 resolution.

### E. `mode: :async` + custom `respond` conflict → eager boot-time raise

An **explicit** `dispatch mode: :async` combined with a custom `respond` block is contradictory (async produces no synchronous `handler_result` for `respond` to read). Validate **eagerly at `inbound` registration (boot) time**: raise `Axn::Webhooks::Error` naming the conflict — consistent with this gem's fail-fast style (missing `verify`, missing `to:`, unknown `parse:`/`mode:`). The common compositions need no special-casing: `mode: :auto` + `respond` resolves to `:sync` (rule 2); `mode: :async` + no `respond` acks immediately (`handler_result: nil` routes through the ack branch of Decision C's mapping).

---

## Global Constraints

- **Ruby ≥ 3.2.1.** Dependencies: `axn` + stdlib only. No teamshares-rails/ActionController/Rack; no unguarded `Rails`/`ActiveRecord`/`ActiveJob`.
- **Nothing escapes the Axn boundary.** `Dispatch` remains the single place a handler is invoked (`call!` or `call_async`); any raise (missing handler, parse error, handler crash, **or a `call_async` with no adapter configured**) lands in axn's exception bucket, never an unhandled raise up the stack.
- **Stage-aware HTTP mapping, not outcome-only.** Verify's `!ok? → 401` and Dispatch's outcome→status rules must live in structurally separate branches (Decision C) — never a single `outcome.failure? → X` rule shared across stages, because a verify failure (401) and a handler `fail!` (2xx) are both `outcome.failure?` but mean opposite things.
- **Async delegates to axn's async interface — never branches on adapter TYPE.** Enqueuing is `handler_class.call_async(**args)` and nothing else; this gem must never reference `:sidekiq`, `:active_job`, or any adapter-specific API. It MAY detect adapter *presence* (`handler_class._async_adapter` / `Axn.config._default_async_adapter`) to choose async-vs-sync per Decision D — that check is adapter-agnostic (it never asks *which* adapter).
- **Mode resolves dynamically (Decision D):** explicit `mode:` wins; else a custom `respond` forces `:sync`; else `:async` if an adapter is configured for the resolved handler, else `:sync`. An **explicit** `mode: :async` + custom `respond` is a boot-time validation error (Decision E) — never a silent override.
- **`respond` only fires on a genuine handler success** (`handler_result` present and `ok?`); every other path (ack, handler `fail!`, verify failure/exception, no dispatch declared) gets the default bare ack Response regardless of a declared `respond` (Decision B).
- **Registry stays test-resettable** (`Axn::Webhooks::Inbound.reset!`); reset in an `after` hook.
- **CHANGELOG** under `## [Unreleased]`. **Done =** `bundle exec rake verify` green. **TDD** always.

## Grounding notes (verified this session against the installed `axn` and the current branch's code)

- **`Dispatch` already exposes `handler_result` (`allow_nil: true`)** — confirmed reading `lib/axn/webhooks/dispatch.rb` on this branch (Phase 3 anticipated this; the CHANGELOG's Phase 3 entry documents it too). **No change needed here for Phase 4** — Decision B's "how does the handler result reach `respond`" is already solved by existing code; the work is entirely on the `Endpoint`/mapping side.
- **`Endpoint#handle`'s short-circuit returns the bare `Verify` `Axn::Result`** on a verify failure or a no-`dispatch` endpoint (`lib/axn/webhooks/inbound/endpoint.rb`) — that object has no `handler_result` reader at all (it's a different axn's `Result`). Confirms Decision C: the new mapping method must not `.handler_result` a result that might have come from `Verify`.
- **`call_async` with no adapter configured raises `NotImplementedError`** — read directly from `lib/axn/async.rb` in the installed gem (`bundle show axn`): `_enqueue_async_job` (the un-overridden base implementation) raises `"No async adapter configured. Use e.g. \`async :sidekiq\` or \`async :active_job\`..."`; `Axn.config._default_async_adapter` defaults to `false` (`lib/axn/configuration.rb:183`). This is the grounding fact behind Decision D.
- **Adapter-presence detection attrs (for Decision D's dynamic resolution):** an Axn class carries `_async_adapter` (a `class_attribute`, default `nil`, set by an `async ...` declaration — `lib/axn/async.rb`) with a public reader `handler_class._async_adapter`; the global default is `Axn.config._default_async_adapter` (default `false`). Both are readable without loading any adapter. In tests, `HandlerClass._async_adapter = :sidekiq` (the class_attribute writer) *marks* a handler async-configured without loading Sidekiq — combine with an RSpec stub of `HandlerClass.call_async` so no real adapter runs.
- **`expects` supports `default:`** (confirmed in `lib/axn/core/contract.rb`) — used for `Dispatch`'s new `expects :mode, default: :auto` and `expects :respond_declared, default: false, allow_blank: true`.
- **`Axn::Result#outcome`** returns an `ActiveSupport::StringInquirer` (`"success"`/`"failure"`/`"exception"`) with `.success?`/`.failure?`/`.exception?` predicates (`lib/axn/result.rb`) — used for the dispatch-stage branch.
- **axn's own auto-logging already covers the spec's "+ log" annotation** on the handler-`fail!` row — `Dispatch`'s `call!` invocation is already auto-logged per axn's automatic per-call logging (silenced in this repo's `spec_helper.rb` via a null logger, per the Phase 3 plan's grounding notes). No extra logging code is added in this plan.

---

## File Structure (Phase 4)

- Create `lib/axn/webhooks/response.rb` — `Response` (status/body/headers value object + `.ack`/`.text`/`.xml` factories).
- Create `lib/axn/webhooks/inbound/respond_context.rb` — the `instance_exec` context for a `respond` block (`ack`/`text`/`xml` as bare calls).
- Modify `lib/axn/webhooks/inbound/dsl.rb` — add `respond(&block)` capture + `__respond__`; add `mode:` to `dispatch(...)` + validate it in `__dispatch__`.
- Modify `lib/axn/webhooks/dispatch.rb` — add `expects :mode, default: :auto` + `expects :respond_declared, default: false`; resolve sync/async (Decision D) and branch `call!` vs `call_async`.
- Modify `lib/axn/webhooks/inbound/endpoint.rb` — accept `respond:`; validate the `mode: :async` + custom `respond` conflict; thread `mode:` into `#handle`'s `Dispatch.call`; add `#to_response(request) → Response`.
- Modify `lib/axn/webhooks/inbound.rb` — pass `respond: dsl.__respond__` when building the `Endpoint`.
- Modify `lib/axn/webhooks.rb` — require the new files.
- Modify `CHANGELOG.md`, `README.md`.
- Tests under `spec/axn/webhooks/`.

---

## Task 1: `Axn::Webhooks::Response` — the Rails-agnostic HTTP response value

A frozen value object (status/body/headers) plus the three factory helpers named in Decision A. No Axn, no Rack — Phase 5 renders this against Rack.

**Files:**
- Create: `lib/axn/webhooks/response.rb`
- Modify: `lib/axn/webhooks.rb` (require)
- Test: `spec/axn/webhooks/response_spec.rb`

**Interfaces:**
- `Axn::Webhooks::Response.new(status: 200, body: "", headers: {})` — frozen; `#status`, `#body` (stringified), `#headers` (string-keyed).
- `.ack(status: 200, headers: {})` → bare ack (empty body).
- `.text(body, status: 200, headers: {})` → `Content-Type: text/plain` (caller's `headers:` can override).
- `.xml(body, status: 200, headers: {})` → `Content-Type: application/xml` (caller's `headers:` can override).
- `#==` for value equality (test convenience; also useful to Phase 5 or any caller comparing responses).

- [ ] **Step 1: Write the failing test**

```ruby
# spec/axn/webhooks/response_spec.rb
# frozen_string_literal: true

RSpec.describe Axn::Webhooks::Response do
  it "defaults to a bare 200 ack with no body and no headers" do
    response = described_class.ack
    expect(response.status).to eq(200)
    expect(response.body).to eq("")
    expect(response.headers).to eq({})
  end

  it "supports a custom status on ack" do
    expect(described_class.ack(status: 201).status).to eq(201)
  end

  it "builds a text/plain body" do
    response = described_class.text("Hello API Event Received")
    expect(response.status).to eq(200)
    expect(response.body).to eq("Hello API Event Received")
    expect(response.headers).to eq("Content-Type" => "text/plain")
  end

  it "builds an xml body" do
    response = described_class.xml("<Response></Response>")
    expect(response.body).to eq("<Response></Response>")
    expect(response.headers).to eq("Content-Type" => "application/xml")
  end

  it "lets a caller override the default Content-Type header" do
    response = described_class.text("hi", headers: { "Content-Type" => "text/csv" })
    expect(response.headers).to eq("Content-Type" => "text/csv")
  end

  it "stringifies a non-String body" do
    expect(described_class.new(body: 200).body).to eq("200")
  end

  it "is frozen" do
    expect(described_class.ack).to be_frozen
  end

  it "supports value equality" do
    expect(described_class.text("hi")).to eq(described_class.text("hi"))
    expect(described_class.text("hi")).not_to eq(described_class.text("bye"))
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/webhooks/response_spec.rb`
Expected: FAIL — `uninitialized constant Axn::Webhooks::Response`.

- [ ] **Step 3: Write minimal implementation**

```ruby
# lib/axn/webhooks/response.rb
# frozen_string_literal: true

module Axn
  module Webhooks
    # A Rails-agnostic HTTP response value: status + body + headers. Produced by
    # `Endpoint#to_response` from the verify->dispatch pipeline's Axn::Result; Phase 5's Rack
    # mount renders this — nothing here touches Rack.
    class Response
      attr_reader :status, :body, :headers

      def initialize(status: 200, body: "", headers: {})
        @status = status
        @body = body.to_s
        @headers = headers.transform_keys(&:to_s)
        freeze
      end

      def self.ack(status: 200, headers: {}) = new(status:, headers:)

      def self.text(body, status: 200, headers: {})
        new(status:, body:, headers: { "Content-Type" => "text/plain" }.merge(headers))
      end

      def self.xml(body, status: 200, headers: {})
        new(status:, body:, headers: { "Content-Type" => "application/xml" }.merge(headers))
      end

      def ==(other)
        other.is_a?(self.class) && status == other.status && body == other.body && headers == other.headers
      end
    end
  end
end
```

```ruby
# lib/axn/webhooks.rb — add below `require_relative "webhooks/request"`
require_relative "webhooks/response"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/axn/webhooks/response_spec.rb`
Expected: PASS.

- [ ] **Step 5: Update CHANGELOG and commit**

```markdown
- `Axn::Webhooks::Response` — a Rails-agnostic HTTP response value (status/body/headers) with `.ack`/`.text`/`.xml` factories, produced by the staged HTTP outcome mapping and rendered against Rack in a later phase.
```

```bash
git add lib/axn/webhooks/response.rb lib/axn/webhooks.rb spec/axn/webhooks/response_spec.rb CHANGELOG.md
git commit -m "feat: add Axn::Webhooks::Response value object"
```

---

## Task 2: `respond` DSL + `RespondContext`

Captures a `respond { |result| ... }` block on the `inbound` block, and the `instance_exec` context that gives it `ack`/`text`/`xml` as bare calls. This task only wires the *declaration*; `Endpoint#to_response` (Task 3) is what actually runs it.

**Files:**
- Create: `lib/axn/webhooks/inbound/respond_context.rb`
- Modify: `lib/axn/webhooks/inbound/dsl.rb`
- Modify: `lib/axn/webhooks.rb` (require)
- Test: `spec/axn/webhooks/inbound/respond_context_spec.rb`, `spec/axn/webhooks/inbound/dsl_respond_spec.rb`

**Interfaces:**
- `Axn::Webhooks::Inbound::RespondContext.new` — `#ack`/`#text(body)`/`#xml(body)` delegate to `Response`.
- `DSL#respond(&block)` captures the block; `DSL#__respond__` → the block or `nil` if undeclared.

- [ ] **Step 1: Write the failing tests**

```ruby
# spec/axn/webhooks/inbound/respond_context_spec.rb
# frozen_string_literal: true

RSpec.describe Axn::Webhooks::Inbound::RespondContext do
  subject(:context) { described_class.new }

  it "builds a bare ack" do
    expect(context.ack).to eq(Axn::Webhooks::Response.ack)
  end

  it "builds a text response" do
    expect(context.text("hi")).to eq(Axn::Webhooks::Response.text("hi"))
  end

  it "builds an xml response" do
    expect(context.xml("<a/>")).to eq(Axn::Webhooks::Response.xml("<a/>"))
  end

  it "instance_execs a respond block so its bare helper calls resolve against this context" do
    block = ->(result) { text("seen: #{result}") }
    expect(context.instance_exec("ok", &block)).to eq(Axn::Webhooks::Response.text("seen: ok"))
  end
end
```

```ruby
# spec/axn/webhooks/inbound/dsl_respond_spec.rb
# frozen_string_literal: true

RSpec.describe Axn::Webhooks::Inbound::DSL do
  describe "#respond" do
    it "defaults __respond__ to nil when undeclared" do
      expect(described_class.new.__respond__).to be_nil
    end

    it "captures the declared block" do
      dsl = described_class.new
      block = ->(r) { text(r.to_s) }
      dsl.respond(&block)
      expect(dsl.__respond__).to eq(block)
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/axn/webhooks/inbound/respond_context_spec.rb spec/axn/webhooks/inbound/dsl_respond_spec.rb`
Expected: FAIL — `uninitialized constant Axn::Webhooks::Inbound::RespondContext` / `undefined method 'respond'`.

- [ ] **Step 3: Write minimal implementation**

```ruby
# lib/axn/webhooks/inbound/respond_context.rb
# frozen_string_literal: true

module Axn
  module Webhooks
    module Inbound
      # instance_exec context for a `respond` block: exposes `ack`/`text`/`xml` as bare calls,
      # so a respond proc reads `text("...")` rather than `Axn::Webhooks::Response.text("...")` —
      # mirrors how the `verify` custom block gets `header`/`params`/etc. as bare calls from DSL.
      class RespondContext
        def ack(**opts) = Response.ack(**opts)
        def text(body, **opts) = Response.text(body, **opts)
        def xml(body, **opts) = Response.xml(body, **opts)
      end
    end
  end
end
```

Add to `DSL` (`lib/axn/webhooks/inbound/dsl.rb`), below `dispatch`:

```ruby
        # respond { |handler_result| text("...") } — maps a genuine handler success to a
        # Response. Every other outcome (ack, business fail!, verify failure/exception, or a
        # no-dispatch endpoint) always gets the default bare ack, regardless of this declaration
        # — see Endpoint#to_response.
        def respond(&block)
          @respond_block = block
        end
```

Add to `DSL`, below `__dispatch__`:

```ruby
        # Internal: the captured respond block, or nil if none declared.
        def __respond__ = @respond_block
```

```ruby
# lib/axn/webhooks.rb — add below `require_relative "webhooks/inbound/parsers"`
require_relative "webhooks/inbound/respond_context"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/axn/webhooks/inbound/respond_context_spec.rb spec/axn/webhooks/inbound/dsl_respond_spec.rb`
Expected: PASS.

- [ ] **Step 5: Update CHANGELOG and commit**

```markdown
- `respond` DSL declaration + `Axn::Webhooks::Inbound::RespondContext` — captures a block mapping a genuine handler success to a `Response`; the block runs with `ack`/`text`/`xml` available as bare calls.
```

```bash
git add lib/axn/webhooks/inbound/respond_context.rb lib/axn/webhooks/inbound/dsl.rb lib/axn/webhooks.rb spec/axn/webhooks/inbound/respond_context_spec.rb spec/axn/webhooks/inbound/dsl_respond_spec.rb CHANGELOG.md
git commit -m "feat: add respond DSL declaration and RespondContext"
```

---

## Task 3: `Endpoint#to_response(request) → Response` — the staged HTTP outcome mapping

*Implements the settled Decisions B and C.* The core Phase 4 deliverable: runs verify → dispatch and maps each stage's `Axn::Result` to a `Response` per the spec's table, in two structurally separate branches (Decision C) so a verify failure (401) and a handler `fail!` (2xx) — both `outcome.failure?` — never share a status rule.

**Files:**
- Modify: `lib/axn/webhooks/inbound/endpoint.rb`
- Modify: `lib/axn/webhooks/inbound.rb`
- Test: `spec/axn/webhooks/inbound/respond_spec.rb`

**Interfaces:**
- `Endpoint.new(name:, verifier:, dispatch: nil, respond: nil)`.
- `Endpoint#to_response(request) → Response` — the full staged mapping:
  - Verify not `ok?` (mismatch **or** a verifier crash) → `Response.new(status: 401)`.
  - No `dispatch` declared and verify `ok?` → `Response.ack`.
  - Dispatch `outcome.exception?` (missing/unresolvable handler, unmatched-no-`otherwise`, parse error, handler crash) → `Response.new(status: 500)`.
  - Dispatch `outcome.failure?` (handler business `fail!`) → `Response.ack`.
  - Dispatch `outcome.success?` with `handler_result.nil?` (`otherwise: :ack` path) → `Response.ack`.
  - Dispatch `outcome.success?` with a `handler_result` present → the declared `respond` block's `Response`, or `Response.ack` if none declared.

- [ ] **Step 1: Write the failing test**

```ruby
# spec/axn/webhooks/inbound/respond_spec.rb
# frozen_string_literal: true

RSpec.describe "Axn::Webhooks::Inbound::Endpoint#to_response (staged HTTP outcome mapping)" do
  after { Axn::Webhooks::Inbound.reset! }

  before do
    stub_const("Handlers", Module.new)
    stub_const("Handlers::Created", Class.new do
      include Axn
      expects :event
      exposes :twiml
      def call = expose(twiml: "<Response>ok</Response>")
    end)
    stub_const("Handlers::FailsQuietly", Class.new do
      include Axn
      expects :event, allow_blank: true
      def call = fail!("we don't care")
    end)
    stub_const("Handlers::Boom", Class.new do
      include Axn
      expects :event, allow_blank: true
      def call = raise("handler crashed")
    end)
  end

  def req(body) = Axn::Webhooks::Request.new(raw_body: body)

  it "maps a signature mismatch to 401 without dispatching" do
    Axn::Webhooks.inbound(:vendor) do
      verify { |_req| false }
      dispatch to: "Handlers::Boom"
    end
    response = Axn::Webhooks::Inbound[:vendor].to_response(req("{}"))
    expect(response.status).to eq(401)
  end

  it "maps a verifier crash to 401 (reported, not leaked)" do
    Axn::Webhooks.inbound(:vendor) { verify { |_req| raise "verifier bug" } }
    expect(Axn::Webhooks::Inbound[:vendor].to_response(req("{}")).status).to eq(401)
  end

  it "maps a missing handler class to 500" do
    Axn::Webhooks.inbound(:vendor) do
      verify { |_req| true }
      dispatch to: "Totally::Missing::Handler"
    end
    expect(Axn::Webhooks::Inbound[:vendor].to_response(req("{}")).status).to eq(500)
  end

  it "maps a handler crash to 500" do
    Axn::Webhooks.inbound(:vendor) do
      verify { |_req| true }
      dispatch to: "Handlers::Boom"
    end
    expect(Axn::Webhooks::Inbound[:vendor].to_response(req("{}")).status).to eq(500)
  end

  it "maps an unmatched event with otherwise: :ack to a bare 2xx" do
    Axn::Webhooks.inbound(:vendor) do
      verify { |_req| true }
      dispatch on: ->(e) { e["t"] }, to: { "known" => "Handlers::Created" }, otherwise: :ack
    end
    response = Axn::Webhooks::Inbound[:vendor].to_response(req('{"t":"surprise"}'))
    expect(response.status).to eq(200)
    expect(response.body).to eq("")
  end

  it "maps a handler business fail! to a bare 2xx (quiet, already logged by axn)" do
    Axn::Webhooks.inbound(:vendor) do
      verify { |_req| true }
      dispatch to: "Handlers::FailsQuietly"
    end
    response = Axn::Webhooks::Inbound[:vendor].to_response(req("{}"))
    expect(response.status).to eq(200)
    expect(response.body).to eq("")
  end

  it "defaults a genuine handler success to a bare 2xx ack when no respond is declared" do
    Axn::Webhooks.inbound(:vendor) do
      verify { |_req| true }
      dispatch to: "Handlers::Created"
    end
    response = Axn::Webhooks::Inbound[:vendor].to_response(req("{}"))
    expect(response.status).to eq(200)
    expect(response.body).to eq("")
  end

  it "maps a genuine handler success through a custom respond block (Twilio-style TwiML)" do
    Axn::Webhooks.inbound(:vendor) do
      verify { |_req| true }
      dispatch to: "Handlers::Created"
      respond { |result| xml(result.twiml) }
    end
    response = Axn::Webhooks::Inbound[:vendor].to_response(req("{}"))
    expect(response.status).to eq(200)
    expect(response.body).to eq("<Response>ok</Response>")
    expect(response.headers).to eq("Content-Type" => "application/xml")
  end

  it "supports a literal string body (DropboxSign-style)" do
    Axn::Webhooks.inbound(:vendor) do
      verify { |_req| true }
      dispatch to: "Handlers::Created"
      respond { |_result| text("Hello API Event Received") }
    end
    expect(Axn::Webhooks::Inbound[:vendor].to_response(req("{}")).body).to eq("Hello API Event Received")
  end

  it "returns a bare 2xx ack for a verify-only endpoint (no dispatch declared)" do
    Axn::Webhooks.inbound(:probe) { verify { |_req| true } }
    response = Axn::Webhooks::Inbound[:probe].to_response(req(""))
    expect(response.status).to eq(200)
    expect(response.body).to eq("")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/webhooks/inbound/respond_spec.rb`
Expected: FAIL — `undefined method 'respond' for an instance of Axn::Webhooks::Inbound::Endpoint` / `unknown keyword: :respond` for `Endpoint.new`.

- [ ] **Step 3: Write minimal implementation**

Update `Endpoint` (`lib/axn/webhooks/inbound/endpoint.rb`):

```ruby
# frozen_string_literal: true

module Axn
  module Webhooks
    module Inbound
      # A registered inbound webhook endpoint.
      class Endpoint
        def initialize(name:, verifier:, dispatch: nil, respond: nil)
          @name = name.to_sym
          @verifier = verifier
          @dispatch = dispatch
          @respond = respond
        end

        attr_reader :name

        # Verify the request's signature. Returns an Axn::Result: ok? when verified,
        # a failure on mismatch, an exception if the verifier raises.
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

        # The staged HTTP outcome mapping (spec: "Respond + staged outcome model"). Verify and
        # dispatch are mapped in separate branches — deliberately NOT a single outcome->status
        # rule, because a verify failure (401) and a handler business fail! (2xx) are both
        # `outcome.failure?` but mean opposite things at the HTTP layer.
        def to_response(request)
          verified = verify(request)
          return Response.new(status: 401) unless verified.ok?
          return Response.ack unless @dispatch

          dispatched = Dispatch.call(request:, router: @dispatch[:router], parse: @dispatch[:parse])
          response_for(dispatched)
        end

        private

        def response_for(dispatched)
          return Response.new(status: 500) if dispatched.outcome.exception?
          return Response.ack if dispatched.outcome.failure?    # handler fail! -> quiet 2xx, already logged
          return Response.ack if dispatched.handler_result.nil? # otherwise: :ack -> bare ack, nothing to render
          return Response.ack unless @respond

          RespondContext.new.instance_exec(dispatched.handler_result, &@respond)
        end
      end
    end
  end
end
```

Update `Axn::Webhooks.inbound` (`lib/axn/webhooks/inbound.rb`) to pass the respond block:

```ruby
      dsl = Inbound::DSL.new
      dsl.instance_exec(&block)
      Inbound.register(name, Inbound::Endpoint.new(
        name:,
        verifier: dsl.__verifier__,
        dispatch: dsl.__dispatch__,
        respond: dsl.__respond__,
      ))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/axn/webhooks/inbound/respond_spec.rb`
Expected: PASS.

- [ ] **Step 5: Update CHANGELOG and commit**

```markdown
- `Axn::Webhooks::Inbound::Endpoint#to_response(request) → Response` — the staged HTTP outcome mapping: verify mismatch/crash → 401; missing handler/unmatched/parse error/handler crash → 500; `otherwise: :ack` and handler business `fail!` → a bare 2xx ack; a genuine handler success → the declared `respond` block's body (default bare ack).
```

```bash
git add lib/axn/webhooks/inbound/endpoint.rb lib/axn/webhooks/inbound.rb spec/axn/webhooks/inbound/respond_spec.rb CHANGELOG.md
git commit -m "feat: add Endpoint#to_response staged HTTP outcome mapping"
```

---

## Task 4: async `mode:` seam — dynamic resolution (`Dispatch` + DSL + validation)

*Implements the settled Decisions D and E (dynamic mode resolution; eager boot-time raise on explicit `mode: :async` + custom `respond`).* `Dispatch` resolves sync-vs-async **at dispatch time** from three inputs — the explicit `mode:` (`:auto` default), whether a custom `respond` was declared (`respond_declared`), and whether an async adapter is configured for the *resolved handler* — then invokes `call!` or `call_async`. It never branches on adapter type.

**Files:**
- Modify: `lib/axn/webhooks/dispatch.rb`
- Modify: `lib/axn/webhooks/inbound/dsl.rb`
- Modify: `lib/axn/webhooks/inbound/endpoint.rb`
- Test: `spec/axn/webhooks/dispatch_async_spec.rb`, `spec/axn/webhooks/inbound/async_mode_spec.rb`

**Interfaces:**
- `Dispatch.call(request:, router:, parse:, mode: :auto, respond_declared: false)`:
  - `mode: :sync` → `handler_class.call!(**args)`, exposes `handler_result`.
  - `mode: :async` → `handler_class.call_async(**args)` (receipt discarded), no `handler_result`, settles `success` (`done!("enqueued")`) unless `call_async` raises.
  - `mode: :auto` → **sync** if `respond_declared`; else **async** when an adapter is configured for the resolved handler (`handler_class._async_adapter` non-nil OR `Axn.config._default_async_adapter` truthy), else **sync**.
- `dispatch(..., mode: :auto)` — DSL kwarg; `__dispatch__` raises `Axn::Webhooks::Error` for anything other than `:auto`/`:sync`/`:async` (a consumer only writes `:sync`/`:async`; `:auto` is the internal default).
- `Endpoint.new(...)` raises `Axn::Webhooks::Error` at construction if `dispatch[:mode] == :async` and a `respond:` block is present. `Endpoint#handle`/`#respond` pass `mode:` and `respond_declared: !@respond.nil?` into `Dispatch.call`.

- [ ] **Step 1: Write the failing tests**

```ruby
# spec/axn/webhooks/dispatch_async_spec.rb
# frozen_string_literal: true

RSpec.describe "Axn::Webhooks::Dispatch async resolution" do
  def request(body) = Axn::Webhooks::Request.new(raw_body: body)
  let(:json_parse) { Axn::Webhooks::Parsers.build(:json) }

  before do
    # Non-Axn stub: records call_async. Used where mode is EXPLICITLY :async (no detection).
    stub_const("AsyncHandler", Class.new do
      def self.calls = (@calls ||= [])
      def self.call_async(**kwargs) = calls << kwargs
    end)
    # Real Axn handler, no adapter configured.
    stub_const("SyncHandler", Class.new do
      include Axn
      expects :event, allow_blank: true
      def call = nil
    end)
    # Real Axn handler MARKED async-configured (sets the class_attribute directly — no Sidekiq load);
    # call_async is stubbed so no real adapter runs.
    stub_const("AdapterHandler", Class.new do
      include Axn
      expects :event, allow_blank: true
      def call = nil
    end)
    AdapterHandler._async_adapter = :sidekiq
    allow(AdapterHandler).to receive(:call_async)
  end

  it "explicit :async delegates to call_async and exposes no handler_result" do
    router = Axn::Webhooks::Inbound::Router.new(to: "AsyncHandler")
    result = Axn::Webhooks::Dispatch.call(request: request('{"a":1}'), router:, parse: json_parse, mode: :async)
    expect(result).to be_ok
    expect(result.handler_result).to be_nil
    expect(AsyncHandler.calls).to eq([{ event: { "a" => 1 } }])
  end

  it "explicit :async with no adapter configured settles as a loud (500-bound) exception" do
    router = Axn::Webhooks::Inbound::Router.new(to: "SyncHandler")
    result = Axn::Webhooks::Dispatch.call(request: request("{}"), router:, parse: json_parse, mode: :async)
    expect(result.outcome).to be_exception
    expect(result.exception).to be_a(NotImplementedError)
  end

  it "explicit :sync runs synchronously even if an adapter is configured" do
    router = Axn::Webhooks::Inbound::Router.new(to: "AdapterHandler")
    result = Axn::Webhooks::Dispatch.call(request: request("{}"), router:, parse: json_parse, mode: :sync)
    expect(result.handler_result).to be_ok
    expect(AdapterHandler).not_to have_received(:call_async)
  end

  describe "mode: :auto (default)" do
    it "runs SYNC when no adapter is configured for the handler" do
      router = Axn::Webhooks::Inbound::Router.new(to: "SyncHandler")
      result = Axn::Webhooks::Dispatch.call(request: request("{}"), router:, parse: json_parse) # mode defaults to :auto
      expect(result.handler_result).to be_ok
    end

    it "runs ASYNC when an adapter IS configured for the handler" do
      router = Axn::Webhooks::Inbound::Router.new(to: "AdapterHandler")
      result = Axn::Webhooks::Dispatch.call(request: request("{}"), router:, parse: json_parse)
      expect(result.handler_result).to be_nil
      expect(AdapterHandler).to have_received(:call_async).with(event: {})
    end

    it "runs ASYNC when a global default adapter is configured (presence, not type)" do
      original = Axn.config._default_async_adapter
      Axn.config.instance_variable_set(:@default_async_adapter, :active_job)
      allow(SyncHandler).to receive(:call_async)
      begin
        router = Axn::Webhooks::Inbound::Router.new(to: "SyncHandler")
        result = Axn::Webhooks::Dispatch.call(request: request("{}"), router:, parse: json_parse)
        expect(SyncHandler).to have_received(:call_async)
        expect(result.handler_result).to be_nil
      ensure
        Axn.config.instance_variable_set(:@default_async_adapter, original)
      end
    end

    it "forces SYNC when respond_declared is true, even with an adapter configured" do
      router = Axn::Webhooks::Inbound::Router.new(to: "AdapterHandler")
      result = Axn::Webhooks::Dispatch.call(request: request("{}"), router:, parse: json_parse, respond_declared: true)
      expect(result.handler_result).to be_ok
      expect(AdapterHandler).not_to have_received(:call_async)
    end
  end
end
```

```ruby
# spec/axn/webhooks/inbound/async_mode_spec.rb
# frozen_string_literal: true

RSpec.describe "Axn::Webhooks::Inbound async dispatch mode" do
  after { Axn::Webhooks::Inbound.reset! }

  before do
    stub_const("AsyncHandler", Class.new do
      def self.calls = (@calls ||= [])
      def self.call_async(**kwargs) = calls << kwargs
    end)
  end

  it "acks immediately via a bare 2xx when mode: :async enqueues successfully" do
    Axn::Webhooks.inbound(:vendor) do
      verify { |_req| true }
      dispatch to: "AsyncHandler", mode: :async
    end
    response = Axn::Webhooks::Inbound[:vendor].to_response(Axn::Webhooks::Request.new(raw_body: "{}"))
    expect(response.status).to eq(200)
    expect(response.body).to eq("")
    expect(AsyncHandler.calls).to eq([{ event: {} }])
  end

  it "rejects an unknown mode: at declaration time" do
    expect do
      Axn::Webhooks.inbound(:bad) do
        verify { |_req| true }
        dispatch to: "AsyncHandler", mode: :yolo
      end
    end.to raise_error(Axn::Webhooks::Error, /mode:/)
  end

  it "rejects combining explicit mode: :async with a custom respond block at declaration time" do
    expect do
      Axn::Webhooks.inbound(:bad) do
        verify { |_req| true }
        dispatch to: "AsyncHandler", mode: :async
        respond { |result| text(result.to_s) }
      end
    end.to raise_error(Axn::Webhooks::Error, /handler_result/)
  end

  it "allows mode: :async with no respond declared" do
    expect do
      Axn::Webhooks.inbound(:ok) do
        verify { |_req| true }
        dispatch to: "AsyncHandler", mode: :async
      end
    end.not_to raise_error
  end

  it "a custom respond (mode: :auto) runs sync so respond can read the result" do
    stub_const("TwimlHandler", Class.new do
      include Axn
      expects :event, allow_blank: true
      exposes :twiml
      def call = expose(twiml: "<Response/>")
    end)
    TwimlHandler._async_adapter = :sidekiq # even with an adapter configured, a respond forces sync
    Axn::Webhooks.inbound(:twilio) do
      verify { |_req| true }
      dispatch to: "TwimlHandler"       # mode: :auto
      respond { |result| xml(result.twiml) }
    end
    response = Axn::Webhooks::Inbound[:twilio].to_response(Axn::Webhooks::Request.new(raw_body: "{}"))
    expect(response.body).to eq("<Response/>")
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/axn/webhooks/dispatch_async_spec.rb spec/axn/webhooks/inbound/async_mode_spec.rb`
Expected: FAIL — `unknown keyword: :mode` for `Dispatch.call` / `dispatch(...)`.

- [ ] **Step 3: Write minimal implementation**

Update `Dispatch` (`lib/axn/webhooks/dispatch.rb`):

```ruby
# frozen_string_literal: true

module Axn
  module Webhooks
    # Routes a verified request to its handler Axn. Built as an Axn so every loud failure
    # (missing handler, unmatched key, parse error, handler crash, or an async enqueue with no
    # adapter configured) lands in axn's exception bucket — reported once via on_exception,
    # returned as a formatted result — and a handler business `fail!` stays a quiet failure.
    class Dispatch
      include Axn

      expects :request, type: Axn::Webhooks::Request
      expects :router
      expects :parse
      expects :mode, default: :auto
      expects :respond_declared, default: false, allow_blank: true
      exposes :handler_result, allow_nil: true
      error "Webhook dispatch failed"

      def call
        event = parse.call(request)
        resolution = router.resolve(event)
        return done!("acknowledged") if resolution == :ack

        handler_class, args = resolution
        return dispatch_async(handler_class, args) if async?(handler_class)

        expose handler_result: handler_class.call!(**args)
      end

      private

      # Resolve sync vs async (Decision D): explicit mode wins; a custom respond forces sync;
      # otherwise async when an adapter is configured for THIS handler, else sync.
      def async?(handler_class)
        return true if mode == :async
        return false if mode == :sync
        return false if respond_declared # mode == :auto, result-returning hook

        async_adapter_configured?(handler_class)
      end

      # Presence check ONLY — decides async-vs-sync, never asks which adapter.
      def async_adapter_configured?(handler_class)
        return true if Axn.config._default_async_adapter
        handler_class.respond_to?(:_async_adapter) && !handler_class._async_adapter.nil?
      end

      # Delegates entirely to axn's own async interface; no handler_result (nothing ran
      # synchronously). A call_async with no adapter raises NotImplementedError → loud exception.
      def dispatch_async(handler_class, args)
        handler_class.call_async(**args)
        done!("enqueued")
      end
    end
  end
end
```

Update `DSL#dispatch` and `#__dispatch__` (`lib/axn/webhooks/inbound/dsl.rb`):

```ruby
        # dispatch to: "Handler" | dispatch on: ->(e){…}, to: {map}, otherwise:, via: | parse: | mode:
        # rubocop:disable Naming/MethodParameterName
        def dispatch(to: nil, on: nil, otherwise: nil, via: nil, parse: :json, mode: :auto)
          @dispatch_spec = { to:, on:, otherwise:, via:, parse:, mode: }
        end
        # rubocop:enable Naming/MethodParameterName
```

```ruby
        # Internal: build the { router:, parse:, mode: } dispatch config, or nil if none declared.
        def __dispatch__
          return nil unless @dispatch_spec

          spec = @dispatch_spec
          unless %i[auto sync async].include?(spec[:mode])
            raise Axn::Webhooks::Error, "dispatch mode: must be :sync or :async (got #{spec[:mode].inspect})"
          end

          router = Router.new(to: spec[:to], on: spec[:on], otherwise: spec[:otherwise], via: spec[:via])
          { router:, parse: Parsers.build(spec[:parse]), mode: spec[:mode] }
        end
```

Update `Endpoint` (`lib/axn/webhooks/inbound/endpoint.rb`) — the constructor guard, and thread `mode:` + `respond_declared:` into both `Dispatch.call` sites:

```ruby
        def initialize(name:, verifier:, dispatch: nil, respond: nil)
          if dispatch && dispatch[:mode] == :async && respond
            raise Axn::Webhooks::Error,
                  "inbound endpoint `#{name}` declares a custom `respond` but explicit `dispatch mode: :async` " \
                  "can't produce a handler_result for it to read — use `mode: :sync` (or omit mode) or drop the respond block"
          end

          @name = name.to_sym
          @verifier = verifier
          @dispatch = dispatch
          @respond = respond
        end
```

```ruby
        def handle(request)
          verified = verify(request)
          return verified unless verified.ok? && @dispatch

          Dispatch.call(request:, router: @dispatch[:router], parse: @dispatch[:parse],
                        mode: @dispatch[:mode], respond_declared: !@respond.nil?)
        end
```

```ruby
        def to_response(request)
          verified = verify(request)
          return Response.new(status: 401) unless verified.ok?
          return Response.ack unless @dispatch

          dispatched = Dispatch.call(request:, router: @dispatch[:router], parse: @dispatch[:parse],
                                     mode: @dispatch[:mode], respond_declared: !@respond.nil?)
          response_for(dispatched)
        end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/axn/webhooks/dispatch_async_spec.rb spec/axn/webhooks/inbound/async_mode_spec.rb`
Expected: PASS. Also re-run the full suite: `bundle exec rspec spec/`. (Note: `expects :respond_declared, default: false, allow_blank: true` — `allow_blank` is required because `false.blank?` is true; without it axn's presence check would reject the default. If axn surfaces a different issue with the `false` default, prefer `type: :boolean, default: false` — either is acceptable so long as `false` is a valid value.)

- [ ] **Step 5: Update CHANGELOG and commit**

```markdown
- `dispatch mode:` — the async seam, resolved dynamically: an explicit `:async` delegates to the handler's own `.call_async` (inheriting whatever axn async adapter the app configured — never branches on `:sidekiq`/`:active_job`), an explicit `:sync` runs inline, and the default (`:auto`) runs **async when an adapter is configured for the handler, else sync** — except a custom `respond` (a result-returning hook) always forces sync. An explicit `mode: :async` + custom `respond` is rejected at `inbound` registration time (you can't read a handler result you enqueued).
```

```bash
git add lib/axn/webhooks/dispatch.rb lib/axn/webhooks/inbound/dsl.rb lib/axn/webhooks/inbound/endpoint.rb spec/axn/webhooks/dispatch_async_spec.rb spec/axn/webhooks/inbound/async_mode_spec.rb CHANGELOG.md
git commit -m "feat: add dynamic dispatch mode: seam (async when adapter configured)"
```

---

## Task 5: Phase 4 wrap-up — full verify + README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Run the full dual suite**

Run: `bundle exec rake verify`
Expected: all library specs + Rails dummy-app specs pass, rubocop clean, output pristine. Fix any rubocop offenses in the new files.

- [ ] **Step 2: Extend the README "Inbound endpoints" section**

After the existing "Dispatch to a handler" subsection, add:

```markdown
### Respond with a custom body

By default a successful request gets a bare 2xx ack — most vendors want nothing else. Add
`respond` only for the two real cases that need it: a literal string body, or an
instruction body the handler computed (e.g. TwiML). The block receives the handler's own
`Axn::Result` and runs with `ack`/`text`/`xml` available as bare calls:

​```ruby
# DropboxSign requires this exact literal string:
Axn::Webhooks.inbound :dropbox_sign do
  verify { |req| … }
  dispatch to: "Actions::DropboxSign::HandleWebhook"
  respond { |_result| text("Hello API Event Received") }
end

# Twilio call-control: the handler computes TwiML; respond renders it.
Axn::Webhooks.inbound :twilio do
  verify { |req| Twilio::Security::RequestValidator.new(ENV.fetch("TWILIO_AUTH_TOKEN"))
                   .validate(req.url, req.params, req.header("X-Twilio-Signature")) }
  dispatch to: "Actions::Twilio::HandleCall", parse: ->(req) { req.params }
  respond { |result| xml(result.twiml) }   # handler exposes :twiml
end

response = Axn::Webhooks::Inbound[:dropbox_sign].to_response(request)  # => Axn::Webhooks::Response
response.status   # => 200
response.body     # => "Hello API Event Received"
​```

`respond` only runs for a genuine handler success — an unmatched event acked via
`otherwise: :ack`, a handler's own business `fail!`, and a verify failure or crash all get
their own fixed status (see below) regardless of any declared `respond`.

### The staged HTTP outcome mapping

`Axn::Webhooks::Inbound[:vendor].to_response(request)` runs the whole pipeline and maps the
outcome to an HTTP status:

| Stage | Outcome | Status |
| -- | -- | -- |
| Verify | signature mismatch, or the verifier itself crashes | 401 |
| Dispatch | missing/unresolvable handler, unmatched event with no `otherwise:`, a parse error, or a handler crash | 500 (reported to `Axn.config.on_exception`) |
| Dispatch | unknown-but-expected event (`otherwise: :ack`) | 2xx ack |
| Handle | the handler's own business `fail!` ("we don't care") | 2xx ack (logged) |
| Handle | success | the declared `respond` body, or a bare 2xx ack |

### Async dispatch

By default (`mode: :auto`) a handler runs **async when it has an axn async adapter configured**
(an `async :sidekiq` / `async :active_job` on the handler, or a host-app global default), and
**sync otherwise** — so it works out of the box standalone and automatically uses async once you
wire an adapter up, the same way you would for any other axn. This gem never references a
specific adapter (`:sidekiq`/`:active_job`); it only checks whether one is present.

Pin a mode explicitly when you want to override the default:

​```ruby
Axn::Webhooks.inbound :merge_dev do
  verify :hmac, secret: ENV.fetch("MERGE_WEBHOOK_SIGNATURE_KEY"), signature: header("X-Merge-Webhook-Signature")
  dispatch to: "Actions::MergeDev::HandleWebhook", mode: :async   # force async (handler must have an adapter)
end
​```

A custom `respond` block reads the handler's own result, so those hooks always run **sync** (you
can't read a result you enqueued) regardless of adapter config — and declaring both an explicit
`mode: :async` and a custom `respond` raises at registration time.
```

**Write standard triple-backtick fences — the leading zero-width space above is a docs-escaping artifact; do not copy it.**

- [ ] **Step 3: Re-run `bundle exec rake verify`, then commit**

```bash
git add README.md
git commit -m "docs: document respond, staged HTTP mapping, and async mode; close Phase 4"
```

---

## Self-Review (Phase 4)

- **Spec coverage:** `Response` value + `.ack`/`.text`/`.xml` ✅ Task 1; `respond` DSL + bare-call helpers ✅ Task 2; staged HTTP table (all six rows: verify mismatch/crash → 401, missing handler/unmatched/parse-error/handler-crash → 500, `otherwise: :ack` → 2xx, handler `fail!` → 2xx, success → respond body/default ack) ✅ Task 3; dynamic `mode:` seam (`:auto` → async-if-adapter-else-sync, custom `respond` forces sync, explicit `:sync`/`:async`) delegating strictly to `call!`/`call_async` ✅ Task 4; explicit `mode: :async` + custom `respond` rejected at boot ✅ Task 4. Deferred: Rack mount, `challenge` GET branch, `vendor_facet` (Phase 5).
- **Placeholder scan:** none — every code step is complete with exact commands.
- **Type consistency:** `Response.new(status:, body:, headers:)` / `.ack`/`.text`/`.xml` used identically across tasks; `Dispatch.call(request:, router:, parse:, mode:)`; `Endpoint.new(name:, verifier:, dispatch:, respond:)`; `Endpoint#to_response(request) → Response`; `dsl.__respond__ → Proc | nil`; `dsl.__dispatch__ → { router:, parse:, mode: } | nil`.
- **Boundary invariant:** every dispatch-stage raise (missing handler, unmatched key, parse error, handler crash, **and now a `call_async` with no adapter configured**) occurs inside the `Dispatch` Axn → reported once + formatted result → mapped to 500 by `Endpoint#to_response`, never an unhandled raise up the stack.
- **Stage-awareness invariant:** `Endpoint#to_response` maps verify's `!ok?` and dispatch's `outcome` in separate code branches (never a single shared `outcome.failure? → status` rule) — directly testable via the "signature mismatch → 401" vs. "handler fail! → 2xx" cases in Task 3's spec, both of which are `outcome.failure?` but assert different statuses.
- **All decisions resolved** (see "## Decisions (resolved)"): dynamic async mode (D), `Endpoint#to_response` (C), `respond` only on genuine success (B), `ack`/`text`/`xml` helpers (A), eager-raise on explicit `:async` + `respond` (E). Ready for SDD execution.
