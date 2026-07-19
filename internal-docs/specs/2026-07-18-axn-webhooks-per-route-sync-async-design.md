# axn-webhooks — per-route sync/async on one endpoint (design)

> **Source:** [PRO-2952 — [axn-webhooks] Per-route sync/async on one endpoint (interaction-platform response pattern)](https://linear.app/teamshares/issue/PRO-2952/axn-webhooks-per-route-syncasync-on-one-endpoint-interaction-platform). Brainstorm settled 2026-07-18. Extends the inbound design ([2026-07-17-axn-webhooks-inbound-design.md](2026-07-17-axn-webhooks-inbound-design.md)) — specifically **Decision D / "Sync vs async"** — to a new class of endpoint.

## Why

`axn-webhooks` today decides sync-vs-async **per endpoint**: a declared `respond` forces the *whole* endpoint sync (`Dispatch#async?` → `return false if respond_declared`), and `Endpoint#initialize` boot-rejects endpoint-wide `mode: :async` combined with `respond`. That is **Decision D**, and it is correct for the original vendor sample (Codat, Merge, Lob, ModernTreasury, DropboxSign, Nylas, Twilio): those are event-notification hooks and are **splittable** — where a vendor needs both disciplines (e.g. Twilio), you configure separate URLs per number/action, so a per-endpoint decision suffices.

**New evidence the original sample didn't contain: the interaction-platform class multiplexes both disciplines on one *fixed* URL you can't split**, with a per-*message* choice between a synchronous body and ack-then-async:

* **Slack** — one Interactivity Request URL: `view_submission` → sync `response_action` JSON; `block_actions` → ack + async.
* **Discord** — one Interactions Endpoint URL: PING → sync PONG (type 1); command → sync (type 4) or deferred-ACK (type 5) + async follow-up.
* **Telegram** — one `setWebhook` URL: per-update choice to reply inline (method-in-body) or ack + separate API call.
* **Microsoft Teams / Bot Framework** share the shape.

So per-route multiplex is a recurring, named pattern — not a Slack one-off. Immediate driver: the Slack interactivity rewrite ([PRO-2939](https://linear.app/teamshares/issue/PRO-2939/axn-slack-interactivity-adapter-block-kit-ui-axn-dispatch)).

## Goal

Make sync-vs-async a **per-resolved-route** decision instead of an endpoint-wide override, so **one** endpoint under **one** `respond` block can host a mix of async-ack routes and sync-body routes. Do this by **extending** Decision D (keeping it as the default), not reversing it.

## Decision A — `respond` stays the sync *default*; a per-route boolean opts out

This is the reconciliation with Decision D. Two rejected framings and why:

* **Rejected — "respond stops influencing mode; each route falls back to its handler's async adapter."** This is the issue's literal shorthand, but under a global async-adapter default (the common Rails setup, `Axn.config._default_async_adapter = :sidekiq`) an *unannotated* sync route silently goes async and its response body vanishes — a silent failure. It would also reverse, not extend, Decision D, forcing rewrites of the `dispatch_async_spec` / `async_mode_spec` "respond forces sync" tests.
* **Chosen — respond ⇒ sync default, per-route opt-out.** A declared `respond` keeps making `:sync` the **per-route default** (Decision D intact); a per-route flag opts individual routes out to async-ack. A forgotten annotation fails *loud* — the route simply stays sync and `respond` doesn't fire on it — never silent. Every existing Decision-D test stays green; this is a pure extension.

## Decision B — per-entry `async:` boolean, not a `mode:` trilean

The per-route knob is a **boolean `async:`** on a dispatch-map Hash entry, not a repeat of the endpoint-wide `mode:` trilean.

* A route's sync/async-ness on these platforms is **protocol-fixed**, not deployment-dependent: `view_submission` *must* return a synchronous `response_action`; `block_actions` *must* ack-then-async. The decision domain is genuinely binary, so a boolean expresses exactly it.
* `mode:` at entry level would give four states `{absent, :sync, :async, :auto}` where `:auto` and `absent` are nearly redundant and `:auto` ("decide this one route by adapter presence") has no natural protocol behind it. `async:` gives three unambiguous states:
  * **absent** → no opinion; fall through to the endpoint/respond default (Decision D untouched)
  * **`async: true`** → this route acks + runs async (no `handler_result`)
  * **`async: false`** → this route runs sync so `respond` can render its body
* The **endpoint-wide `mode:` stays a trilean** (`:auto`/`:sync`/`:async`) — at endpoint scope, `:auto` ("async iff an adapter is configured") is the genuine shipped default and is untouched. Endpoint `mode:` = policy default; entry `async:` = a specific protocol-fixed carve-out. Different scopes, deliberately different shapes.

## API

```ruby
Axn::Webhooks.inbound :slack do
  verify :hmac, secret: ENV.fetch("SLACK_SIGNING_SECRET"), signing_string: ->(r){ "v0:#{...}" }

  dispatch on: ->(e){ e[:type] },
    to: {
      # absent async: -> respond default -> SYNC. Returns a result; respond renders it.
      "view_submission" => "Slack::HandleViewSubmission",

      # async: true -> acks immediately, runs on the configured adapter. No handler_result.
      "block_actions"   => { call: "Slack::HandleBlockActions", async: true },
    }

  respond { |result| json(result.response) } # sync route renders JSON; async route auto-acks (bare 2xx)
end
```

* Only **Hash** map entries can carry `async:` (alongside the existing `:call`/`:with`). A bare String entry (`"Slack::HandleViewSubmission"`) carries no opinion and falls through to the default.
* Single-route `dispatch to: "Handler"` and convention-namespace `dispatch to: "Namespace", on: …, via: …` have no per-entry knob — they use the endpoint-wide `mode:` / default exactly as today.
* `json(...)` is the sync body helper from the paired ticket ([PRO-2951](https://linear.app/teamshares/issue/PRO-2951/axn-webhooks-json-response-bodies-for-inbound-respond-responsejson)); this ticket does not depend on it landing first (any existing `respond` helper — `text`/`xml` — exercises the same path).

## Precedence ladder (per resolved route)

Computed inside `Dispatch`, most-specific wins:

1. **Entry `async:`** (if the resolved map entry sets it) → `true` = async, `false` = sync.
2. **Endpoint-wide `mode:`** (the `dispatch mode:` arg) → if explicitly `:sync` or `:async`.
3. **`respond` declared → sync** (Decision D preserved as the default).
4. **Else `:auto`** → async iff an async adapter is configured for *this* resolved handler (unchanged detection logic).

Today's blanket `return false if respond_declared` in `Dispatch#async?` becomes **step 3** of this ladder rather than an early hard override.

## Implementation

### `Router` (`lib/axn/webhooks/inbound/router.rb`)

* `#resolve(event)` returns **`[handler_class, args, route_async]`** for a matched route (was `[handler_class, args]`); `:ack` stays `:ack`. `route_async` is `true`/`false` when the entry sets `async:`, else `nil` (no opinion).
* `#handler_for` reads `:async` off a Hash entry (next to `:call`/`:with`). A String entry yields `route_async = nil`.
* **Validation:** a non-boolean `async:` on an entry raises `Axn::Webhooks::Error` at resolve time (same loud-miss discipline as an unknown endpoint `mode:`). (`nil`/absent is the legitimate "no opinion" state and does not raise.)

### `Dispatch` (`lib/axn/webhooks/dispatch.rb`)

* Unpack the third element: `handler_class, args, route_async = resolution`.
* Replace `async?(handler_class)` with the precedence ladder above:
  * `route_async` non-nil → return it directly.
  * else endpoint `mode == :async` → true; `mode == :sync` → false.
  * else `respond_declared` → false (sync).
  * else → `async_adapter_configured?(handler_class)`.
* The existing async-with-no-adapter guard in `dispatch_async` is **reused verbatim**: a route with `async: true` whose handler has no adapter still settles as a clean reported `Axn::Webhooks::Error` (not an escaping `NotImplementedError`).

### `Endpoint#initialize` guard stays (`lib/axn/webhooks/inbound/endpoint.rb`)

Endpoint-wide `mode: :async` + `respond` remains a **boot error** — if *every* route is async, `respond` can only ever ack, so the declaration is genuinely contradictory. Per-entry `async: true` lives *inside* the map and never trips this guard, so a mixed endpoint (endpoint `mode: :auto` + `respond` + some `async: true` entries) is allowed. No change to this method.

### Response mapping already correct (`Endpoint#response_for`)

No change needed. An async route produces `handler_result == nil` → `Response.ack`; a sync route produces a result → the `respond` block runs. The mixed endpoint simply exercises both existing branches under one endpoint.

### DSL (`lib/axn/webhooks/inbound/dsl.rb`)

No signature change to `dispatch`. `async:` is data *inside* the `to:` map, interpreted by `Router`; the DSL passes the map through unchanged.

## Testing

New spec `spec/axn/webhooks/inbound/per_route_async_spec.rb` (integration, through `Inbound[:vendor].to_response`) plus `Router`/`Dispatch` unit coverage:

1. **Mixed endpoint under one `respond`:** an `async: true` route acks (bare 2xx, enqueues via `call_async`, no body) **and** a sync route renders the `respond` body — asserted on the same endpoint, two requests.
2. **Precedence:** entry `async: true` overrides an endpoint-wide `mode: :sync` (route goes async); entry `async: false` overrides an endpoint-wide `mode: :async` (route goes sync); entry `async: true` overrides the respond→sync default (route goes async).
3. **Validation:** a non-boolean `async:` entry raises `Axn::Webhooks::Error`.
4. **Adapter guard:** `async: true` on an adapter-less handler → reported `Axn::Webhooks::Error` (500-bound), not an escaping exception.
5. **`Router#resolve` shape:** returns the 3-tuple with `route_async` nil for String entries and Hash entries without `async:`.
6. **Regression:** the named Decision-D tests (`dispatch_async_spec` "forces SYNC when respond_declared is true"; `async_mode_spec` "a custom respond runs sync so respond can read the result") stay green **unmodified** — the proof this extends rather than reverses Decision D.

## Non-goals / out of scope

* No change to the endpoint-wide `mode:` trilean or its `:auto` adapter detection.
* No `json()` helper work — that is [PRO-2951](https://linear.app/teamshares/issue/PRO-2951/axn-webhooks-json-response-bodies-for-inbound-respond-responsejson); this ticket is mode-routing only.
* No Slack adapter itself — that is [PRO-2939](https://linear.app/teamshares/issue/PRO-2939/axn-slack-interactivity-adapter-block-kit-ui-axn-dispatch), the consumer that motivates this.

## Related

* Extends: [2026-07-17-axn-webhooks-inbound-design.md](2026-07-17-axn-webhooks-inbound-design.md), Decision D ("Dispatch mode = async by default; a result-reading `respond` forces sync").
* Pairs with: [PRO-2951](https://linear.app/teamshares/issue/PRO-2951/axn-webhooks-json-response-bodies-for-inbound-respond-responsejson) (`json()` response bodies) to fully express Slack's single interactivity endpoint.
* Motivating consumer: [PRO-2939](https://linear.app/teamshares/issue/PRO-2939/axn-slack-interactivity-adapter-block-kit-ui-axn-dispatch) (Slack interactivity adapter).
