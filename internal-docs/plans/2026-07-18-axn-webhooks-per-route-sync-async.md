# Per-route sync/async on one endpoint — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let one inbound endpoint under one `respond` block host a mix of async-ack routes and sync-body routes, by making sync-vs-async a per-resolved-route decision via a per-entry `async:` boolean in the dispatch map.

**Architecture:** `Router#resolve` starts surfacing a third element — a per-route `async` flag (`true`/`false`/`nil`) read off the matched dispatch-map Hash entry. `Dispatch` consumes it through a most-specific-wins precedence ladder (entry `async:` → endpoint `mode:` → `respond`⇒sync default → `:auto` adapter detection), replacing today's blanket `return false if respond_declared`. No DSL signature change and no `Endpoint` change — `async:` is data inside the `to:` map, and the existing response mapping (`handler_result.nil?` → ack, else render) already handles both branches.

**Tech Stack:** Ruby, `axn` gem, RSpec. No Rails required (this is the Rails-free `spec/` suite).

## Global Constraints

- **TDD:** failing test first, every task.
- **Works outside Rails:** guard any `Rails`/`ActiveRecord`/`ActiveJob` reference with `defined?(...)`. (No such references are needed in this plan.)
- **`# frozen_string_literal: true`** at the top of every Ruby file (all touched files already have it).
- **CHANGELOG** every user-visible change under `## [Unreleased]`.
- **`bundle exec rake`** (specs + rubocop) must pass before done.
- **Extend, don't reverse Decision D:** the two named regression tests must stay green **unmodified** — `spec/axn/webhooks/dispatch_async_spec.rb` "forces SYNC when respond_declared is true" and `spec/axn/webhooks/inbound/async_mode_spec.rb` "a custom respond (mode: :auto) runs sync so respond can read the result".

---

### Task 1: `Router#resolve` surfaces a per-route `async` flag

Make `Router#resolve` return a 3-element `[handler_class, args, route_async]` tuple, reading an optional boolean `async:` off a Hash dispatch entry. `route_async` is `nil` (no opinion) for String entries, convention-derived handlers, and Hash entries that omit `async:`. A non-boolean `async:` raises loudly.

**Files:**
- Modify: `lib/axn/webhooks/inbound/router.rb`
- Test: `spec/axn/webhooks/inbound/router_spec.rb`

**Interfaces:**
- Consumes: nothing new.
- Produces: `Router#resolve(event) → [handler_class, args, route_async]` where `route_async ∈ {true, false, nil}`, **or** `:ack` (unchanged). Task 2 (`Dispatch`) relies on this exact shape and on `route_async == nil` meaning "no per-route opinion".

- [ ] **Step 1: Update the three existing full-array assertions to the new 3-tuple shape**

In `spec/axn/webhooks/inbound/router_spec.rb`, three examples assert the whole return array and must gain a trailing `nil` (no `async:` set → no opinion). Change each:

```ruby
  it "resolves a single string handler with the whole event" do
    router = described_class.new(to: "HandleWebhook")
    expect(router.resolve({ "any" => 1 })).to eq([HandleWebhook, { event: { "any" => 1 } }, nil])
  end

  it "resolves a keyed handler from an explicit map" do
    router = described_class.new(
      on: ->(e) { e["eventType"] },
      to: { "connection.updated" => "Actions::Codat::ConnectionUpdated" },
    )
    expect(router.resolve({ "eventType" => "connection.updated" }))
      .to eq([Actions::Codat::ConnectionUpdated, { event: { "eventType" => "connection.updated" } }, nil])
  end

  it "extracts scalar handler args via a with: proc" do
    router = described_class.new(
      on: ->(e) { e["event"] },
      to: { "reconciled" => { call: "PaymentOrders::DispatchCompleted",
                              with: ->(e) { { payment_order_id: e.dig("data", "id") } } } },
    )
    event = { "event" => "reconciled", "data" => { "id" => 42 } }
    expect(router.resolve(event)).to eq([PaymentOrders::DispatchCompleted, { payment_order_id: 42 }, nil])
  end
```

(The `.first`-based examples on lines 37, 47 and the `:ack`/raise examples are unaffected — leave them.)

- [ ] **Step 2: Add the new failing examples for the `async` flag**

Append to `spec/axn/webhooks/inbound/router_spec.rb` (inside the top-level `describe`):

```ruby
  it "surfaces async: true from a map entry as the third tuple element" do
    router = described_class.new(
      on: ->(e) { e["type"] },
      to: { "block_actions" => { call: "HandleWebhook", async: true } },
    )
    expect(router.resolve({ "type" => "block_actions" }))
      .to eq([HandleWebhook, { event: { "type" => "block_actions" } }, true])
  end

  it "surfaces async: false from a map entry as the third tuple element" do
    router = described_class.new(
      on: ->(e) { e["type"] },
      to: { "view_submission" => { call: "HandleWebhook", async: false } },
    )
    expect(router.resolve({ "type" => "view_submission" }))
      .to eq([HandleWebhook, { event: { "type" => "view_submission" } }, false])
  end

  it "combines async: with a with: extractor on the same entry" do
    router = described_class.new(
      on: ->(e) { e["event"] },
      to: { "reconciled" => { call: "PaymentOrders::DispatchCompleted",
                              with: ->(e) { { payment_order_id: e.dig("data", "id") } },
                              async: true } },
    )
    event = { "event" => "reconciled", "data" => { "id" => 42 } }
    expect(router.resolve(event)).to eq([PaymentOrders::DispatchCompleted, { payment_order_id: 42 }, true])
  end

  it "raises for a non-boolean async: on an entry (loud)" do
    router = described_class.new(
      on: ->(e) { e["type"] },
      to: { "block_actions" => { call: "HandleWebhook", async: :yes } },
    )
    expect { router.resolve({ "type" => "block_actions" }) }
      .to raise_error(Axn::Webhooks::Error, /async:/)
  end
```

- [ ] **Step 3: Run the specs to verify they fail**

Run: `bundle exec rspec spec/axn/webhooks/inbound/router_spec.rb`
Expected: FAIL — the 3-tuple assertions and the new async examples fail (current `resolve` returns 2-element arrays; `:yes` does not raise).

- [ ] **Step 4: Implement the 3-tuple return + `async:` extraction in `Router`**

In `lib/axn/webhooks/inbound/router.rb`, replace `resolve_by_convention` and `handler_for` and add a private `route_async` helper:

```ruby
        def resolve_by_convention(key, event)
          transform = @via || method(:default_transform)
          [constantize("#{@to}::#{transform.call(key)}"), { event: }, nil]
        end

        def handler_for(entry, event)
          case entry
          when String then [constantize(entry), { event: }, nil]
          when Hash
            args = entry.key?(:with) ? entry.fetch(:with).call(event) : { event: }
            [constantize(entry.fetch(:call)), args, route_async(entry)]
          else
            raise Axn::Webhooks::Error, "invalid dispatch target: #{entry.inspect}"
          end
        end

        # Optional per-route sync/async opt-out from a map entry: true=async, false=sync,
        # absent=nil (no opinion — Dispatch falls through to endpoint mode / respond default).
        def route_async(entry)
          return nil unless entry.key?(:async)

          value = entry.fetch(:async)
          return value if [true, false].include?(value)

          raise Axn::Webhooks::Error, "dispatch entry `async:` must be true or false (got #{value.inspect})"
        end
```

(`resolve`, `resolve_mapped`, `unmatched`, `constantize`, `default_transform` are unchanged — `resolve_mapped` already returns `handler_for(...)` and `unmatched` still returns `:ack`/raises.)

- [ ] **Step 5: Run the specs to verify they pass**

Run: `bundle exec rspec spec/axn/webhooks/inbound/router_spec.rb`
Expected: PASS (all examples).

- [ ] **Step 6: Commit**

```bash
git add lib/axn/webhooks/inbound/router.rb spec/axn/webhooks/inbound/router_spec.rb
git commit -m "feat: Router#resolve surfaces per-route async flag (PRO-2952)"
```

---

### Task 2: `Dispatch` per-route precedence ladder

Replace the blanket `return false if respond_declared` override with a most-specific-wins ladder that honors the per-route flag from Task 1. Reuse the existing no-adapter guard so `async: true` on an adapter-less handler still settles as a clean reported exception.

**Files:**
- Modify: `lib/axn/webhooks/dispatch.rb`
- Test: `spec/axn/webhooks/dispatch_async_spec.rb`

**Interfaces:**
- Consumes: `Router#resolve → [handler_class, args, route_async]` (Task 1).
- Produces: no new public interface; behavior — a resolved route's mode is decided by: (1) entry `route_async` if non-nil, else (2) endpoint `mode` if `:sync`/`:async`, else (3) sync when `respond_declared`, else (4) `:auto` adapter detection.

- [ ] **Step 1: Add failing examples for per-route precedence**

Append to `spec/axn/webhooks/dispatch_async_spec.rb` a new `describe` block (the `before` hook already defines `AsyncHandler`, `SyncHandler`, `AdapterHandler`):

```ruby
  describe "per-route async: flag (PRO-2952)" do
    it "an entry with async: true enqueues even when respond_declared forces the endpoint sync" do
      router = Axn::Webhooks::Inbound::Router.new(
        on: ->(e) { e["type"] },
        to: { "block_actions" => { call: "AsyncHandler", async: true } },
      )
      result = Axn::Webhooks::Dispatch.call(
        request: request('{"type":"block_actions"}'), router:, parse: json_parse, respond_declared: true
      )
      expect(result).to be_ok
      expect(result.handler_result).to be_nil
      expect(AsyncHandler.calls).to eq([{ event: { "type" => "block_actions" } }])
    end

    it "an entry with async: false runs sync even when endpoint mode: :async" do
      router = Axn::Webhooks::Inbound::Router.new(
        on: ->(e) { e["type"] },
        to: { "view_submission" => { call: "AdapterHandler", async: false } },
      )
      result = Axn::Webhooks::Dispatch.call(
        request: request('{"type":"view_submission"}'), router:, parse: json_parse, mode: :async
      )
      expect(result.handler_result).to be_ok
      expect(AdapterHandler).not_to have_received(:call_async)
    end

    it "an entry with no async: still honors the respond_declared sync default" do
      router = Axn::Webhooks::Inbound::Router.new(
        on: ->(e) { e["type"] },
        to: { "view_submission" => { call: "AdapterHandler" } },
      )
      result = Axn::Webhooks::Dispatch.call(
        request: request('{"type":"view_submission"}'), router:, parse: json_parse, respond_declared: true
      )
      expect(result.handler_result).to be_ok
      expect(AdapterHandler).not_to have_received(:call_async)
    end

    it "async: true on an adapter-less Axn handler settles as a reported exception" do
      router = Axn::Webhooks::Inbound::Router.new(
        on: ->(e) { e["type"] },
        to: { "block_actions" => { call: "SyncHandler", async: true } },
      )
      result = Axn::Webhooks::Dispatch.call(
        request: request('{"type":"block_actions"}'), router:, parse: json_parse, respond_declared: true
      )
      expect(result.outcome).to be_exception
      expect(result.exception).to be_a(Axn::Webhooks::Error)
    end
  end
```

- [ ] **Step 2: Run the specs to verify they fail**

Run: `bundle exec rspec spec/axn/webhooks/dispatch_async_spec.rb -e "per-route async"`
Expected: FAIL — the first example enqueues nothing (respond_declared currently forces sync and swallows the route flag); the destructure drops the third element.

- [ ] **Step 3: Implement the ladder in `Dispatch`**

In `lib/axn/webhooks/dispatch.rb`, unpack the third element and replace `async?`:

```ruby
      def call
        event = parse.call(request)
        resolution = router.resolve(event)
        return done!("acknowledged") if resolution == :ack

        handler_class, args, route_async = resolution
        return dispatch_async(handler_class, args) if async?(handler_class, route_async)

        expose handler_result: handler_class.call!(**args)
      end

      private

      # Resolve sync vs async per resolved route (Decision D extended, PRO-2952),
      # most-specific wins: (1) the route's own async: flag; (2) an explicit endpoint
      # mode:; (3) a declared respond forces sync (Decision D default); (4) :auto —
      # async when an adapter is configured for THIS handler, else sync.
      def async?(handler_class, route_async)
        return route_async unless route_async.nil?
        return true if mode == :async
        return false if mode == :sync
        return false if respond_declared

        async_adapter_configured?(handler_class)
      end
```

(`async_adapter_configured?` and `dispatch_async` are unchanged — the no-adapter guard inside `dispatch_async` still fires for `async: true` on an adapter-less Axn handler.)

- [ ] **Step 4: Run the specs to verify they pass**

Run: `bundle exec rspec spec/axn/webhooks/dispatch_async_spec.rb`
Expected: PASS (new examples + all prior ones, including "forces SYNC when respond_declared is true").

- [ ] **Step 5: Commit**

```bash
git add lib/axn/webhooks/dispatch.rb spec/axn/webhooks/dispatch_async_spec.rb
git commit -m "feat: Dispatch per-route async precedence ladder (PRO-2952)"
```

---

### Task 3: Integration — a mixed endpoint under one `respond`

Prove the end-to-end pattern through the public `Inbound[:vendor].to_response`: one endpoint, one `respond` block, one async-ack route and one sync-body route, selected per message.

**Files:**
- Create: `spec/axn/webhooks/inbound/per_route_async_spec.rb`

**Interfaces:**
- Consumes: `Axn::Webhooks.inbound`, `Axn::Webhooks::Inbound[:vendor]`, `Endpoint#to_response`, `Request.new(raw_body:)` — all existing. Relies on Task 1 + Task 2 behavior.
- Produces: nothing (leaf integration spec).

- [ ] **Step 1: Write the failing integration spec**

Create `spec/axn/webhooks/inbound/per_route_async_spec.rb`:

```ruby
# frozen_string_literal: true

RSpec.describe "Axn::Webhooks::Inbound mixed per-route sync/async endpoint (PRO-2952)" do
  after { Axn::Webhooks::Inbound.reset! }

  before do
    # Async-ack route: non-Axn stub recording call_async (no adapter machinery needed).
    stub_const("BlockActionsHandler", Class.new do
      def self.calls = (@calls ||= [])
      def self.call_async(**kwargs) = calls << kwargs
    end)

    # Sync-body route: a real Axn handler returning a value the respond block renders.
    stub_const("ViewSubmissionHandler", Class.new do
      include Axn

      expects :event, allow_blank: true
      exposes :body
      def call = expose(body: "clear")
    end)

    Axn::Webhooks.inbound(:slack) do
      verify { |_req| true }
      dispatch on: ->(e) { e["type"] },
               to: {
                 "block_actions"   => { call: "BlockActionsHandler", async: true },
                 "view_submission" => "ViewSubmissionHandler",
               }
      respond { |result| text(result.body) }
    end
  end

  def post(body) = Axn::Webhooks::Inbound[:slack].to_response(Axn::Webhooks::Request.new(raw_body: body))

  it "acks the async route with a bare 2xx and enqueues it" do
    response = post('{"type":"block_actions"}')
    expect(response.status).to eq(200)
    expect(response.body).to eq("")
    expect(BlockActionsHandler.calls).to eq([{ event: { "type" => "block_actions" } }])
  end

  it "runs the sync route inline and renders its respond body" do
    response = post('{"type":"view_submission"}')
    expect(response.status).to eq(200)
    expect(response.body).to eq("clear")
    expect(BlockActionsHandler.calls).to eq([]) # sync route did not enqueue
  end
end
```

- [ ] **Step 2: Run the spec to verify it passes (Tasks 1–2 already implement the behavior)**

Run: `bundle exec rspec spec/axn/webhooks/inbound/per_route_async_spec.rb`
Expected: PASS — both examples. (If the async example instead renders a body or the sync example enqueues, revisit the Task 2 ladder.)

- [ ] **Step 3: Commit**

```bash
git add spec/axn/webhooks/inbound/per_route_async_spec.rb
git commit -m "test: mixed per-route sync/async endpoint integration (PRO-2952)"
```

---

### Task 4: CHANGELOG + full green gate

Document the user-visible change and confirm the whole suite (specs + rubocop) is green, including the unmodified Decision-D regression tests.

**Files:**
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing.

- [ ] **Step 1: Add the CHANGELOG entry**

In `CHANGELOG.md`, under `## [Unreleased]` → `### Added`, add as the first bullet:

```markdown
- Per-route sync/async on one endpoint (interaction-platform pattern) — a dispatch-map Hash entry
  accepts an optional `async:` boolean (`{ call: "Handler", async: true }`), so one endpoint under
  one `respond` block can multiplex async-ack routes and sync-body routes (Slack `view_submission`
  vs `block_actions`, Discord, Telegram). Precedence, most-specific first: the entry's `async:`, then
  an explicit endpoint `mode:`, then a declared `respond` (sync — Decision D preserved), then `:auto`
  adapter detection. A non-boolean `async:` raises at resolve time; `async: true` on an adapter-less
  handler settles as a reported exception (unchanged guard).
```

- [ ] **Step 2: Confirm the named Decision-D regression tests are green and unmodified**

Run: `git diff --stat HEAD~3 -- spec/axn/webhooks/inbound/async_mode_spec.rb`
Expected: no output (file untouched by this work).

Run: `bundle exec rspec spec/axn/webhooks/inbound/async_mode_spec.rb spec/axn/webhooks/dispatch_async_spec.rb`
Expected: PASS — including "forces SYNC when respond_declared is true" and "a custom respond (mode: :auto) runs sync so respond can read the result".

- [ ] **Step 3: Run the full gate**

Run: `bundle exec rake`
Expected: all specs pass and rubocop reports no offenses.

- [ ] **Step 4: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs: CHANGELOG for per-route sync/async (PRO-2952)"
```

---

## Self-Review

**Spec coverage** (against `internal-docs/specs/2026-07-18-axn-webhooks-per-route-sync-async-design.md`):
- Decision A (respond⇒sync default, per-route opt-out) → Task 2 ladder step 3 + Task 3 integration.
- Decision B (`async:` boolean, endpoint `mode:` stays trilean) → Task 1 (`route_async` boolean) + Task 2 (endpoint `mode:` untouched in the ladder).
- API (`async:` on Hash entries only; String / single / convention carry no opinion) → Task 1 Steps 2 & 4.
- Precedence ladder (4 steps) → Task 2 Step 3 + tests in Task 2 Step 1.
- `Router` 3-tuple + validation → Task 1.
- `Dispatch` unpack + ladder + reused guard → Task 2.
- `Endpoint#initialize` guard unchanged / no DSL change → no task needed (explicitly out of scope; nothing modifies them).
- `Endpoint#response_for` unchanged → exercised, not modified, by Task 3.
- Testing items 1–6 → Task 1 (items 3, 5), Task 2 (items 2, 4), Task 3 (item 1), Task 4 (item 6).

**Placeholder scan:** none — every code step shows complete code; every run step shows the command and expected result.

**Type consistency:** `resolve → [handler_class, args, route_async]` (Task 1) is consumed verbatim as `handler_class, args, route_async = resolution` and `async?(handler_class, route_async)` (Task 2). `route_async ∈ {true, false, nil}` is consistent across both. `route_async` helper name (`route_async`) is distinct from the flag variable and used only inside `Router`.
