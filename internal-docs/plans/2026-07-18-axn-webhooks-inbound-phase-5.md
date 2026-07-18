# axn-webhooks Inbound — Phase 5 (Rack mount + challenge + vendor facet) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Status (2026-07-18): DESIGN DRAFT — five open decisions below (A–E) are NOT yet resolved with
> the user.** Each has a recommendation and rationale, but unlike Phases 2–4's plans, this one
> should not be executed blind — confirm the "## Open decisions (need confirmation)" section (or
> at least flag disagreement) before running the tasks, per the recommended option each is written
> against. This is the **final** phase — after it lands, `axn-webhooks` inbound is feature-complete
> per the design spec.

**Goal:** Make a registered `Axn::Webhooks::Inbound[:vendor]` endpoint directly usable as an HTTP
entry point: a Rack app (`#call(env)`) that a Rails `routes.rb` can `mount` or a bare
`Rack::Builder`/`config.ru` can `run`, owning the whole path and every verb — `POST` runs the
existing (already non-raising) `#to_response` pipeline; `GET` either echoes a declared `challenge`
or 405s. Also ships the `vendor_facet` config setting (`Axn::Configurable`), which stamps the
registered vendor name onto the verify/dispatch/respond/challenge pipeline as a Datadog/OTel
dimension or tag, per Decision 7 of the spec.

**Architecture:** `Axn::Webhooks::Request` gains `.from_rack(env)`, extracting raw body bytes from
`rack.input` (read + rewind — pristine, unparsed, exactly why the spec chose mount-first), headers
from `HTTP_*`/`CONTENT_TYPE`/`CONTENT_LENGTH`, and params from the query string (merged with
form-decoded body params when the content type is `application/x-www-form-urlencoded`, so Twilio's
`parse: ->(req){ req.params }` dispatch works over Rack too). `Endpoint#call(env)` becomes the Rack
app: it delegates request-building to a new tiny `Inbound::BuildRequest` Axn (so a malformed env
gets axn's own exception-bucket treatment — reported + a clean 500 — never an unhandled raise),
then branches on HTTP verb: `POST` → the existing `#to_response`; `GET` → a new
`Inbound::Challenge` Axn (echoes a declared `challenge` value, or 400/500 on rejection/crash) or a
bare 405 if no `challenge` was declared; anything else → 405. `Response` gains `#to_rack`, the
one-line `[status, headers, [body]]` triple Rack expects (its header keys are already lower-cased
per Rack 3's SPEC — done in Phase 4, unknowingly anticipating this phase).

Separately, `Axn::Webhooks.config.vendor_facet` (new `setting`, default `false`,
`one_of: [false, :dimension, :tag]`) is threaded through a new shared `VendorFacet` mixin that
`Verify`/`Dispatch`/`Respond`/`Challenge` all include: each of those axns gains `expects :vendor`,
and `Endpoint` passes `vendor: @name` (the registered symbol) into every pipeline call. The facet
TYPE (dimension vs. tag) is a live, mutable global setting, but `dimension`/`tag` are one-time
class-level declarations — so both are declared unconditionally at class-load time, and each
resolver proc reads the *live* config setting when it runs (at call time, once per request), only
"claiming" the vendor value for the currently-selected facet type and returning `nil` (which
`Axn::Core::Tagging.resolve` treats as "omit this facet") otherwise. See Decision B below — this is
the trickiest piece of this phase and is written out in full there.

**Tech Stack:** Ruby ≥ 3.2.1, `axn` + **Rack** (new runtime dependency — see Task 1) + stdlib.
Still no ActionController/teamshares-rails; the Rails dummy app is used only for one integration
test proving the mount works inside real `routes.rb`.

**Spec:** `internal-docs/specs/2026-07-17-axn-webhooks-inbound-design.md` — read **"### 3.
Challenge"**, **"## Packaging"** (Decision 2: mount-first), **Decision 7** (vendor facet), and the
Phase 2–4 amendments at the top (especially Phase 3's `handle`-not-`call` naming note and Phase
4's Decision C, which explicitly reserves `call(env)` for this phase). Phases 1–4
(`Request`/`Response`/`Signature`, `Verify`/`Dispatch`/`Respond`, all four DSL verbs except
`challenge`, `Endpoint#verify`/`#handle`/`#to_response`) are merged to `main`; this repo is
currently on the Phase 5 branch off that.

---

## Open decisions (need confirmation)

Five points, each with a concrete recommendation. Tasks below are written against the
recommendation in each case; where a task depends on a decision, it says so.

### A. What object is the Rack app?

**Options:** (1) `Endpoint#call(env)` — the `Endpoint` itself is the Rack app returned by
`Inbound[:vendor]`. (2) A separate wrapper (`Inbound::RackApp`/`Mount`) that `Inbound[:vendor]`
returns instead of the bare `Endpoint`, or that wraps it.

**Recommendation: (1), `Endpoint#call(env)`.** This is effectively pre-decided by earlier phases,
not a fresh choice: the Phase 3 amendment says `handle` was named (not `call`) "**because Phase 5's
Rack mount owns `call(env)`**," and Phase 4's Decision C states outright "`call(env)` is reserved
for Phase 5's Rack app and is not used here" — both merged, on `main`, before this phase started.
`Endpoint` already holds `verify`/`handle`/`to_response`, all operating on the same `Request`
value; `call(env)` is just a fourth, Rack-shaped entry point on the same object, translating `env`
to `Request` and a `Response` to a Rack triple. A wrapper class would only add indirection —
`Inbound[:vendor]` already needs to be `mount`-able directly per the spec's literal syntax
(`mount Axn::Webhooks::Inbound[:codat], at: "/webhooks/codat"` — no `.rack_app` or similar
accessor in the spec). No collision risk: `Object`/`Kernel` don't define `#call`, so nothing on
`Endpoint` already uses that name.

**Needs confirmation:** none, really — flagging per the task's instructions, but this is the
strongest of the five (grounded in already-merged code, not just this phase's judgment call).

### B. How is `vendor_facet` stamped per-vendor at runtime? (the hard one)

**The tension:** `dimension`/`tag` (`Axn::Core::Tagging::ClassMethods`, `lib/axn/core/tagging.rb` in
the installed `axn` gem) are **class-level** declarations — called once, when a class body is
evaluated (i.e., when `lib/axn/webhooks/verify.rb` etc. is `require`d, at gem-load time). But (a)
the vendor name is **per-endpoint**, not known until an `inbound` block registers one, and (b) the
facet **type** (`:dimension` vs `:tag` vs off) is a **live, mutable** `Axn::Webhooks.config` setting
that a consuming app can change in a Rails initializer — which runs *after* these files have
already loaded and already called `dimension`/`tag` once. A naive
`dimension :vendor, ... if Axn::Webhooks.config.vendor_facet == :dimension` at class-body level
would bake in whatever the setting happened to be at `require` time (almost always `false`, its
default, since gem files load before any app initializer runs) — permanently wrong.

**Recommendation: declare both facets unconditionally, each gated by a resolver that reads the
live setting at *call* time, not declaration time.**

Grounded in how `axn` actually resolves a facet (`Axn::Core::Tagging.resolve`, confirmed reading
`lib/axn/core/tagging.rb` in the installed gem): a facet's `resolver` (here, a `Proc`) is invoked
via `action.instance_exec(&resolver)` **once per call**, not once at class-load time; if the
resolver returns `nil`, `Tagging.resolve` **omits that facet entirely** from the resolved map
(`acc[name] = ... unless value.nil?`). So:

```ruby
# lib/axn/webhooks/vendor_facet.rb (NEW)
module Axn
  module Webhooks
    module VendorFacet
      def self.included(base)
        base.class_eval do
          expects :vendor, allow_blank: true, default: nil

          dimension :vendor, -> { vendor if Axn::Webhooks.config.vendor_facet == :dimension }
          tag       :vendor, -> { vendor if Axn::Webhooks.config.vendor_facet == :tag }
        end
      end
    end
  end
end
```

Both `dimension :vendor` and `tag :vendor` are declared exactly once (at class load), but each is a
closure that reads `Axn::Webhooks.config.vendor_facet` — a fresh read of the *live* value — every
time the pipeline axn actually runs. With the default `false`, both resolvers return `nil` on every
call → `_dimensions`/`_tags` never contribute a `:vendor` facet → zero overhead, zero output,
matching "ships `false`." Flip the setting to `:dimension` (e.g. in a Rails initializer, any time
before the first request) and every subsequent call's `dimension` resolver returns the endpoint's
vendor name while the `tag` resolver keeps returning `nil` — no re-declaration, no load-order
dependency, because the read happens at call time. This is the concrete mechanism the ticket's
"auto-`dimension`" language gestured at, made to actually work with a class-level declaration API
against a runtime setting.

`Verify`, `Dispatch`, `Respond`, and the new `Challenge` (Decision D) each `include VendorFacet`
(each already `include Axn` first — mirrors how `Contract#expects` generates a plain instance
reader, confirmed reading `lib/axn/core/contract.rb`: `define_method(reader) {
internal_context.public_send(source) }` — so `vendor` inside the `->{ vendor if ... }` resolver
resolves through the normal contract accessor, exactly like `Dispatch`'s existing `mode`/`request`
bare calls). `Endpoint` threads `vendor: @name` (the registered symbol) into every
`Verify.call`/`Dispatch.call`/`Respond.call`/`Challenge.call` site — four call sites across
`#verify`, `#handle`, `#to_response`'s `response_for`, and the new `#challenge_response`.

**This requires small changes to Phase 1–4 code**, flagged explicitly:
- `lib/axn/webhooks/verify.rb`, `lib/axn/webhooks/dispatch.rb`, `lib/axn/webhooks/respond.rb` each
  gain one line: `include Axn::Webhooks::VendorFacet` (right after `include Axn`).
- `lib/axn/webhooks/inbound/endpoint.rb`'s three existing pipeline-call sites
  (`Verify.call(request:, verifier: @verifier)`,
  `Dispatch.call(request:, router:, parse:, mode:, respond_declared:)`, and
  `Respond.call(handler_result:, responder:)`) each gain `vendor: @name`.

**Needs confirmation:** this is a genuinely new mechanism (not something already anticipated in
merged code, unlike Decision A) — worth a second look before committing, specifically: (a) is
declaring *both* facets unconditionally (vs. e.g. a single resolver that returns a
`{dimension_or_tag_name => value}`-shaped thing) acceptable, given `axn`'s API doesn't support a
single dynamic facet-type declaration; (b) is per-call cost of evaluating two cheap procs (one of
which always short-circuits to `nil`) negligible — yes, but confirm no one expected zero
declaration overhead.

### C. Does `call(env)` run inside an Axn boundary too?

**Recommendation: yes, but narrowly — only for the one new raising surface, not the whole method.**
`#to_response` and the new `#challenge_response` (Decision D) are already axn-boundary-clean (built
entirely from `Verify`/`Dispatch`/`Respond`/`Challenge` calls, which never raise past their own
boundaries). The **one genuinely new raising surface** Phase 5 introduces is `Request.from_rack(env)`
— building a `Request` from a raw Rack env hash (reading `rack.input`, scanning `HTTP_*` keys) can
raise on a malformed/adversarial env (missing `rack.input`, a stream that doesn't respond to `read`,
etc.) — a real if rare defense-in-depth case (a conforming Rack server never sends a broken env, but
a hand-rolled test double or a buggy upstream middleware might).

Wrap exactly that surface in a new tiny Axn, `Inbound::BuildRequest`:

```ruby
# lib/axn/webhooks/inbound/build_request.rb (NEW)
module Axn
  module Webhooks
    module Inbound
      class BuildRequest
        include Axn
        include Axn::Webhooks::VendorFacet

        expects :env
        exposes :request, type: Axn::Webhooks::Request
        error "Webhook Rack request parsing failed"

        def call
          expose request: Axn::Webhooks::Request.from_rack(env)
        end
      end
    end
  end
end
```

Rejected alternative: calling `Axn.config.on_exception(e, action:, context:)` directly from a bare
`rescue` in `#call(env)`. Grounded reason this is worse: reading `lib/axn/configuration.rb` and
`lib/axn/async/exception_reporting.rb` in the installed gem, `on_exception` expects an `action:`
— a real (or carefully constructed "proxy") action instance, part of axn's internal exception
context contract. Hand-building that context ourselves (to avoid a second Axn) means duplicating
internal plumbing this gem doesn't own or control the stability of; running it through a real Axn
(`BuildRequest.call(env:, vendor: @name)`) gets the *exact* reporting behavior every other failure
in this gem already gets, for free, with zero guessing. It also means `BuildRequest` gets vendor
tagging too — a malformed-env failure is still attributable to the vendor whose endpoint received
it.

`Endpoint#call(env)` itself stays a plain Ruby method (not an Axn) — Rack's contract is
`#call(env) → [status, headers, body]`, a shape that doesn't map onto axn's
`expects`/`exposes`/`Result` idiom without an artificial unwrap step, and there's nothing left to
protect once `BuildRequest` and the two response methods are each already boundary-clean.

**Needs confirmation:** whether one more tiny Axn (bringing the pipeline to five:
`Verify`/`Dispatch`/`Respond`/`Challenge`/`BuildRequest`) is proportionate, versus a simpler
`rescue StandardError` in `#call(env)` that just returns a 500 without going through
`on_exception` at all (losing Honeybadger visibility into a malformed-env bug, which seems like the
wrong tradeoff — but confirm).

### D. GET/challenge specifics — RESOLVED 2026-07-18

**Settled (guard-fail split to 403 per Meta's convention):**

| Case | Status | Body |
| -- | -- | -- |
| `GET`, declared `challenge`, guard (`if:`, if present) passes, resolver returns non-nil | **200** | the resolved value, verbatim, `text/plain` |
| `GET`, declared `challenge`, **guard fails** (e.g. Meta `hub.verify_token` mismatch) | **403** | empty |
| `GET`, declared `challenge`, resolver returns **`nil`** (no challenge value present) | **400** | empty |
| `GET`, declared `challenge`, guard or resolver **raises** | **500** (reported) | empty |
| `GET` with no `challenge` declared | **405** | empty |
| any verb other than `GET`/`POST` | **405** | empty |

**403 vs 400:** a guard (token) failure is a rejected/forbidden verification — Meta's platform expects `403` on a `hub.verify_token` mismatch — while a missing challenge *value* is a malformed request (`400`). A raise is a real bug (loud, reported → `500`); the two non-raising rejections are quiet (no page). The `Challenge` axn computes the exact `Response` itself (guard-fail/nil are *successful* computations of a non-2xx response, not axn failures); only a raise becomes an axn exception → 500. It exposes a typed `Response` (like the `Respond` axn), so a resolver that somehow yields a non-Response can't leak. New `Challenge` axn:

```ruby
# lib/axn/webhooks/inbound/challenge.rb (NEW)
module Axn
  module Webhooks
    module Inbound
      class Challenge
        include Axn
        include Axn::Webhooks::VendorFacet

        expects :request, type: Axn::Webhooks::Request
        expects :resolver
        expects :guard, allow_blank: true, default: nil
        exposes :response, type: Axn::Webhooks::Response
        error "Webhook challenge failed"

        def call
          expose response: build_response
        end

        private

        def build_response
          return Response.new(status: 403) if guard && !guard.call(request) # e.g. Meta hub.verify_token mismatch
          value = resolver.call(request)
          return Response.new(status: 400) if value.nil?

          Response.text(value.to_s)
        end
      end
    end
  end
end
```

`challenge` DSL — stores `{ resolver:, guard: }`; note **`if:` is a genuine Ruby gotcha**: a
keyword parameter literally named `if` shadows the `if` *keyword* inside the method body, so it
cannot be referenced as a bare identifier (confirmed empirically — `def foo(x, if: nil); if; end`
is a syntax trap) and must be read back via `binding.local_variable_get(:if)`:

```ruby
# lib/axn/webhooks/inbound/dsl.rb — new method, alongside verify/dispatch/respond
# rubocop:disable Naming/MethodParameterName
def challenge(resolver, if: nil)
  # `if:` shadows the `if` keyword inside this method — can't reference it as a bare identifier.
  guard = binding.local_variable_get(:if)
  @challenge_spec = { resolver:, guard: }
end
# rubocop:enable Naming/MethodParameterName
```

**Resolved:** guard-fail → 403 (Meta convention), nil value → 400, undeclared/other-verb → 405, raise → 500 (per the table above). `challenge_response` maps: `Challenge` result `ok?` → its `response` (200/403/400); not `ok?` (a raise) → `Response.new(status: 500)`; no `challenge` declared → `Response.new(status: 405)`.

### E. Non-Rails rackup + testing

**Recommendation:** two layers, mirroring the existing dual-suite setup (`spec/` Rails-free +
`spec_rails/dummy_app/` real Rails):

1. **`spec/`** (no Rails) — since Rack is now a direct gemspec dependency (Task 1), `Rack::MockRequest`
   ships in the `rack` gem itself (no extra `rack-test` dependency needed). Use
   `Rack::MockRequest.env_for(path, method:, input:, "CONTENT_TYPE" => ..., "HTTP_X_SIG" => ...)` to
   build realistic envs, plus a couple of hand-built raw env Hashes for the malformed-env
   (Decision C) edge case Rack itself would never actually produce. Drive `Endpoint#call(env)`
   directly (no server, no sockets) and assert on the returned `[status, headers, body]` triple.
2. **`spec_rails/dummy_app/`** — add exactly one real integration test: register an `inbound`
   endpoint (HMAC-verified) in a spec-local initializer-equivalent, `mount` it in
   `config/routes.rb`, then use `Rack::Test::Methods` (already present transitively via Rails —
   confirmed in `spec_rails/dummy_app/Gemfile.lock`: `rack-test (2.2.0)`) to `post` a real signed
   body through the full Rails middleware stack and assert the response status/body — proving the
   "mount bypasses ActionController param parsing, so `rack.input` is pristine" claim from the spec
   actually holds inside a booted Rails app, not just in a hand-built env.

**Needs confirmation:** none — this directly follows the existing dual-suite pattern Phase 1
already established; flagging per the instructions only.

---

## Global Constraints

- **Ruby ≥ 3.2.1.** Dependencies: `axn` + **Rack** (`>= 3.0`, `< 4` — see Task 1 for why 3.0+ only)
  + stdlib. Still no teamshares-rails/ActionController; no unguarded `Rails`/`ActiveRecord`/`ActiveJob`.
- **Nothing escapes.** Every new raising surface (`Request.from_rack`, a `challenge` resolver/guard)
  is wrapped in an Axn (`BuildRequest`, `Challenge`) so a crash is reported once and mapped to a
  clean 500 — never an unhandled exception escaping `Endpoint#call(env)`.
- **The mount owns the whole path, every verb** (spec, "### 3. Challenge"): `Endpoint#call(env)`
  branches on `POST` → `#to_response`, `GET` → `#challenge_response`, anything else → 405. No
  vendor ever needs a second `routes.rb` line for `challenge`.
- **Verify still runs on raw, unparsed bytes** — `Request.from_rack` reads `rack.input` once,
  captures the exact bytes, then `rewind`s the stream (defense-in-depth for any downstream
  middleware, even though this gem never re-reads it itself).
- **`vendor_facet` ships `false` by default** — zero behavior change for a standalone consumer who
  never touches the setting (both `VendorFacet` resolvers return `nil`, so `_dimensions`/`_tags`
  contribute nothing on every call). Teamshares sets `:dimension`.
- **Registry stays test-resettable** (`Axn::Webhooks::Inbound.reset!`); reset in an `after` hook.
  **`Axn::Webhooks.reset_config!`** likewise resets `vendor_facet` between examples that touch it.
- **CHANGELOG** under `## [Unreleased]`. **Done =** `bundle exec rake verify` green (both `spec/`
  and `spec_rails`). **TDD** always, except Task 1 (a bare dependency bump has no independently
  testable behavior of its own — flagged there).

## Grounding notes (verified this session against the installed `axn` and the current branch's code)

- **`Endpoint#to_response` and the constructor's `mode: :async` + `respond:` conflict guard are
  already merged** (`lib/axn/webhooks/inbound/endpoint.rb`, current branch) — Phase 4 landed ahead
  of what its own plan doc shows verbatim (e.g. `Respond` is a real Axn, not the plan's simpler
  inline `RespondContext.new.instance_exec`; `Dispatch`'s adapter-presence check already handles the
  `_async_adapter == false` opt-out edge case). This plan is written against the **actual merged
  code**, not the Phase 4 plan doc's illustrative snippets.
- **`Axn::Core::Tagging` is included into every axn automatically** — `include Core::Tagging` lives
  in `axn/core.rb` (installed gem), which every `include Axn` class pulls in. `dimension`/`tag` are
  therefore already available as class methods on `Verify`/`Dispatch`/`Respond`/`Challenge` with no
  extra include beyond `Axn::Webhooks::VendorFacet` itself (which exists only to share the
  `expects :vendor` + two-facet-declaration boilerplate across four classes, not to grant access to
  `dimension`/`tag`).
- **`Tagging.resolve_one`** (installed gem, `lib/axn/core/tagging.rb`): `when Proc then
  action.instance_exec(&resolver)` — confirms a facet resolver runs fresh **per call**, against the
  live instance, which is what makes Decision B's "read the live config setting inside the
  resolver" mechanism work at all (a class-body-time `if` would freeze the setting at gem-load
  time instead).
- **`Axn.config.on_exception(e, action:, context: {})` requires a real `action:`** (confirmed
  reading `lib/axn/configuration.rb` + `lib/axn/async/exception_reporting.rb`, installed gem) — not
  a bare `(exception)` callback. This is why Decision C recommends routing the one new raising
  surface (`Request.from_rack`) through a real Axn (`BuildRequest`) rather than hand-building an
  `on_exception` call ourselves.
- **`Contract#expects` generates a plain instance reader** (`lib/axn/core/contract.rb`, installed
  gem: `define_method(reader) { internal_context.public_send(source) }`) — confirms `vendor` is a
  bare, `instance_exec`-reachable method once `expects :vendor` is declared, exactly like the
  existing `Dispatch#mode`/`#request` bare calls this codebase already relies on.
- **Rack is NOT currently a dependency of this gem, direct or transitive** — `bundle show axn`'s
  gemspec lists only `activemodel`/`activesupport`; grepping this repo's own `Gemfile.lock` for
  `rack` returns nothing. It arrives only inside `spec_rails/dummy_app`'s *separate* bundle (via
  Rails, `rack (3.2.6)`, confirmed in `spec_rails/dummy_app/Gemfile.lock`). Task 1 adds it directly.
- **`Axn::Webhooks::Response`'s headers are already Rack-3-shaped** (`lib/axn/webhooks/response.rb`,
  current branch) — its own comment says so: `"Keys are lower-cased (Rack 3's SPEC forbids
  uppercase in response header keys...)"`. This was written in Phase 4, before Rack was a
  dependency at all — confirms the gem was always designed toward Rack 3, making `>= 3.0, < 4` the
  natural version constraint rather than a fresh choice.
- **`if:` as a keyword-argument name shadows the `if` keyword inside the method body** — verified
  empirically (`ruby -e 'def foo(x, if: nil); guard = binding.local_variable_get(:if); p guard;
  end; foo(1, if: -> (r) { r })'` → works; a bare `if` reference does not parse as the local). The
  `challenge` DSL method must use `binding.local_variable_get(:if)`, matching the spec's literal
  `challenge ->(req){...}, if: ->(req){...}` syntax.
- **`Rack::Utils.parse_nested_query`** is a public, stable Rack API (no `Rack::Request` instance
  needed) — used for both the query-string and (when applicable) form-body parsing in
  `Request.from_rack`, so `Request` stays a plain value object independent of a live `env`.
- **`spec_rails/dummy_app` already has `rack-test (2.2.0)`** transitively via Rails (confirmed in
  its `Gemfile.lock`) — the Decision E integration test needs no new dependency there.

---

## File Structure (Phase 5)

- Modify `axn-webhooks.gemspec` — add `rack` runtime dependency.
- Modify `lib/axn/webhooks/request.rb` — add `Request.from_rack(env)` + private extraction helpers.
- Modify `lib/axn/webhooks/response.rb` — add `#to_rack`; update the "nothing here touches Rack"
  comment (now false — this is the phase that connects them).
- Create `lib/axn/webhooks/vendor_facet.rb` — the `VendorFacet` mixin (Decision B).
- Modify `lib/axn/webhooks/verify.rb`, `lib/axn/webhooks/dispatch.rb`, `lib/axn/webhooks/respond.rb`
  — `include Axn::Webhooks::VendorFacet`.
- Create `lib/axn/webhooks/inbound/challenge.rb` — the `Challenge` axn (Decision D).
- Create `lib/axn/webhooks/inbound/build_request.rb` — the `BuildRequest` axn (Decision C).
- Modify `lib/axn/webhooks/inbound/dsl.rb` — add `challenge(resolver, if: nil)` + `__challenge__`.
- Modify `lib/axn/webhooks/inbound/endpoint.rb` — accept `challenge:`; thread `vendor: @name` into
  every pipeline call; add `#challenge_response(request)` and `#call(env)`.
- Modify `lib/axn/webhooks/inbound.rb` — pass `challenge: dsl.__challenge__` into `Endpoint.new`.
- Modify `lib/axn/webhooks.rb` — `setting :vendor_facet, default: false, one_of: [false, :dimension,
  :tag]`; require the new files.
- Modify `spec_rails/dummy_app/config/routes.rb` — mount a real endpoint (Decision E).
- Modify `CHANGELOG.md`, `README.md`.
- Tests under `spec/axn/webhooks/` and one new `spec_rails/dummy_app/spec/` file.

---

## Task 1: Add Rack as a runtime dependency

Prerequisite for everything else in this phase. Not independently TDD-able (a bare dependency bump
has no behavior of its own to fail-then-pass against) — flagged as an exception to "TDD always."

**Files:**
- Modify: `axn-webhooks.gemspec`

- [ ] **Step 1: Add the dependency**

```ruby
# axn-webhooks.gemspec
  spec.add_dependency "axn", ">= 0.1.0-alpha.4.3", "< 0.2.0"
  # Rack 3+ only: Response's headers are already lower-cased per Rack 3's SPEC (done in Phase 4,
  # before this was a real dependency), and Rails 7's own transitive rack (spec_rails/dummy_app's
  # Gemfile.lock: rack 3.2.6) is already 3.x — no need to support Rack 2's mixed-case convention.
  spec.add_dependency "rack", ">= 3.0", "< 4"
```

- [ ] **Step 2: `bundle install` and sanity-check**

Run: `bundle install`
Expected: `Gemfile.lock` (gitignored, per `AGENTS.md`) now resolves `rack` for the main `spec/`
suite. Confirm with `bundle exec ruby -e 'require "rack"; puts Rack::RELEASE'` → prints a `3.x`
version.

- [ ] **Step 3: CHANGELOG and commit**

```markdown
### Changed
- Added `rack` (`>= 3.0`, `< 4`) as a runtime dependency, in preparation for the Rack mount.
```

```bash
git add axn-webhooks.gemspec CHANGELOG.md
git commit -m "chore: add rack as a runtime dependency"
```

---

## Task 2: `vendor_facet` setting + `VendorFacet` mixin

*Implements Decision B.* Ships the config setting and the shared mixin, and wires it into the three
existing pipeline axns. This task alone is fully testable without any Rack/challenge code — every
existing spec keeps passing (default `false` ⇒ no behavior change) and new specs assert the
opt-in stamping behavior.

**Files:**
- Create: `lib/axn/webhooks/vendor_facet.rb`
- Modify: `lib/axn/webhooks.rb` (setting + require)
- Modify: `lib/axn/webhooks/verify.rb`, `lib/axn/webhooks/dispatch.rb`, `lib/axn/webhooks/respond.rb`
- Modify: `lib/axn/webhooks/inbound/endpoint.rb` (thread `vendor: @name`)
- Test: `spec/axn/webhooks/vendor_facet_spec.rb`

**Interfaces:**
- `Axn::Webhooks.config.vendor_facet` → `false` | `:dimension` | `:tag` (default `false`).
- `Axn::Webhooks.configure { |c| c.vendor_facet = :dimension }`.
- `Axn::Webhooks::VendorFacet` — a mixin adding `expects :vendor` + the two facet declarations.
- `Verify`/`Dispatch`/`Respond` each accept a new `vendor:` kwarg (optional, `allow_blank: true`,
  default `nil` — existing direct callers of these axns, e.g. any spec built before this phase,
  keep working unchanged).

- [ ] **Step 1: Write the failing tests**

```ruby
# spec/axn/webhooks/vendor_facet_spec.rb
# frozen_string_literal: true

RSpec.describe "Axn::Webhooks vendor_facet" do
  after { Axn::Webhooks.reset_config! }

  it "defaults to false" do
    expect(Axn::Webhooks.config.vendor_facet).to eq(false)
  end

  it "rejects an unknown value" do
    expect { Axn::Webhooks.configure { |c| c.vendor_facet = :bogus } }.to raise_error(ArgumentError)
  end

  %i[dimension tag].each do |value|
    it "accepts #{value.inspect}" do
      expect { Axn::Webhooks.configure { |c| c.vendor_facet = value } }.not_to raise_error
    end
  end

  describe "Verify (representative pipeline axn — Dispatch/Respond/Challenge share the mixin)" do
    def verified_result(vendor:)
      Axn::Webhooks::Verify.call(request: Axn::Webhooks::Request.new(raw_body: "{}"),
                                  verifier: ->(_req) { true }, vendor:)
    end

    it "declares both a :vendor dimension and a :vendor tag unconditionally" do
      expect(Axn::Webhooks::Verify._dimensions.keys).to include(:vendor)
      expect(Axn::Webhooks::Verify._tags.keys).to include(:vendor)
    end

    it "stamps :vendor as a dimension, not a tag, when vendor_facet: :dimension" do
      Axn::Webhooks.configure { |c| c.vendor_facet = :dimension }
      events = []
      callback = ->(*, payload) { events << payload }
      ActiveSupport::Notifications.subscribed(callback, "axn.call") { verified_result(vendor: :codat) }
      payload = events.find { |e| e[:action_class] == Axn::Webhooks::Verify }
      expect(payload[:dimensions]).to eq(vendor: "codat")
      expect(payload[:tags]).to be_nil.or eq({})
    end

    it "stamps :vendor as a tag, not a dimension, when vendor_facet: :tag" do
      Axn::Webhooks.configure { |c| c.vendor_facet = :tag }
      events = []
      callback = ->(*, payload) { events << payload }
      ActiveSupport::Notifications.subscribed(callback, "axn.call") { verified_result(vendor: :codat) }
      payload = events.find { |e| e[:action_class] == Axn::Webhooks::Verify }
      expect(payload[:tags]).to eq(vendor: "codat")
      expect(payload[:dimensions]).to be_nil.or eq({})
    end

    it "stamps neither facet when vendor_facet: false (the default)" do
      events = []
      callback = ->(*, payload) { events << payload }
      ActiveSupport::Notifications.subscribed(callback, "axn.call") { verified_result(vendor: :codat) }
      payload = events.find { |e| e[:action_class] == Axn::Webhooks::Verify }
      expect(payload[:dimensions]).to be_nil.or eq({})
      expect(payload[:tags]).to be_nil.or eq({})
    end

    it "works with vendor: nil (a direct call outside an Endpoint) and stamps nothing" do
      Axn::Webhooks.configure { |c| c.vendor_facet = :dimension }
      expect { verified_result(vendor: nil) }.not_to raise_error
    end
  end

  describe "Endpoint threading vendor: through the pipeline" do
    after { Axn::Webhooks::Inbound.reset! }

    it "passes the registered endpoint name as vendor: into Verify" do
      Axn::Webhooks.configure { |c| c.vendor_facet = :dimension }
      Axn::Webhooks.inbound(:codat) { verify { |_req| true } }
      events = []
      callback = ->(*, payload) { events << payload }
      ActiveSupport::Notifications.subscribed(callback, "axn.call") do
        Axn::Webhooks::Inbound[:codat].verify(Axn::Webhooks::Request.new(raw_body: "{}"))
      end
      payload = events.find { |e| e[:action_class] == Axn::Webhooks::Verify }
      expect(payload[:dimensions]).to eq(vendor: "codat")
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/axn/webhooks/vendor_facet_spec.rb`
Expected: FAIL — `NoMethodError: undefined method 'vendor_facet' for #<Axn::Webhooks::Config...>` /
`unknown keyword: :vendor` for `Verify.call`.

- [ ] **Step 3: Write minimal implementation**

```ruby
# lib/axn/webhooks/vendor_facet.rb (NEW)
# frozen_string_literal: true

module Axn
  module Webhooks
    # Included by each pipeline Axn (Verify/Dispatch/Respond/Challenge) to stamp the endpoint's
    # registered vendor name onto the pipeline as the configured observability facet
    # (Axn::Webhooks.config.vendor_facet). See internal-docs/plans/2026-07-18-axn-webhooks-inbound-
    # phase-5.md, Decision B, for why both facets are declared unconditionally: `dimension`/`tag`
    # are one-time class-level declarations, but the facet TYPE is a live runtime setting and the
    # vendor name is per-endpoint — so each resolver reads the live setting fresh, per call, and
    # "claims" the vendor value only for the currently-selected facet type. A resolver returning nil
    # makes Axn::Core::Tagging.resolve omit that facet entirely, so at most one of {dimension, tag}
    # is ever actually stamped.
    module VendorFacet
      def self.included(base)
        base.class_eval do
          expects :vendor, allow_blank: true, default: nil

          dimension :vendor, -> { vendor if Axn::Webhooks.config.vendor_facet == :dimension }
          tag       :vendor, -> { vendor if Axn::Webhooks.config.vendor_facet == :tag }
        end
      end
    end
  end
end
```

```ruby
# lib/axn/webhooks.rb — add the setting (after config_namespace) and the require
module Axn
  module Webhooks
    extend Axn::Configurable

    config_namespace :webhooks

    # Per-vendor observability facet (spec Decision 7 / PRO-2818). Off by default; a consuming app
    # (Teamshares: :dimension) opts in. See Axn::Webhooks::VendorFacet for the runtime mechanism.
    setting :vendor_facet, default: false, one_of: [false, :dimension, :tag]

    # ... existing Error / deprecator ...
  end
end
```

```ruby
# lib/axn/webhooks.rb — add near the other requires, BEFORE verify/dispatch/respond (they include it)
require_relative "webhooks/vendor_facet"
```

Update `Verify` (`lib/axn/webhooks/verify.rb`):

```ruby
      class Verify
        include Axn
        include Axn::Webhooks::VendorFacet

        expects :request, type: Axn::Webhooks::Request
        expects :verifier
        error "Webhook signature verification failed"

        def call
          fail!("signature mismatch") unless verifier.call(request)
        end
      end
```

Update `Dispatch` (`lib/axn/webhooks/dispatch.rb`) and `Respond` (`lib/axn/webhooks/respond.rb`)
identically — add `include Axn::Webhooks::VendorFacet` immediately after `include Axn`; no other
change to either class's body.

Update `Endpoint` (`lib/axn/webhooks/inbound/endpoint.rb`) to thread `vendor: @name` into every
pipeline call:

```ruby
        def verify(request)
          Verify.call(request:, verifier: @verifier, vendor: @name)
        end

        def handle(request)
          verified = verify(request)
          return verified unless verified.ok? && @dispatch

          Dispatch.call(request:, router: @dispatch[:router], parse: @dispatch[:parse],
                        mode: @dispatch[:mode], respond_declared: !@respond.nil?, vendor: @name)
        end

        def to_response(request)
          verified = verify(request)
          return Response.new(status: 401) unless verified.ok?
          return Response.ack unless @dispatch

          dispatched = Dispatch.call(request:, router: @dispatch[:router], parse: @dispatch[:parse],
                                     mode: @dispatch[:mode], respond_declared: !@respond.nil?, vendor: @name)
          response_for(dispatched)
        end

        private

        def response_for(dispatched)
          return Response.new(status: 500) if dispatched.outcome.exception?
          return Response.ack if dispatched.outcome.failure?
          return Response.ack if dispatched.handler_result.nil?
          return Response.ack unless @respond

          responded = Respond.call(handler_result: dispatched.handler_result, responder: @respond, vendor: @name)
          responded.ok? ? responded.response : Response.new(status: 500)
        end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/axn/webhooks/vendor_facet_spec.rb spec/`
Expected: PASS — including the full existing suite (default `false` must not change any existing
behavior).

- [ ] **Step 5: Update CHANGELOG and commit**

```markdown
### Added
- `Axn::Webhooks.config.vendor_facet` (`setting`, default `false`, `one_of: [false, :dimension,
  :tag]`) — when set, stamps the registered vendor name onto the verify/dispatch/respond pipeline
  as that observability facet (Datadog/OTel dimension or tag), via the new
  `Axn::Webhooks::VendorFacet` mixin shared by `Verify`/`Dispatch`/`Respond`/`Challenge`.
```

```bash
git add lib/axn/webhooks/vendor_facet.rb lib/axn/webhooks.rb lib/axn/webhooks/verify.rb \
        lib/axn/webhooks/dispatch.rb lib/axn/webhooks/respond.rb lib/axn/webhooks/inbound/endpoint.rb \
        spec/axn/webhooks/vendor_facet_spec.rb CHANGELOG.md
git commit -m "feat: add vendor_facet config setting and VendorFacet mixin"
```

---

## Task 3: `Request.from_rack(env)`

*Grounds Decision C's `BuildRequest` (Task 5) and the mount itself (Task 5).* Builds a `Request`
from a raw Rack env: pristine raw body, headers, params (query string + form body when
applicable), url, http_method — independent of any Axn boundary (a pure data transform, like
`Request.new` itself).

**Files:**
- Modify: `lib/axn/webhooks/request.rb`
- Test: `spec/axn/webhooks/request_spec.rb` (extend)

**Interfaces:**
- `Axn::Webhooks::Request.from_rack(env) → Request`.

- [ ] **Step 1: Write the failing tests**

```ruby
# spec/axn/webhooks/request_spec.rb — append inside the existing RSpec.describe block
  describe ".from_rack" do
    def rack_env(**overrides)
      {
        "REQUEST_METHOD" => "POST",
        "PATH_INFO" => "/webhooks/codat",
        "QUERY_STRING" => "",
        "rack.input" => StringIO.new('{"a":1}'),
        "rack.url_scheme" => "https",
        "SERVER_NAME" => "example.com",
        "HTTP_HOST" => "example.com",
        "CONTENT_TYPE" => "application/json",
        "CONTENT_LENGTH" => "7",
        "HTTP_X_SIG" => "abc123",
      }.merge(overrides)
    end

    it "extracts the raw body verbatim from rack.input" do
      request = described_class.from_rack(rack_env)
      expect(request.raw_body).to eq('{"a":1}')
    end

    it "rewinds rack.input after reading, so downstream middleware can still read it" do
      env = rack_env
      described_class.from_rack(env)
      expect(env["rack.input"].read).to eq('{"a":1}')
    end

    it "maps HTTP_* env keys to header names, case-insensitively readable" do
      request = described_class.from_rack(rack_env)
      expect(request.header("X-Sig")).to eq("abc123")
    end

    it "maps CONTENT_TYPE and CONTENT_LENGTH to headers (not HTTP_*-prefixed in Rack)" do
      request = described_class.from_rack(rack_env)
      expect(request.header("Content-Type")).to eq("application/json")
      expect(request.header("Content-Length")).to eq("7")
    end

    it "extracts query-string params" do
      request = described_class.from_rack(rack_env("QUERY_STRING" => "challenge=xyz&a=1"))
      expect(request.params).to eq("challenge" => "xyz", "a" => "1")
    end

    it "merges form-urlencoded body params into params (Twilio's form body)" do
      body = "From=%2B15551234567&To=%2B15557654321"
      env = rack_env(
        "rack.input" => StringIO.new(body),
        "CONTENT_TYPE" => "application/x-www-form-urlencoded",
        "QUERY_STRING" => "extra=1",
      )
      request = described_class.from_rack(env)
      expect(request.params).to eq("From" => "+15551234567", "To" => "+15557654321", "extra" => "1")
      expect(request.raw_body).to eq(body) # verify still sees the untouched raw bytes
    end

    it "does not attempt to parse a non-form body as params" do
      request = described_class.from_rack(rack_env) # application/json body
      expect(request.params).to eq({})
    end

    it "builds the full url including scheme, host, path, and query string" do
      request = described_class.from_rack(rack_env("QUERY_STRING" => "a=1"))
      expect(request.url).to eq("https://example.com/webhooks/codat?a=1")
    end

    it "omits the query string from url when there is none" do
      request = described_class.from_rack(rack_env)
      expect(request.url).to eq("https://example.com/webhooks/codat")
    end

    it "reads the HTTP method" do
      request = described_class.from_rack(rack_env("REQUEST_METHOD" => "GET"))
      expect(request.http_method).to eq("GET")
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/webhooks/request_spec.rb`
Expected: FAIL — `NoMethodError: undefined method 'from_rack' for Axn::Webhooks::Request:Class`.

- [ ] **Step 3: Write minimal implementation**

```ruby
# lib/axn/webhooks/request.rb
# frozen_string_literal: true

require "rack/utils"

module Axn
  module Webhooks
    class Request
      def initialize(raw_body:, headers: {}, params: {}, url: nil, http_method: "POST")
        @raw_body = raw_body.frozen? ? raw_body : raw_body.dup.freeze
        @headers = (headers || {}).each_with_object({}) { |(k, v), h| h[k.to_s.downcase] = v }
        @params = (params || {}).dup.freeze
        @url = url
        @http_method = http_method.to_s.upcase
      end

      attr_reader :raw_body, :params, :url, :http_method

      def header(name)
        @headers[name.to_s.downcase]
      end

      # Build a Request from a Rack env. Reads rack.input ONCE, capturing the exact pristine bytes
      # before rewinding — this (not a controller's already-parsed params) is why the spec chose a
      # Rack mount over a controller concern (see "## Packaging" in the design spec).
      def self.from_rack(env)
        raw_body = env.fetch("rack.input").read
        env["rack.input"].rewind

        content_type = env["CONTENT_TYPE"]
        new(
          raw_body:,
          headers: extract_headers(env),
          params: extract_params(env, raw_body, content_type),
          url: extract_url(env),
          http_method: env["REQUEST_METHOD"],
        )
      end

      # HTTP_* env keys -> header names ("HTTP_X_SIG" -> "X-Sig"-ish; case doesn't matter, #header
      # looks up case-insensitively). CONTENT_TYPE/CONTENT_LENGTH are Rack's two documented
      # exceptions to the HTTP_* convention (never prefixed), so they're mapped explicitly.
      def self.extract_headers(env)
        headers = env.each_with_object({}) do |(key, value), acc|
          next unless key.start_with?("HTTP_")

          acc[key.delete_prefix("HTTP_").tr("_", "-")] = value
        end
        headers["Content-Type"] = env["CONTENT_TYPE"] if env["CONTENT_TYPE"]
        headers["Content-Length"] = env["CONTENT_LENGTH"] if env["CONTENT_LENGTH"]
        headers
      end
      private_class_method :extract_headers

      # Query-string params always; form-urlencoded BODY params merged in only when the content
      # type says so (Twilio's dispatch `parse: ->(req){ req.params }` relies on this) — parsed
      # from the raw_body we already captured, never by re-reading rack.input.
      def self.extract_params(env, raw_body, content_type)
        query = Rack::Utils.parse_nested_query(env["QUERY_STRING"])
        return query unless content_type&.start_with?("application/x-www-form-urlencoded")

        query.merge(Rack::Utils.parse_nested_query(raw_body))
      end
      private_class_method :extract_params

      def self.extract_url(env)
        scheme = env["rack.url_scheme"] || "http"
        host = env["HTTP_HOST"] || env["SERVER_NAME"]
        query = env["QUERY_STRING"]
        "#{scheme}://#{host}#{env['PATH_INFO']}#{"?#{query}" if query && !query.empty?}"
      end
      private_class_method :extract_url
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/axn/webhooks/request_spec.rb`
Expected: PASS.

- [ ] **Step 5: Update CHANGELOG and commit**

```markdown
### Added
- `Axn::Webhooks::Request.from_rack(env)` — builds a Request from a Rack env: pristine raw body
  (read once from `rack.input`, then rewound), headers from `HTTP_*`/`CONTENT_TYPE`/
  `CONTENT_LENGTH`, params from the query string (merged with form-decoded body params when the
  content type is `application/x-www-form-urlencoded`), url, and http_method.
```

```bash
git add lib/axn/webhooks/request.rb spec/axn/webhooks/request_spec.rb CHANGELOG.md
git commit -m "feat: add Request.from_rack"
```

---

## Task 4: `challenge` DSL + `Challenge` axn + `Endpoint#challenge_response`

*Implements Decision D.* The GET-echo handshake, as an Axn (so a raising resolver/guard is
reported + mapped to 500, never escaping).

**Files:**
- Create: `lib/axn/webhooks/inbound/challenge.rb`
- Modify: `lib/axn/webhooks/inbound/dsl.rb`
- Modify: `lib/axn/webhooks/inbound/endpoint.rb`
- Modify: `lib/axn/webhooks/inbound.rb`
- Modify: `lib/axn/webhooks.rb` (require)
- Test: `spec/axn/webhooks/inbound/challenge_spec.rb`, `spec/axn/webhooks/inbound/dsl_challenge_spec.rb`

**Interfaces:**
- `Axn::Webhooks::Inbound::Challenge.call(request:, resolver:, guard: nil, vendor: nil) →
  Axn::Result` (`exposes :response`, a typed `Axn::Webhooks::Response` — 200 echo, 403 guard-fail,
  400 nil value; a raise → exception outcome). Guard-fail/nil are *successful* computations of a
  non-2xx `Response`, not axn failures.
- `DSL#challenge(resolver, if: nil)`; `DSL#__challenge__ → { resolver:, guard: } | nil`.
- `Endpoint.new(..., challenge: nil)`; `Endpoint#challenge_response(request) → Response` (public —
  testable without a Rack env, mirroring `#verify`/`#handle`/`#to_response`).

- [ ] **Step 1: Write the failing tests**

```ruby
# spec/axn/webhooks/inbound/dsl_challenge_spec.rb
# frozen_string_literal: true

RSpec.describe Axn::Webhooks::Inbound::DSL do
  describe "#challenge" do
    it "defaults __challenge__ to nil when undeclared" do
      expect(described_class.new.__challenge__).to be_nil
    end

    it "captures the resolver with no guard" do
      dsl = described_class.new
      resolver = ->(req) { req.params["challenge"] }
      dsl.challenge(resolver)
      expect(dsl.__challenge__).to eq(resolver:, guard: nil)
    end

    it "captures the resolver and an if: guard" do
      dsl = described_class.new
      resolver = ->(req) { req.params["hub.challenge"] }
      guard = ->(req) { req.params["hub.verify_token"] == "secret" }
      dsl.challenge(resolver, if: guard)
      expect(dsl.__challenge__).to eq(resolver:, guard:)
    end
  end
end
```

```ruby
# spec/axn/webhooks/inbound/challenge_spec.rb
# frozen_string_literal: true

RSpec.describe Axn::Webhooks::Inbound::Challenge do
  def req(params) = Axn::Webhooks::Request.new(raw_body: "", params:)

  it "echoes the resolver's value as a 200 text/plain Response" do
    result = described_class.call(request: req("challenge" => "xyz"), resolver: ->(r) { r.params["challenge"] })
    expect(result).to be_ok
    expect(result.response.status).to eq(200)
    expect(result.response.body).to eq("xyz")
    expect(result.response.headers).to eq("content-type" => "text/plain")
  end

  it "computes a 400 Response (no exception) when the resolver returns nil" do
    result = described_class.call(request: req({}), resolver: ->(r) { r.params["challenge"] })
    expect(result).to be_ok
    expect(result.response.status).to eq(400)
  end

  it "computes a 403 Response when a guard rejects the request" do
    result = described_class.call(
      request: req("hub.challenge" => "xyz", "hub.verify_token" => "wrong"),
      resolver: ->(r) { r.params["hub.challenge"] },
      guard: ->(r) { r.params["hub.verify_token"] == "right" },
    )
    expect(result).to be_ok
    expect(result.response.status).to eq(403)
  end

  it "echoes when the guard accepts the request" do
    result = described_class.call(
      request: req("hub.challenge" => "xyz", "hub.verify_token" => "right"),
      resolver: ->(r) { r.params["hub.challenge"] },
      guard: ->(r) { r.params["hub.verify_token"] == "right" },
    )
    expect(result).to be_ok
    expect(result.response.body).to eq("xyz")
  end

  it "reports (exception) rather than raises when the resolver crashes" do
    result = nil
    expect { result = described_class.call(request: req({}), resolver: ->(_r) { raise "boom" }) }.not_to raise_error
    expect(result.outcome).to be_exception
  end
end
```

```ruby
# spec/axn/webhooks/inbound/dsl_challenge_endpoint_spec.rb (Endpoint#challenge_response)
# frozen_string_literal: true

RSpec.describe "Axn::Webhooks::Inbound::Endpoint#challenge_response" do
  after { Axn::Webhooks::Inbound.reset! }

  def get(params) = Axn::Webhooks::Request.new(raw_body: "", params:, http_method: "GET")

  it "echoes verbatim as a 200 text/plain response (Nylas-style, no guard)" do
    Axn::Webhooks.inbound(:nylas) do
      verify { |_req| true }
      challenge ->(req) { req.params["challenge"] }
    end
    response = Axn::Webhooks::Inbound[:nylas].challenge_response(get("challenge" => "xyz"))
    expect(response.status).to eq(200)
    expect(response.body).to eq("xyz")
    expect(response.headers).to eq("content-type" => "text/plain")
  end

  it "returns 400 when the challenge param is missing" do
    Axn::Webhooks.inbound(:nylas) { challenge ->(req) { req.params["challenge"] } }
    expect(Axn::Webhooks::Inbound[:nylas].challenge_response(get({})).status).to eq(400)
  end

  it "returns 403 when a guard (Meta's hub.verify_token) rejects the request" do
    Axn::Webhooks.inbound(:meta) do
      challenge ->(req) { req.params["hub.challenge"] }, if: ->(req) { req.params["hub.verify_token"] == "expected" }
    end
    response = Axn::Webhooks::Inbound[:meta].challenge_response(
      get("hub.challenge" => "xyz", "hub.verify_token" => "wrong"),
    )
    expect(response.status).to eq(403)
  end

  it "returns 200 when the guard accepts the request (Meta)" do
    Axn::Webhooks.inbound(:meta) do
      challenge ->(req) { req.params["hub.challenge"] }, if: ->(req) { req.params["hub.verify_token"] == "expected" }
    end
    response = Axn::Webhooks::Inbound[:meta].challenge_response(
      get("hub.challenge" => "xyz", "hub.verify_token" => "expected"),
    )
    expect(response.status).to eq(200)
    expect(response.body).to eq("xyz")
  end

  it "returns 405 when no challenge is declared" do
    Axn::Webhooks.inbound(:codat) { verify { |_req| true } }
    expect(Axn::Webhooks::Inbound[:codat].challenge_response(get({})).status).to eq(405)
  end

  it "returns 500 (reported) when the resolver crashes" do
    Axn::Webhooks.inbound(:broken) { challenge ->(_req) { raise "boom" } }
    expect(Axn::Webhooks::Inbound[:broken].challenge_response(get({})).status).to eq(500)
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/axn/webhooks/inbound/challenge_spec.rb spec/axn/webhooks/inbound/dsl_challenge_spec.rb spec/axn/webhooks/inbound/dsl_challenge_endpoint_spec.rb`
Expected: FAIL — `uninitialized constant Axn::Webhooks::Inbound::Challenge` / `undefined method
'challenge'` / `undefined method 'challenge_response'`.

- [ ] **Step 3: Write minimal implementation**

```ruby
# lib/axn/webhooks/inbound/challenge.rb (NEW)
# frozen_string_literal: true

module Axn
  module Webhooks
    module Inbound
      # The GET-echo handshake (spec: "### 3. Challenge"). Computes the exact Response: 200 echo,
      # 403 when a guard (e.g. Meta hub.verify_token) rejects, 400 when there's no challenge value
      # — all quiet (no page). A resolver or guard that RAISES is a loud exception (reported, mapped
      # to 500 by Endpoint#challenge_response) — never an unhandled crash. Exposes a typed Response.
      class Challenge
        include Axn
        include Axn::Webhooks::VendorFacet

        expects :request, type: Axn::Webhooks::Request
        expects :resolver
        expects :guard, allow_blank: true, default: nil
        exposes :response, type: Axn::Webhooks::Response
        error "Webhook challenge failed"

        def call
          expose response: build_response
        end

        private

        def build_response
          return Response.new(status: 403) if guard && !guard.call(request) # e.g. Meta hub.verify_token mismatch
          value = resolver.call(request)
          return Response.new(status: 400) if value.nil?

          Response.text(value.to_s)
        end
      end
    end
  end
end
```

Add to `DSL` (`lib/axn/webhooks/inbound/dsl.rb`), below `respond`:

```ruby
        # challenge ->(req){ req.params["challenge"] }                          — Nylas
        # challenge ->(req){ req.params["hub.challenge"] }, if: ->(req){ ... }  — Meta
        # rubocop:disable Naming/MethodParameterName
        def challenge(resolver, if: nil)
          # `if:` shadows Ruby's `if` keyword inside this method body — must read it back via
          # binding.local_variable_get, not a bare `if` reference (that's a syntax trap, not a var).
          guard = binding.local_variable_get(:if)
          @challenge_spec = { resolver:, guard: }
        end
        # rubocop:enable Naming/MethodParameterName
```

Add to `DSL`, below `__respond__`:

```ruby
        # Internal: the captured { resolver:, guard: } challenge declaration, or nil if none.
        def __challenge__ = @challenge_spec
```

Update `Endpoint` (`lib/axn/webhooks/inbound/endpoint.rb`) — constructor + new method:

```ruby
        def initialize(name:, verifier:, dispatch: nil, respond: nil, challenge: nil)
          if dispatch && dispatch[:mode] == :async && respond
            raise Axn::Webhooks::Error, # ... (unchanged, see Phase 4)
          end

          @name = name.to_sym
          @verifier = verifier
          @dispatch = dispatch
          @respond = respond
          @challenge = challenge
        end
```

```ruby
        # The GET branch (spec: the mount owns the whole path, every verb). Testable without a Rack
        # env, mirroring #verify/#handle/#to_response.
        def challenge_response(request)
          return Response.new(status: 405) unless @challenge

          # The Challenge axn computes the exact Response (200 echo / 403 guard-fail / 400 nil).
          # Only a raising resolver/guard makes it not-ok -> a reported 500.
          result = Challenge.call(request:, resolver: @challenge[:resolver], guard: @challenge[:guard], vendor: @name)
          result.ok? ? result.response : Response.new(status: 500)
        end
```

Update `Axn::Webhooks.inbound` (`lib/axn/webhooks/inbound.rb`) to pass the challenge spec:

```ruby
      Inbound.register(
        name,
        Inbound::Endpoint.new(
          name:,
          verifier: dsl.__verifier__,
          dispatch: dsl.__dispatch__,
          respond: dsl.__respond__,
          challenge: dsl.__challenge__,
        ),
      )
```

```ruby
# lib/axn/webhooks.rb — add below the other inbound/* requires
require_relative "webhooks/inbound/challenge"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/axn/webhooks/inbound/challenge_spec.rb spec/axn/webhooks/inbound/dsl_challenge_spec.rb spec/axn/webhooks/inbound/dsl_challenge_endpoint_spec.rb spec/`
Expected: PASS.

- [ ] **Step 5: Update CHANGELOG and commit**

```markdown
### Added
- `challenge` DSL declaration + `Axn::Webhooks::Inbound::Challenge` — the GET-echo handshake
  (Nylas `?challenge=`, Meta `?hub.challenge=` + `if:` guard on `hub.verify_token`). A missing/
  rejected challenge is a quiet 400; a resolver or guard that raises is reported and mapped to 500.
  `Endpoint#challenge_response(request) → Response` is testable without a Rack env, mirroring
  `#verify`/`#handle`/`#to_response`.
```

```bash
git add lib/axn/webhooks/inbound/challenge.rb lib/axn/webhooks/inbound/dsl.rb \
        lib/axn/webhooks/inbound/endpoint.rb lib/axn/webhooks/inbound.rb lib/axn/webhooks.rb \
        spec/axn/webhooks/inbound/challenge_spec.rb spec/axn/webhooks/inbound/dsl_challenge_spec.rb \
        spec/axn/webhooks/inbound/dsl_challenge_endpoint_spec.rb CHANGELOG.md
git commit -m "feat: add challenge DSL and Challenge axn"
```

---

## Task 5: `BuildRequest` axn + `Response#to_rack` + `Endpoint#call(env)` — the Rack mount

*Implements Decisions A and C.* The core Phase 5 deliverable: `Inbound[:vendor]` becomes directly
`mount`/`run`-able.

**Files:**
- Create: `lib/axn/webhooks/inbound/build_request.rb`
- Modify: `lib/axn/webhooks/response.rb` (`#to_rack`)
- Modify: `lib/axn/webhooks/inbound/endpoint.rb` (`#call(env)`)
- Modify: `lib/axn/webhooks.rb` (require)
- Test: `spec/axn/webhooks/response_spec.rb` (extend), `spec/axn/webhooks/inbound/rack_spec.rb`

**Interfaces:**
- `Axn::Webhooks::Inbound::BuildRequest.call(env:, vendor: nil) → Axn::Result` (`exposes :request`).
- `Response#to_rack → [status, headers, [body]]`.
- `Endpoint#call(env) → [status, headers, [body]]` — `POST` → `#to_response`; `GET` →
  `#challenge_response`; any other verb → 405; a `BuildRequest` failure → 500.

- [ ] **Step 1: Write the failing tests**

```ruby
# spec/axn/webhooks/response_spec.rb — append
  it "renders as a Rack triple" do
    response = described_class.text("hi", status: 201)
    expect(response.to_rack).to eq([201, { "content-type" => "text/plain" }, ["hi"]])
  end
```

```ruby
# spec/axn/webhooks/inbound/rack_spec.rb
# frozen_string_literal: true

require "openssl"
require "rack"

RSpec.describe "Axn::Webhooks::Inbound::Endpoint#call (Rack app)" do
  after { Axn::Webhooks::Inbound.reset! }

  let(:secret) { "shh" }

  before do
    stub_const("Handlers", Module.new)
    stub_const("Handlers::Created", Class.new do
      include Axn
      expects :event
      exposes :seen_id
      def call = expose(seen_id: event.dig("data", "id"))
    end)
  end

  def signed_env(body, sig: nil)
    sig ||= OpenSSL::HMAC.hexdigest("SHA256", secret, body)
    Rack::MockRequest.env_for("/webhooks/vendor", method: "POST", input: body,
                              "CONTENT_TYPE" => "application/json", "HTTP_X_SIG" => sig)
  end

  it "responds to call(env) directly, satisfying the Rack app contract" do
    Axn::Webhooks.inbound(:vendor) { verify { |_req| true } }
    expect(Axn::Webhooks::Inbound[:vendor]).to respond_to(:call)
  end

  it "is mountable/runnable via Rack::MockRequest end-to-end (POST -> verify -> dispatch -> ack)" do
    Axn::Webhooks.inbound(:vendor) do
      verify :hmac, secret:, signature: header("X-Sig")
      dispatch on: ->(e) { e["type"] }, to: { "created" => "Handlers::Created" }
    end
    body = '{"type":"created","data":{"id":99}}'
    status, headers, response_body = Axn::Webhooks::Inbound[:vendor].call(signed_env(body))
    expect(status).to eq(200)
    expect(headers).to eq({})
    expect(response_body).to eq([""])
  end

  it "returns 401 for a bad signature over Rack" do
    Axn::Webhooks.inbound(:vendor) { verify :hmac, secret:, signature: header("X-Sig") }
    status, = Axn::Webhooks::Inbound[:vendor].call(signed_env("{}", sig: "wrong"))
    expect(status).to eq(401)
  end

  it "handles GET as the declared challenge" do
    Axn::Webhooks.inbound(:vendor) { challenge ->(req) { req.params["challenge"] } }
    env = Rack::MockRequest.env_for("/webhooks/vendor?challenge=xyz", method: "GET")
    status, headers, body = Axn::Webhooks::Inbound[:vendor].call(env)
    expect(status).to eq(200)
    expect(headers["content-type"]).to eq("text/plain")
    expect(body).to eq(["xyz"])
  end

  it "405s a GET with no declared challenge" do
    Axn::Webhooks.inbound(:vendor) { verify { |_req| true } }
    env = Rack::MockRequest.env_for("/webhooks/vendor", method: "GET")
    status, = Axn::Webhooks::Inbound[:vendor].call(env)
    expect(status).to eq(405)
  end

  it "405s any verb other than GET/POST" do
    Axn::Webhooks.inbound(:vendor) { verify { |_req| true } }
    env = Rack::MockRequest.env_for("/webhooks/vendor", method: "PUT")
    status, = Axn::Webhooks::Inbound[:vendor].call(env)
    expect(status).to eq(405)
  end

  it "returns a clean 500 (never raises) for a malformed env BuildRequest can't parse" do
    Axn::Webhooks.inbound(:vendor) { verify { |_req| true } }
    broken_env = { "REQUEST_METHOD" => "POST" } # no rack.input at all
    status, = nil
    expect { status, = Axn::Webhooks::Inbound[:vendor].call(broken_env) }.not_to raise_error
    expect(status).to eq(500)
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/axn/webhooks/response_spec.rb spec/axn/webhooks/inbound/rack_spec.rb`
Expected: FAIL — `undefined method 'to_rack'` / `undefined method 'call' for an instance of
Axn::Webhooks::Inbound::Endpoint`.

- [ ] **Step 3: Write minimal implementation**

```ruby
# lib/axn/webhooks/inbound/build_request.rb (NEW)
# frozen_string_literal: true

module Axn
  module Webhooks
    module Inbound
      # Wraps Request.from_rack in an Axn boundary so a malformed/adversarial env (missing
      # rack.input, etc.) is reported via Axn.config.on_exception and mapped to a clean 500 by
      # Endpoint#call, never an unhandled exception escaping the Rack app.
      class BuildRequest
        include Axn
        include Axn::Webhooks::VendorFacet

        expects :env
        exposes :request, type: Axn::Webhooks::Request
        error "Webhook Rack request parsing failed"

        def call
          expose request: Axn::Webhooks::Request.from_rack(env)
        end
      end
    end
  end
end
```

Update `Response` (`lib/axn/webhooks/response.rb`) — add `#to_rack`, and correct the now-stale
"nothing here touches Rack" comment:

```ruby
    # A Rails-agnostic HTTP response value: status + body + headers. Produced by
    # `Endpoint#to_response`/`#challenge_response` from the pipeline's Axn::Result. `#to_rack`
    # renders it as the [status, headers, body] triple Endpoint#call(env) returns.
    class Response
      # ... existing body unchanged ...

      # [status, headers, body] — the Rack app return contract. Headers are already lower-cased
      # (see #initialize); body is wrapped in an Array, Rack's documented minimal body contract.
      def to_rack = [status, headers, [body]]
```

Update `Endpoint` (`lib/axn/webhooks/inbound/endpoint.rb`) — add `#call(env)`:

```ruby
        # The Rack app entry point (spec: mount-first packaging). `Inbound[:vendor]` (this object)
        # is directly `mount`-able in Rails routes.rb or `run`-able in a bare Rack::Builder — the
        # mount owns the whole path and every verb: POST -> #to_response, GET -> #challenge_response,
        # anything else -> 405. Named `call`, deliberately reserved since Phase 3 (see #handle).
        def call(env)
          built = BuildRequest.call(env:, vendor: @name)
          return Response.new(status: 500).to_rack unless built.ok?

          request = built.request
          response =
            case request.http_method
            when "POST" then to_response(request)
            when "GET" then challenge_response(request)
            else Response.new(status: 405)
            end
          response.to_rack
        end
```

```ruby
# lib/axn/webhooks.rb — add below the other inbound/* requires
require_relative "webhooks/inbound/build_request"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/axn/webhooks/response_spec.rb spec/axn/webhooks/inbound/rack_spec.rb spec/`
Expected: PASS.

- [ ] **Step 5: Update CHANGELOG and commit**

```markdown
### Added
- `Axn::Webhooks::Inbound::Endpoint#call(env)` — `Inbound[:vendor]` is now directly a Rack app:
  `mount Axn::Webhooks::Inbound[:vendor], at: "/webhooks/vendor"` in Rails, or
  `run Axn::Webhooks::Inbound[:vendor]` in a bare `Rack::Builder`/`config.ru`. `POST` runs
  `#to_response`; `GET` runs `#challenge_response` (or 405 with no declared `challenge`); any other
  verb 405s. A malformed Rack env is caught by the new `Inbound::BuildRequest` axn and mapped to a
  reported 500, never an unhandled exception.
- `Axn::Webhooks::Response#to_rack` — renders a Response as the `[status, headers, [body]]` triple
  a Rack app returns.
```

```bash
git add lib/axn/webhooks/inbound/build_request.rb lib/axn/webhooks/response.rb \
        lib/axn/webhooks/inbound/endpoint.rb lib/axn/webhooks.rb \
        spec/axn/webhooks/response_spec.rb spec/axn/webhooks/inbound/rack_spec.rb CHANGELOG.md
git commit -m "feat: add Endpoint#call(env), the Rack mount entry point"
```

---

## Task 6: Rails dummy-app integration test

*Implements Decision E's second layer.* Proves the mount works inside a booted Rails app — real
`routes.rb`, real middleware stack, real `Rack::Test` POST.

**Files:**
- Modify: `spec_rails/dummy_app/config/routes.rb`
- Create/modify: `spec_rails/dummy_app/spec/integration_spec.rb` (or a new
  `spec_rails/dummy_app/spec/webhook_mount_spec.rb`)

- [ ] **Step 1: Write the failing test**

```ruby
# spec_rails/dummy_app/config/routes.rb
# frozen_string_literal: true

Rails.application.routes.draw do
  mount Axn::Webhooks::Inbound[:test_vendor], at: "/webhooks/test_vendor" if Axn::Webhooks::Inbound.registered.include?(:test_vendor)
end
```

```ruby
# spec_rails/dummy_app/spec/webhook_mount_spec.rb (NEW)
# frozen_string_literal: true

require "spec_helper"
require "rack/test"

RSpec.describe "Axn::Webhooks mounted in a real Rails app" do
  include Rack::Test::Methods

  def app = Rails.application

  before do
    stub_const("Handlers", Module.new) unless defined?(Handlers)
    stub_const("Handlers::Created", Class.new do
      include Axn
      expects :event
      exposes :seen_id
      def call = expose(seen_id: event.dig("data", "id"))
    end)
    Axn::Webhooks.inbound(:test_vendor) do
      verify :hmac, secret: "shh", signature: header("X-Sig")
      dispatch on: ->(e) { e["type"] }, to: { "created" => "Handlers::Created" }
    end
    Rails.application.reload_routes!
  end

  after { Axn::Webhooks::Inbound.reset! }

  it "verifies and dispatches a real signed POST through the full middleware stack" do
    body = '{"type":"created","data":{"id":42}}'
    sig = OpenSSL::HMAC.hexdigest("SHA256", "shh", body)
    header "X-Sig", sig
    header "Content-Type", "application/json"
    post "/webhooks/test_vendor", body
    expect(last_response.status).to eq(200)
    expect(last_response.body).to eq("")
  end

  it "401s a real request with a bad signature (rack.input stayed pristine through Rails' stack)" do
    header "X-Sig", "wrong"
    header "Content-Type", "application/json"
    post "/webhooks/test_vendor", '{"type":"created"}'
    expect(last_response.status).to eq(401)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd spec_rails/dummy_app && BUNDLE_GEMFILE=Gemfile bundle exec rspec spec/webhook_mount_spec.rb`
Expected: FAIL initially (route not mounted / endpoint not registered before routes load —
confirms the fixture ordering needs `reload_routes!` after registration, already included above).

- [ ] **Step 3: Adjust until routing + dispatch works**

No new library code — this task validates Task 5's implementation inside Rails, and may need
`Rails.application.reload_routes!` (already in the spec above) since routes are normally drawn once
at boot, before the test registers `:test_vendor`. If `reload_routes!` proves insufficient (Rails
version-dependent), fall back to registering `:test_vendor` in
`spec_rails/dummy_app/config/initializers/webhooks.rb` (a real initializer, booted once) instead of
inside the spec — more realistic anyway (mirrors how a real consuming app registers vendors) and
sidesteps any route-reloading flakiness. Prefer the initializer if the inline `reload_routes!`
approach is flaky.

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rake verify` (runs both suites + rubocop).
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add spec_rails/dummy_app/config/routes.rb spec_rails/dummy_app/spec/webhook_mount_spec.rb
git commit -m "test: add Rails dummy-app integration test for the Rack mount"
```

(No CHANGELOG entry — this is test-only, no library behavior change.)

---

## Task 7: Phase 5 wrap-up — full verify + README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Run the full dual suite**

Run: `bundle exec rake verify`
Expected: all library specs + Rails dummy-app specs pass, rubocop clean.

- [ ] **Step 2: Extend the README "Inbound endpoints" section**

Add, after "### Async dispatch":

```markdown
### Mounting

An `Inbound[:vendor]` endpoint is a Rack app — mount it directly, no controller needed:

​```ruby
# config/routes.rb (Rails)
Rails.application.routes.draw do
  mount Axn::Webhooks::Inbound[:codat], at: "/webhooks/codat"
end
​```

​```ruby
# config.ru (no Rails)
require "axn-webhooks"
map "/webhooks/codat" { run Axn::Webhooks::Inbound[:codat] }
​```

The mount owns the whole path and every verb: `POST` runs verify → dispatch → respond; `GET` runs
a declared `challenge`, or 405s if none was declared.

### Challenge (GET-echo handshake)

Some vendors (Nylas, Meta) verify a new endpoint with a `GET` request before sending real events:

​```ruby
Axn::Webhooks.inbound :nylas do
  verify { |req| ... }
  challenge ->(req) { req.params["challenge"] }   # echoed verbatim, 200 text/plain
end

Axn::Webhooks.inbound :meta do
  challenge ->(req) { req.params["hub.challenge"] },
            if: ->(req) { req.params["hub.verify_token"] == ENV.fetch("META_VERIFY_TOKEN") }
end
​```

No extra `routes.rb` line is needed — `challenge` just teaches the same mount how to answer `GET`.
A missing/rejected challenge is a quiet 400; a `challenge`/`if:` proc that raises is reported and
mapped to 500. (Slack's in-band `url_verification` handshake is NOT this — it's a normal `dispatch`
entry, since Slack sends it as a POST event, not a GET.)

### Per-vendor observability (`vendor_facet`)

​```ruby
Axn::Webhooks.configure { |c| c.vendor_facet = :dimension }  # or :tag; default false
​```

When set, every `verify`/`dispatch`/`respond`/`challenge` call for a registered endpoint is stamped
with the endpoint's registered name as that Datadog/OTel facet — `:dimension` for a bounded,
low-cardinality grouping (Teamshares' choice); `:tag` for the higher-cardinality path. Ships `false`
(no stamping) so a standalone consumer opts in explicitly.
```

- [ ] **Step 3: Re-run `bundle exec rake verify`, then commit**

```bash
git add README.md
git commit -m "docs: document the Rack mount, challenge, and vendor_facet; close Phase 5"
```

---

## Self-Review (Phase 5)

- **Spec coverage:** Rack mount (`Endpoint#call(env)`, Decision A) ✅ Task 5; `Request.from_rack`
  ✅ Task 3; `POST`/`GET`/405 verb branching ✅ Task 5; `challenge` DSL + GET-echo (Decision D) ✅
  Task 4; `vendor_facet` setting + runtime stamping mechanism (Decision B) ✅ Task 2; "nothing
  escapes" extended to the two new raising surfaces (`Request.from_rack`, challenge resolver/guard)
  via `BuildRequest`/`Challenge` axns (Decision C) ✅ Tasks 4–5; Rack-mounted integration proof
  (Decision E) ✅ Task 6.
- **Placeholder scan:** every code step above is complete, runnable code — no `# ...` elisions
  inside actual file contents (elisions like "unchanged, see Phase 4" appear only where quoting the
  *entire* surrounding method would be pure repetition of already-merged code, and are always next
  to the genuinely new lines being added).
- **Type consistency:** `Request.from_rack(env) → Request`; `Response#to_rack → [Integer, Hash,
  Array<String>]`; `Endpoint#call(env) → [Integer, Hash, Array<String>]`;
  `Endpoint#challenge_response(request) → Response`; `Endpoint.new(name:, verifier:, dispatch:,
  respond:, challenge:)`; `BuildRequest.call(env:, vendor:) → Result#request`;
  `Challenge.call(request:, resolver:, guard:, vendor:) → Result#body`; every pipeline axn
  (`Verify`/`Dispatch`/`Respond`/`Challenge`/`BuildRequest`) now also accepts `vendor:`
  (`allow_blank: true, default: nil` — backward compatible with any existing direct call site).
- **Boundary invariant:** the only two new raising surfaces this phase introduces
  (`Request.from_rack`'s env parsing, a `challenge`/`if:` proc) are each wrapped in their own Axn
  (`BuildRequest`, `Challenge`) — `Endpoint#call(env)` itself never has a bare `rescue`, and never
  needs one, because nothing it calls directly (`BuildRequest.call`, `#to_response`,
  `#challenge_response`) can raise past its own boundary.
- **Decision-B soundness check:** `VendorFacet`'s two `dimension`/`tag` declarations are evaluated
  once, at gem-load time (when `verify.rb`/`dispatch.rb`/`respond.rb`/`challenge.rb` are required)
  — but their *resolvers* (the `-> { vendor if ... }` procs) run fresh on every single call, reading
  `Axn::Webhooks.config.vendor_facet` live each time (confirmed via `Axn::Core::Tagging.resolve_one`
  in the installed gem: `action.instance_exec(&resolver)`, called per-call, not at declaration).
  This is the one piece of this plan not already anticipated by merged Phase 1–4 code, and is
  flagged as such in "Open decisions," Decision B.
- **All five decisions have a recommendation + rationale + an explicit confirmation flag**, per the
  task's requirement — A and E are near-certain (grounded in already-merged naming reservations /
  existing dual-suite precedent); B, C, and D are genuine judgment calls this plan surfaces clearly
  rather than silently picking.
- **Small changes to existing Phase 1–4 code, called out explicitly (not buried):** `Verify`/
  `Dispatch`/`Respond` each gain one `include Axn::Webhooks::VendorFacet` line (Task 2); `Endpoint`'s
  three existing pipeline-call sites gain a `vendor: @name` kwarg (Task 2); `Endpoint`'s constructor
  gains a fourth `challenge:` kwarg (Task 4); `Response` gains `#to_rack` and a corrected docstring
  (Task 5); `Axn::Webhooks.inbound` gains one more kwarg passed to `Endpoint.new` (Task 4).
