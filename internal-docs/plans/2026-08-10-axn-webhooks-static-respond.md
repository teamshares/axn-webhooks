# axn-webhooks static_respond Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `static_respond { ... }` to `Axn::Webhooks::Inbound::DSL` — a webhook response body that never reads the handler's result, so it renders on every non-error dispatch outcome (sync success, async enqueue, `otherwise: :ack`, business `fail!`) without forcing sync dispatch or raising alongside `mode: :async`, unlike the existing `respond`.

**Architecture:** A new pipeline-stage Axn (`Axn::Webhooks::StaticRespond`), parallel to the existing `Respond` axn but with no `handler_result` input. `Inbound::Endpoint` threads a new `static_respond:` constructor argument through and routes every branch that currently hardcodes a bare `Response.ack` through a new private `default_ack` method, which renders `static_respond`'s body when declared. `respond` and `static_respond` are mutually exclusive, enforced by a registration-time raise.

**Tech Stack:** Ruby, `axn` gem's `Axn`/`expects`/`exposes`/`fail!` contract, RSpec, Rubocop.

## Global Constraints

- Source spec: `internal-docs/specs/2026-08-10-axn-webhooks-static-respond-design.md` — read it before starting if any task below is ambiguous.
- TDD: write the failing test before the implementation, for every step below.
- No `Rails`/`ActiveRecord`/`ActiveJob` references — this feature touches none, so no `defined?(...)` guards are needed, but don't introduce any.
- Run `bundle exec rake` (specs + rubocop) before considering any task done.
- Add a CHANGELOG entry under `## [Unreleased]` (Task 5) — this is a user-visible change per `AGENTS.md`.
- Do not modify the existing `respond`/`Respond` axn behavior, its forced-sync default, or its `mode: :async` registration-time raise.

---

### Task 1: DSL surface — `static_respond`

**Files:**
- Modify: `lib/axn/webhooks/inbound/dsl.rb`
- Test: `spec/axn/webhooks/inbound/dsl_static_respond_spec.rb` (new)

**Interfaces:**
- Produces: `Inbound::DSL#static_respond(&block)` (captures the block), `Inbound::DSL#__static_respond__` (returns the captured block or `nil`) — consumed by Task 2's `Axn::Webhooks.inbound` wiring.

- [ ] **Step 1: Write the failing test**

Create `spec/axn/webhooks/inbound/dsl_static_respond_spec.rb`:

```ruby
# frozen_string_literal: true

RSpec.describe Axn::Webhooks::Inbound::DSL do
  describe "#static_respond" do
    it "defaults __static_respond__ to nil when undeclared" do
      expect(described_class.new.__static_respond__).to be_nil
    end

    it "captures the declared block" do
      dsl = described_class.new
      block = -> { text("Hello API Event Received") }
      dsl.static_respond(&block)
      expect(dsl.__static_respond__).to eq(block)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/webhooks/inbound/dsl_static_respond_spec.rb`
Expected: FAIL — `NoMethodError: undefined method 'static_respond'` (or `'__static_respond__'`).

- [ ] **Step 3: Write minimal implementation**

In `lib/axn/webhooks/inbound/dsl.rb`, add a `static_respond` method right after the existing `respond` method (after line 27, before the `challenge` method's leading comment at line 29):

```ruby
        # static_respond { text("...") } — a body that does NOT read the handler result (block
        # takes zero args, unlike respond's `|handler_result|`), so it renders on every non-error
        # outcome: sync success, async enqueue, otherwise: :ack, and business fail! — see
        # Endpoint#default_ack. Mutually exclusive with `respond` (Endpoint#initialize raises if
        # both are declared) and never forces sync dispatch (Dispatch#async? never reads it).
        def static_respond(&block)
          @static_respond_block = block
        end
```

And add `__static_respond__` right after the existing `__respond__` (line 92):

```ruby
        # Internal: the captured static_respond block, or nil if none declared.
        def __static_respond__ = @static_respond_block
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/axn/webhooks/inbound/dsl_static_respond_spec.rb`
Expected: PASS (2 examples, 0 failures).

- [ ] **Step 5: Commit**

```bash
git add lib/axn/webhooks/inbound/dsl.rb spec/axn/webhooks/inbound/dsl_static_respond_spec.rb
git commit -m "feat: add static_respond DSL method to Inbound::DSL"
```

---

### Task 2: Wire `static_respond` through `Endpoint`/`inbound`, mutual-exclusion guard

**Files:**
- Modify: `lib/axn/webhooks/inbound/endpoint.rb`
- Modify: `lib/axn/webhooks/inbound.rb`
- Test: `spec/axn/webhooks/inbound/static_respond_spec.rb` (new)

**Interfaces:**
- Consumes: `Inbound::DSL#__static_respond__` (Task 1).
- Produces: `Inbound::Endpoint.new(..., static_respond: proc_or_nil)` accepts and stores `@static_respond`; raises `Axn::Webhooks::Error` at construction if both `respond:` and `static_respond:` are truthy. `@static_respond` is not yet consumed by response rendering — that's Task 3.

- [ ] **Step 1: Write the failing test**

Create `spec/axn/webhooks/inbound/static_respond_spec.rb`:

```ruby
# frozen_string_literal: true

RSpec.describe "Axn::Webhooks::Inbound static_respond" do
  after { Axn::Webhooks::Inbound.reset! }

  describe "registration" do
    it "rejects declaring both respond and static_respond at declaration time" do
      expect do
        Axn::Webhooks.inbound(:bad) do
          verify { |_req| true }
          dispatch to: "Handlers::Created"
          respond { |result| text(result.to_s) }
          static_respond { text("Hello API Event Received") }
        end
      end.to raise_error(Axn::Webhooks::Error, /declares both `respond` and `static_respond`/)
    end

    it "allows static_respond alone" do
      expect do
        Axn::Webhooks.inbound(:ok) do
          verify { |_req| true }
          dispatch to: "Handlers::Created"
          static_respond { text("Hello API Event Received") }
        end
      end.not_to raise_error
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/webhooks/inbound/static_respond_spec.rb`
Expected: FAIL — `ArgumentError: unknown keyword: :static_respond` (the DSL method exists from Task 1, but `Axn::Webhooks.inbound` doesn't pass it through yet, so `respond` is what raises unexpectedly, or the block-DSL call itself errors depending on where it breaks; either way, not the expected `Axn::Webhooks::Error` message).

- [ ] **Step 3: Write minimal implementation**

In `lib/axn/webhooks/inbound/endpoint.rb`, change the constructor (lines 10–22):

```ruby
        def initialize(name:, verifier:, dispatch: nil, respond: nil, static_respond: nil, challenge: nil)
          if dispatch && dispatch[:mode] == :async && respond
            raise Axn::Webhooks::Error,
                  "inbound endpoint `#{name}` declares a custom `respond` but explicit `dispatch mode: :async` " \
                  "can't produce a handler_result for it to read — use `mode: :sync` (or omit mode) or drop the respond block"
          end

          if respond && static_respond
            raise Axn::Webhooks::Error,
                  "inbound endpoint `#{name}` declares both `respond` and `static_respond` — declare only one; " \
                  "`respond` reads the handler's result, `static_respond` doesn't and renders on every non-error outcome"
          end

          @name = name.to_sym
          @verifier = verifier
          @dispatch = dispatch
          @respond = respond
          @static_respond = static_respond
          @challenge = challenge
        end
```

In `lib/axn/webhooks/inbound.rb`, add `static_respond:` to the `Inbound::Endpoint.new` call (lines 29–38):

```ruby
      Inbound.register(
        name,
        Inbound::Endpoint.new(
          name:,
          verifier: dsl.__verifier__,
          dispatch: dsl.__dispatch__,
          respond: dsl.__respond__,
          static_respond: dsl.__static_respond__,
          challenge: dsl.__challenge__,
        ),
      )
```

Also add the `Handlers::Created` stub the test references — since `static_respond_spec.rb` is a new file, it needs its own `before` block. Add this at the top of the `RSpec.describe` block, before `describe "registration"`:

```ruby
  before do
    stub_const("Handlers", Module.new) unless defined?(Handlers)
    stub_const("Handlers::Created", Class.new do
      include Axn

      expects :event, allow_blank: true
      def call = nil
    end)
  end
```

(Task 3 will reuse and extend this `before` block with more handler stubs, so define it once now.)

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/axn/webhooks/inbound/static_respond_spec.rb`
Expected: PASS (2 examples, 0 failures).

- [ ] **Step 5: Run the full existing suite to check for regressions**

Run: `bundle exec rspec`
Expected: PASS, same count as before this task plus 2 (no existing spec passes `static_respond:` so none should be affected by the new keyword argument, which defaults to `nil`).

- [ ] **Step 6: Commit**

```bash
git add lib/axn/webhooks/inbound/endpoint.rb lib/axn/webhooks/inbound.rb spec/axn/webhooks/inbound/static_respond_spec.rb
git commit -m "feat: wire static_respond through Endpoint, guard against combining with respond"
```

---

### Task 3: `StaticRespond` axn + `Endpoint#default_ack` — the rendering behavior

**Files:**
- Create: `lib/axn/webhooks/static_respond.rb`
- Modify: `lib/axn/webhooks.rb` (require the new file)
- Modify: `lib/axn/webhooks/inbound/endpoint.rb`
- Test: `spec/axn/webhooks/inbound/static_respond_spec.rb` (extend)

**Interfaces:**
- Consumes: `Inbound::RespondContext` (existing, `lib/axn/webhooks/inbound/respond_context.rb`) for `ack`/`text`/`xml`/`json` bare calls; `Axn::Webhooks::VendorFacet` (existing).
- Produces: `Axn::Webhooks::StaticRespond.call(responder:, vendor:)` → `Axn::Result` exposing `:response` (an `Axn::Webhooks::Response`) on success. `Endpoint#default_ack` (private) — returns `Response.ack` when no `static_respond` declared, else the rendered `Response` or a 500 on error.

- [ ] **Step 1: Write the failing tests**

Extend `spec/axn/webhooks/inbound/static_respond_spec.rb` — add handler/adapter stubs to the shared `before` block and a `describe "rendering"` block. Replace the existing `before` block with this (adds `FailsQuietly`, `Boom`, and a non-Axn async-adapter stub) and append the new `describe`:

```ruby
  before do
    stub_const("Handlers", Module.new)
    stub_const("Handlers::Created", Class.new do
      include Axn

      expects :event, allow_blank: true
      def call = nil
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
    stub_const("AsyncHandler", Class.new do
      def self.calls = (@calls ||= [])
      def self.call_async(**kwargs) = calls << kwargs
    end)
  end

  def req(body) = Axn::Webhooks::Request.new(raw_body: body)

  describe "registration" do
    # ... (unchanged from Task 2)
  end

  describe "rendering" do
    it "renders the static body on a genuine sync handler success" do
      Axn::Webhooks.inbound(:vendor) do
        verify { |_req| true }
        dispatch to: "Handlers::Created" # mode: :auto, no adapter configured -> sync
        static_respond { text("Hello API Event Received") }
      end
      response = Axn::Webhooks::Inbound[:vendor].to_response(req("{}"))
      expect(response.status).to eq(200)
      expect(response.body).to eq("Hello API Event Received")
    end

    it "renders the static body on an unmatched event (otherwise: :ack)" do
      Axn::Webhooks.inbound(:vendor) do
        verify { |_req| true }
        dispatch on: ->(e) { e["t"] }, to: { "known" => "Handlers::Created" }, otherwise: :ack
        static_respond { text("Hello API Event Received") }
      end
      response = Axn::Webhooks::Inbound[:vendor].to_response(req('{"t":"surprise"}'))
      expect(response.status).to eq(200)
      expect(response.body).to eq("Hello API Event Received")
    end

    it "renders the static body on a handler business fail!" do
      Axn::Webhooks.inbound(:vendor) do
        verify { |_req| true }
        dispatch to: "Handlers::FailsQuietly"
        static_respond { text("Hello API Event Received") }
      end
      response = Axn::Webhooks::Inbound[:vendor].to_response(req("{}"))
      expect(response.status).to eq(200)
      expect(response.body).to eq("Hello API Event Received")
    end

    it "renders the static body for a verify-only endpoint (no dispatch declared)" do
      Axn::Webhooks.inbound(:vendor) do
        verify { |_req| true }
        static_respond { text("Hello API Event Received") }
      end
      response = Axn::Webhooks::Inbound[:vendor].to_response(req(""))
      expect(response.status).to eq(200)
      expect(response.body).to eq("Hello API Event Received")
    end

    it "renders the static body when mode: :async enqueues successfully" do
      Axn::Webhooks.inbound(:vendor) do
        verify { |_req| true }
        dispatch to: "AsyncHandler", mode: :async
        static_respond { text("Hello API Event Received") }
      end
      response = Axn::Webhooks::Inbound[:vendor].to_response(req("{}"))
      expect(response.status).to eq(200)
      expect(response.body).to eq("Hello API Event Received")
      expect(AsyncHandler.calls).to eq([{ event: {} }])
    end

    it "renders the static body on a per-route async(...) entry" do
      Axn::Webhooks.inbound(:vendor) do
        verify { |_req| true }
        dispatch on: ->(e) { e["t"] }, to: { "a" => async("AsyncHandler") }
        static_respond { text("Hello API Event Received") }
      end
      response = Axn::Webhooks::Inbound[:vendor].to_response(req('{"t":"a"}'))
      expect(response.status).to eq(200)
      expect(response.body).to eq("Hello API Event Received")
      expect(AsyncHandler.calls).to eq([{ event: { "t" => "a" } }])
    end

    it "does not force sync dispatch, unlike respond" do
      Handlers::Created._async_adapter = :sidekiq
      allow(Handlers::Created).to receive(:call_async)
      Axn::Webhooks.inbound(:vendor) do
        verify { |_req| true }
        dispatch to: "Handlers::Created" # mode: :auto + adapter configured -> would be async
        static_respond { text("Hello API Event Received") }
      end
      response = Axn::Webhooks::Inbound[:vendor].to_response(req("{}"))
      expect(response.body).to eq("Hello API Event Received")
      expect(Handlers::Created).to have_received(:call_async)
    ensure
      Handlers::Created._async_adapter = nil
    end

    it "does not raise when combined with explicit mode: :async" do
      expect do
        Axn::Webhooks.inbound(:vendor) do
          verify { |_req| true }
          dispatch to: "AsyncHandler", mode: :async
          static_respond { text("Hello API Event Received") }
        end
      end.not_to raise_error
    end

    it "maps a raise inside the static_respond block to a reported 500" do
      Axn::Webhooks.inbound(:vendor) do
        verify { |_req| true }
        dispatch to: "Handlers::Created"
        static_respond { text(no_such_helper) }
      end
      response = nil
      expect { response = Axn::Webhooks::Inbound[:vendor].to_response(req("{}")) }.not_to raise_error
      expect(response.status).to eq(500)
    end

    it "maps a static_respond block that returns a non-Response to a 500" do
      Axn::Webhooks.inbound(:vendor) do
        verify { |_req| true }
        dispatch to: "Handlers::Created"
        static_respond { "a raw string, not a Response" }
      end
      response = nil
      expect { response = Axn::Webhooks::Inbound[:vendor].to_response(req("{}")) }.not_to raise_error
      expect(response).to be_a(Axn::Webhooks::Response)
      expect(response.status).to eq(500)
    end
  end
```

Note: `Handlers::Created#call` above returns `nil` and exposes nothing — that's deliberate. Since `Handlers::Created` has no `exposes`, `handler_result` will be a successful `Axn::Result` with no exposures, matching the "genuine sync success, nothing for `respond` to read" DropboxSign shape. Don't add `include Axn::Testing::SpecHelpers`-style adapter stubbing beyond `_async_adapter =` — that setter already exists on any `include Axn` class (see `async_mode_spec.rb`'s `TwimlHandler._async_adapter = :sidekiq`).

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/axn/webhooks/inbound/static_respond_spec.rb`
Expected: FAIL on every example in the `"rendering"` group — bodies come back empty (`""`) because `default_ack` doesn't exist yet and `@static_respond` is never consulted.

- [ ] **Step 3: Write minimal implementation**

Create `lib/axn/webhooks/static_respond.rb`:

```ruby
# frozen_string_literal: true

module Axn
  module Webhooks
    # The static_respond stage as an Axn: runs the endpoint's static_respond block — which reads
    # no handler result, unlike Respond — to build a Response. Built as an Axn so a raise inside
    # the (user-supplied) block is reported once via on_exception and mapped to a 500 by
    # Endpoint#default_ack, never an unhandled exception escaping the HTTP mapper.
    class StaticRespond
      include Axn
      include Axn::Webhooks::VendorFacet

      expects :responder
      exposes :response, type: Axn::Webhooks::Response
      error "Webhook static_respond failed"

      def call
        expose response: Inbound::RespondContext.new.instance_exec(&responder)
      end
    end
  end
end
```

In `lib/axn/webhooks.rb`, add the require right after the existing `require_relative "webhooks/respond"` (line 23):

```ruby
require_relative "webhooks/respond"
require_relative "webhooks/static_respond"
require_relative "webhooks/dispatch"
```

In `lib/axn/webhooks/inbound/endpoint.rb`, update `to_response` (was lines 46–54) to route the no-dispatch branch through `default_ack`:

```ruby
        def to_response(request)
          verified = verify(request)
          return Response.new(status: 401) unless verified.ok?
          return default_ack unless @dispatch

          dispatched = Dispatch.call(request:, router: @dispatch[:router], parse: @dispatch[:parse],
                                     mode: @dispatch[:mode], respond_declared: !@respond.nil?, vendor: @name)
          response_for(dispatched)
        end
```

Update `response_for` (was lines 87–98):

```ruby
        def response_for(dispatched)
          return Response.service_unavailable(retry_after: dispatched.retry_after) if dispatched.retry_later
          return Response.new(status: 500) if dispatched.outcome.exception?
          return default_ack if dispatched.outcome.failure?    # handler fail! -> quiet ack (or static body)
          return default_ack if dispatched.handler_result.nil? # otherwise: :ack / async enqueue -> ack (or static body)
          return default_ack unless @respond

          # Run the user's respond block inside the Respond axn so a raise in it (e.g. reading a
          # missing exposure) becomes a reported 500, not an exception escaping the HTTP mapper.
          responded = Respond.call(handler_result: dispatched.handler_result, responder: @respond, vendor: @name)
          responded.ok? ? responded.response : Response.new(status: 500)
        end

        # The bare-ack default, or the declared static_respond body in its place. Every branch
        # above that used to hardcode `Response.ack` (dispatch.failure?, nil handler_result, no
        # respond declared, no dispatch at all) now goes through here — static_respond, unlike
        # respond, has no handler_result to read, so it renders on all of them uniformly.
        def default_ack
          return Response.ack unless @static_respond

          responded = StaticRespond.call(responder: @static_respond, vendor: @name)
          responded.ok? ? responded.response : Response.new(status: 500)
        end
```

`default_ack` goes in the existing `private` section, alongside `response_for`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/axn/webhooks/inbound/static_respond_spec.rb`
Expected: PASS (all examples in both `"registration"` and `"rendering"` groups).

- [ ] **Step 5: Run the full suite to check for regressions**

Run: `bundle exec rspec`
Expected: PASS — in particular, `spec/axn/webhooks/inbound/respond_spec.rb` and `spec/axn/webhooks/inbound/async_mode_spec.rb` stay green unmodified (proof this is additive to `respond`'s contract, not a change to it).

- [ ] **Step 6: Run rubocop**

Run: `bundle exec rubocop lib/axn/webhooks/static_respond.rb lib/axn/webhooks/inbound/endpoint.rb lib/axn/webhooks.rb spec/axn/webhooks/inbound/static_respond_spec.rb`
Expected: no offenses. Fix any and re-run before continuing.

- [ ] **Step 7: Commit**

```bash
git add lib/axn/webhooks/static_respond.rb lib/axn/webhooks.rb lib/axn/webhooks/inbound/endpoint.rb spec/axn/webhooks/inbound/static_respond_spec.rb
git commit -m "feat: render static_respond's body on every non-error dispatch outcome"
```

---

### Task 4: README documentation

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: none (docs only).
- Produces: none (docs only).

- [ ] **Step 1: Fix the DropboxSign example** (no test — doc-only change; verify by reading, per Step 4 below)

In the "Respond with a custom body" section, the DropboxSign example currently reads (around line 110-115):

```ruby
# DropboxSign requires this exact literal string:
Axn::Webhooks.inbound :dropbox_sign do
  verify { |req| … }
  dispatch to: "Actions::DropboxSign::HandleWebhook"
  respond { |_result| text("Hello API Event Received") }
end
```

Replace the `respond` line with `static_respond`, and drop the now-unused `|_result|` param (the whole point is that it isn't read):

```ruby
# DropboxSign requires this exact literal string, and DropboxSign's handler must run async
# (it makes outbound API calls) — static_respond renders regardless of dispatch outcome:
Axn::Webhooks.inbound :dropbox_sign do
  verify { |req| … }
  dispatch to: "Actions::DropboxSign::HandleWebhook"
  static_respond { text("Hello API Event Received") }
end
```

- [ ] **Step 2: Add a `static_respond` subsection**

Immediately after the existing "Respond with a custom body" section's closing example (after the `respond` section's explanatory paragraph, before "### The staged HTTP outcome mapping"), add:

```markdown
For a body that must render regardless of how dispatch resolves — including async enqueue,
`otherwise: :ack`, and business `fail!` — use `static_respond` instead. Unlike `respond`, its
block takes **no arguments** (it never reads the handler's result), so declaring it does not
force sync dispatch and is compatible with explicit `mode: :async`:

\`\`\`ruby
Axn::Webhooks.inbound :dropbox_sign do
  verify { |req| … }
  dispatch to: "Actions::DropboxSign::HandleWebhook"   # stays async under mode: :auto
  static_respond { text("Hello API Event Received") }
end
\`\`\`

`respond` and `static_respond` are mutually exclusive — declaring both on one endpoint raises at
registration time.
```

(Write the actual triple-backtick Ruby fence, not the escaped `\`\`\`` shown above — that's only to keep this plan step's own Markdown from closing early.)

- [ ] **Step 3: Update "The staged HTTP outcome mapping" table**

The table's last row currently reads:

```markdown
| Handle | success | the declared `respond` body, or a bare 2xx ack |
```

Change the surrounding paragraph (just above the table, "`respond` only runs for a genuine handler success...") to also mention `static_respond`, and add a note directly below the table:

```markdown
A declared `static_respond` renders on every row above except the two 401 rows and the two 500
rows — including `otherwise: :ack`, business `fail!`, and a genuine handler success with no
`respond` declared.
```

- [ ] **Step 4: Update "Async dispatch" section**

The paragraph starting "A custom `respond` block reads the handler's own result..." (around line 171) should get one more sentence appended:

```markdown
`static_respond`, by contrast, never reads a result, so it never forces sync and is compatible
with an explicit `mode: :async` — it's the right choice for a vendor like DropboxSign that needs
both a literal ack body and an async handler.
```

- [ ] **Step 5: Verify by reading**

Read the full modified README section (Respond through Async dispatch) start to finish and confirm: no leftover reference to `respond` in the DropboxSign example, the new subsection reads coherently in place, and the table/notes are internally consistent with `internal-docs/specs/2026-08-10-axn-webhooks-static-respond-design.md`.

- [ ] **Step 6: Commit**

```bash
git add README.md
git commit -m "docs: document static_respond, fix DropboxSign example"
```

---

### Task 5: CHANGELOG + final verification

**Files:**
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: none.
- Produces: none.

- [ ] **Step 1: Add a CHANGELOG entry**

In `CHANGELOG.md`, under `## [Unreleased]`, add (create an `### Added` subsection under `[Unreleased]` if one doesn't already immediately follow it — check the current file first, since a `### Fixed` and `### Added` already exist there per the last release notes):

```markdown
- `Axn::Webhooks::Inbound::DSL#static_respond` — a webhook response body that does not read the
  handler's result (its block takes no arguments, unlike `respond`), so it renders on every
  non-error dispatch outcome: sync success, async enqueue, `otherwise: :ack`, and business
  `fail!`. Unlike `respond`, declaring it never forces sync dispatch and is compatible with
  explicit `mode: :async`. Mutually exclusive with `respond` (raises at registration if both are
  declared). Fixes the README's DropboxSign example, which was wrong for any consuming app with
  an axn async adapter configured.
```

- [ ] **Step 2: Run the full verification suite**

Run: `bundle exec rake`
Expected: `spec` and `rubocop` both pass with no failures/offenses. If `rubocop` flags anything in files touched by this plan, fix it and re-run.

- [ ] **Step 3: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs: add CHANGELOG entry for static_respond"
```
