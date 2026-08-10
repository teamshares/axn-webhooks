# axn-webhooks — static respond body independent of dispatch outcome (design)

> **Source:** [PRO-3076 — [axn-webhooks] Static respond body independent of dispatch outcome (async + literal ack)](https://linear.app/teamshares/issue/PRO-3076/axn-webhooks-static-respond-body-independent-of-dispatch-outcome-async). Brainstorm settled 2026-08-10. Extends the inbound design ([2026-07-17-axn-webhooks-inbound-design.md](2026-07-17-axn-webhooks-inbound-design.md)) — specifically **Decision D / "Sync vs async"** and "Respond + staged outcome model" — without reversing either.

## Why

`respond` only ever renders on a **genuine synchronous handler success** — `Endpoint#response_for` returns a bare `Response.ack` whenever `handler_result` is `nil` (async enqueue, `otherwise: :ack`) or the handler's own `fail!`, before it ever consults `@respond`. That coupling is correct for `respond`'s two real use cases (Twilio TwiML, Slack `response_action`), which genuinely need to read the handler's result — but it means a **static** body, one that ignores the handler result entirely, can't coexist with async dispatch:

| Configuration | Result today |
| -- | -- |
| sync + `respond` | `200 "Hello API Event Received"` — works |
| `mode: :auto` + `respond` | forced **sync** (`respond_declared` short-circuits `async?`) |
| explicit `mode: :async` + `respond` | **raises at registration** |
| per-route `async(...)` + `respond` | `200` with **empty body** — the literal is silently dropped |
| sync + handler business `fail!` | `200` with **empty body** |

This breaks the gem's own README DropboxSign example for any consuming app with an axn async adapter configured — the gem's documented default posture (`mode: :auto` → async when an adapter exists). It blocks the DropboxSign half of the os-app conversion ([PRO-3075](https://linear.app/teamshares/issue/PRO-3075/axn-webhooks-os-app-convert-vendor-webhooks-to-axn-webhooks-codat-merge-lob)): DropboxSign's `ConfirmSignature` handlers make outbound API calls, download a PDF, and upload to S3, and must run async so a transient blip retries via Sidekiq instead of failing DropboxSign's synchronous request.

## Goal

A declaration for a body that never reads the handler result, and therefore renders on **every non-error outcome** — sync success, async enqueue, per-route `async(...)`, `otherwise: :ack`, and business `fail!` — while verify failures (401) and exceptions (500) stay exactly as they are. Declaring it must not force sync dispatch and must not raise alongside `mode: :async`. The existing result-reading `respond` is untouched — it stays the right tool for Twilio TwiML / Slack `response_action`.

## Decision A — new method `static_respond`, not an overload of `respond`

Rejected alternatives and why:

* **Rejected — detect "static" by block arity on `respond` itself** (a zero-param block means static, `|result|` means result-reading). Collapses two genuinely different pipeline contracts — reads-result-and-forces-sync vs. never-reads-and-never-forces-sync — into one method name, keyed off an incidental detail of how the block happens to be written. A copy-pasted `respond { |result| text("literal") }` with an unused `result` param would silently keep the old forced-sync/raise-on-`mode: :async` behavior even though the body is static — the same class of *silent* bug this issue exists to fix, just relocated from the async/otherwise-ack branches to block arity. Also genuinely ambiguous for a splat (`|*|`, arity `-1`).
* **Rejected — `respond(always: true) { ... }`.** Same method name sometimes reads the result and sometimes doesn't, depending on a flag — no more discoverable than arity detection and no smaller a diff than a second method.
* **Rejected — rename existing `respond` to `sync_respond` for symmetry.** Collides with vocabulary this DSL already owns: the per-route `sync(...)`/`async(...)` map-entry helpers and the endpoint-wide `mode: :sync`/`:async`. `sync_respond` sitting next to those reads as another per-route/mode flag, not "reads the result." Also a breaking rename of an already-documented method for no behavioral benefit.
* **Chosen — a distinct method, `static_respond { ... }`.** Two names make the two contracts legible by grep at the declaration site, with no rename of existing, documented API.

## Decision B — the block takes zero arguments; still built from the same `RespondContext` helpers

```ruby
Axn::Webhooks.inbound :dropbox_sign do
  verify { |req| … }
  dispatch to: "Actions::DropboxSign::HandleWebhook"   # stays async under mode: :auto
  static_respond { text("Hello API Event Received") }
end
```

* The block is `instance_exec`'d against `Inbound::RespondContext` with **no arguments** (vs. `respond`'s `instance_exec(handler_result, &block)`) — so `ack`/`text`/`xml`/`json` are available as the same bare calls `respond` already provides, covering the same body kinds (literal string, XML, JSON) with no new helper surface.
* Rejected a bare-value call site (`static_respond "Hello API Event Received"`) — it only covers the plain-string case; XML/JSON would need either new top-level DSL helpers (duplicating `RespondContext`) or a wrapper type. The block form covers all four kinds today for free and keeps the same raise→500 / non-`Response`→500 contract enforcement `respond` already has.
* "Static" is enforced by arity (zero params), not by any restriction on what the block body can call — same freedom `respond`'s block has (e.g. referencing `ENV`, constants).

## Decision C — `respond` and `static_respond` are mutually exclusive, enforced at registration

Declaring both on the same endpoint raises `Axn::Webhooks::Error` at `Axn::Webhooks.inbound` registration time — same style as the existing `mode: :async` + `respond` guard. Each endpoint has exactly one response strategy; no precedence rule to document, implement, or test for a combination with no motivating vendor case.

## Decision D — renders even on a no-`dispatch` endpoint

A verify-only endpoint (no `dispatch` declared) with `static_respond` renders its body instead of today's bare ack — kept consistent with "renders on every non-error outcome" rather than carving out an exception for a case that happens to have no motivating vendor today. Same code path either way (see Implementation).

## Non-goals

* No change to `respond`'s own behavior, its forced-sync default, or its `mode: :async` registration-time raise.
* No change to per-route `async(...)`/`sync(...)` semantics or precedence (extended in [2026-07-18-axn-webhooks-per-route-sync-async-design.md](2026-07-18-axn-webhooks-per-route-sync-async-design.md)) — `static_respond` composes with all of it unchanged, since it never participates in the sync/async decision.
* No change to the 401 (verify failure/crash), 500 (dispatch exception), or 503 (`retry_later!`) mappings.

## Implementation

### New pipeline stage: `Axn::Webhooks::StaticRespond` (`lib/axn/webhooks/static_respond.rb`)

Mirrors `Respond` (`lib/axn/webhooks/respond.rb`) exactly, minus `handler_result`:

```ruby
module Axn
  module Webhooks
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

Built as an Axn for the same reason `Respond` is: a raise inside the user's block (e.g. a typo'd helper name) is reported once via `on_exception` and mapped to a 500, never an unhandled exception escaping the HTTP mapper. Require it from `lib/axn/webhooks.rb` alongside `respond`.

### `Inbound::DSL` (`lib/axn/webhooks/inbound/dsl.rb`)

```ruby
def static_respond(&block)
  @static_respond_block = block
end

def __static_respond__ = @static_respond_block
```

### `Inbound::Endpoint` (`lib/axn/webhooks/inbound/endpoint.rb`)

Constructor takes `static_respond:` and adds the mutual-exclusion guard alongside the existing one:

```ruby
def initialize(name:, verifier:, dispatch: nil, respond: nil, static_respond: nil, challenge: nil)
  if dispatch && dispatch[:mode] == :async && respond
    raise Axn::Webhooks::Error, "…" # unchanged — scoped to `respond` only
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

`response_for` and `to_response` route every bare-ack branch through a new `default_ack`:

```ruby
def to_response(request)
  verified = verify(request)
  return Response.new(status: 401) unless verified.ok?
  return default_ack unless @dispatch          # was: Response.ack

  dispatched = Dispatch.call(...)
  response_for(dispatched)
end

def response_for(dispatched)
  return Response.service_unavailable(retry_after: dispatched.retry_after) if dispatched.retry_later
  return Response.new(status: 500) if dispatched.outcome.exception?
  return default_ack if dispatched.outcome.failure?     # was: Response.ack
  return default_ack if dispatched.handler_result.nil?  # was: Response.ack
  return default_ack unless @respond                    # was: Response.ack

  responded = Respond.call(handler_result: dispatched.handler_result, responder: @respond, vendor: @name)
  responded.ok? ? responded.response : Response.new(status: 500)
end

private

def default_ack
  return Response.ack unless @static_respond

  responded = StaticRespond.call(responder: @static_respond, vendor: @name)
  responded.ok? ? responded.response : Response.new(status: 500)
end
```

401 and the `retry_later`/exception branches at the top of `response_for` are untouched — they run before `default_ack` is ever reached.

### `Axn::Webhooks.inbound` (`lib/axn/webhooks/inbound.rb`)

Pass the new declaration through to `Endpoint.new`:

```ruby
Inbound::Endpoint.new(
  name:,
  verifier: dsl.__verifier__,
  dispatch: dsl.__dispatch__,
  respond: dsl.__respond__,
  static_respond: dsl.__static_respond__,
  challenge: dsl.__challenge__,
)
```

### `Dispatch#async?` (`lib/axn/webhooks/dispatch.rb`)

No change. `respond_declared` stays sourced from `@respond` only (`Endpoint#handle`/`#to_response` already pass `respond_declared: !@respond.nil?`) — `static_respond` never reaches this method and never influences the sync/async decision.

## Testing

New spec `spec/axn/webhooks/inbound/static_respond_spec.rb` (integration, through `Inbound[:vendor].to_response`), plus a `DSL#static_respond` unit spec mirroring `dsl_respond_spec.rb`:

1. **Renders on every non-error outcome**, one per case: sync success (no adapter), async enqueue (`mode: :async` and `mode: :auto` + adapter configured), per-route `async(...)`, `otherwise: :ack` on an unmatched event, and handler business `fail!`.
2. **Does not force sync**: `static_respond` + `mode: :auto` + an adapter configured on the handler → dispatches async (assert via a stubbed `call_async`, same pattern as `async_mode_spec.rb`).
3. **Does not raise** when combined with explicit `mode: :async` (regression-shaped: mirrors the existing "rejects combining explicit mode: :async with a custom respond block" test, asserting the opposite for `static_respond`).
4. **Mutual exclusion**: declaring both `respond` and `static_respond` raises `Axn::Webhooks::Error` at registration.
5. **No-dispatch endpoint**: `verify` + `static_respond`, no `dispatch` → renders the static body instead of a bare ack.
6. **Error containment**: a raise inside the `static_respond` block → reported 500, not an escaping exception (mirrors the existing `respond` raise test); a block returning a non-`Response` → 500 (contract enforcement).
7. **Regression**: existing `respond_spec.rb`/`async_mode_spec.rb`/`dsl_respond_spec.rb` cases stay green unmodified — proof this is additive, not a change to `respond`'s own contract.

## Docs

* README "Respond with a custom body": fix the DropboxSign example to use `static_respond` instead of `respond` (the example is currently wrong for any consuming app with an async adapter configured — the motivating bug for this issue).
* README: add a short subsection introducing `static_respond`, its zero-arg block, and the "renders on every non-error outcome" contract — placed next to the existing `respond` section since they're mutually exclusive siblings.
* README "The staged HTTP outcome mapping" table: note that the "Handle" rows (`otherwise: :ack`, business `fail!`, success-with-no-`respond`) render `static_respond`'s body when declared, instead of always being a bare ack.
* README "Async dispatch": note that `static_respond`, unlike `respond`, never forces sync and is compatible with `mode: :async`.
* CHANGELOG entry under `## [Unreleased]`.

## Related

* Extends: [2026-07-17-axn-webhooks-inbound-design.md](2026-07-17-axn-webhooks-inbound-design.md), "Respond + staged outcome model" and Decision D ("Dispatch mode = async by default; a result-reading `respond` forces sync") — both preserved unchanged for `respond`; `static_respond` is a parallel, non-overriding addition.
* Composes with: [2026-07-18-axn-webhooks-per-route-sync-async-design.md](2026-07-18-axn-webhooks-per-route-sync-async-design.md) — `static_respond` never participates in that precedence ladder.
* Blocks: [PRO-3075](https://linear.app/teamshares/issue/PRO-3075/axn-webhooks-os-app-convert-vendor-webhooks-to-axn-webhooks-codat-merge-lob) (os-app conversion), specifically the DropboxSign endpoints.
