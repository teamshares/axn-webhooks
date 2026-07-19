# axn-webhooks — outbound webhook delivery (design)

> **Companion to** [`2026-07-17-axn-webhooks-inbound-design.md`](./2026-07-17-axn-webhooks-inbound-design.md).
> The inbound half (PRO-2947) is code-complete and merged; this document is the settled design for
> the **outbound** sibling reserved in that spec's Decision 8. Brainstorm settled 2026-07-18.
> Replaces teamshares-rails' `TS::Actions::SendWebhook` / `SendWebhookToSpecificSubscriber`.

## Goal

One reusable primitive for *sending* signed webhooks with delivery best-practices — receipt
confirmation, a self-managed exponential-backoff retry engine, and per-subscriber fan-out — built
on the same `axn` + `Axn::Webhooks::Signature` foundation as the inbound half. It fixes the gaps in
today's teamshares-rails implementation:

* **Silent no-op on unknown events.** `SendWebhook`'s `subscribers_for` returns `[]` for any event
  not in the `WEBHOOK_EVENTS` constant, so a typo'd event name sends nothing and raises nothing.
* **Centralized listener list requires a TSR release.** `WEBHOOK_EVENTS` lives in teamshares-rails,
  so changing *who* receives a hook means cutting a new teamshares-rails version — even though the
  set is, in practice, two events today.
* **No receipt confirmation.** `SendWebhookToSpecificSubscriber` POSTs and ignores the response;
  a 5xx or a timeout is indistinguishable from success.
* **No retry/backoff.** A failed delivery is simply lost.
* **Non-standard signing.** It signs the whole body with `ActiveSupport::MessageVerifier`
  (a Rails-only signed blob sent as `text/plain`), rather than a standard signature-header scheme
  symmetric with what the inbound half verifies.

## Scope

**This repo builds the library only.** It ships `Axn::Webhooks::Outbound` (the delivery engine +
declaration DSL) reusing the existing shared `Axn::Webhooks::Signature`. Migrating teamshares-rails
off `TS::Actions::SendWebhook` / `SendWebhookToSpecificSubscriber` — and **deleting `WEBHOOK_EVENTS`**
— is separate consuming-app work (its own ticket), exactly as the inbound half's per-vendor
migration lands in os-app/buyout, not here. Proven by the gem's own standalone test suite (no Rails
required), same as inbound.

**Routing model = sender-owned config (built now), DB-backed store deferred.** The general public-gem
case is a persisted subscription store where receivers self-register endpoints at runtime (no deploy
to change listeners). We are **not** building that now: it would require a migration + record-keeping
in every sending app for what is two events today. Instead we build sender-owned declaration (the
event→targets map moves out of teamshares-rails into each *sending* app's initializer) and keep a
**resolver seam** (`subscribers` / `to:` accept a lambda) so the DB store drops in later with no API
change. **The README states plainly that the full self-registration shape is intentionally deferred
until a real use-case exists.**

## Design

### 1. Public API — central `outbound` block + `emit`, symbol-keyed, loud on typos

Declaration and emission mirror the inbound half's registration ergonomics:

```ruby
# config/initializers/webhooks.rb in the SENDING app
Axn::Webhooks.outbound do
  # Our own emitted hooks use Standard Webhooks (spec Decision 1/8: recommended for first-party hooks).
  sign :standard_webhooks, secret: ENV.fetch("TEAMSHARES_INTERNAL_WEBHOOK_SECRET")

  # Default subscriber resolver — the seam a future DB-backed subscription store slots into.
  # Sugar: an event declared with no explicit `to:` falls back to this.
  subscribers ->(event) { Subscription.urls_for(event) }

  event :lead_signed, to: [TS::KnownApplication[:os].root_url("/webhooks/buyout/lead_signed")]
  event :lead_closed   # no `to:` → resolved via the default `subscribers` resolver
end

# emit site (was TS::Actions::SendWebhook.call_async(event:, payload:))
Axn::Webhooks.emit(:lead_signed, data: { lead_id: 42 })
```

* **Symbols are the identity.** `emit(:unknown_event)` raises `Axn::Webhooks::Error` immediately,
  listing the known events — the concrete fix for today's silent `subscribers_for → []`. A statically
  declared `event :x, to: []` warns at boot.
* **Wire `type`** defaults to the symbol as a string (`"lead_signed"`), overridable per event with
  `type:` when a dotted convention or an existing consumer's expected value is required
  (`event :lead_signed, type: "lead.signed", to: [...]`).
* **`to:`** accepts a static array **or a lambda** (`->(event) { … }`); the block-level `subscribers`
  resolver is the shared default. Both are the DB seam.
* **`sign`** reuses `Axn::Webhooks::Signature` — the same primitive the inbound `verify :standard_webhooks`
  strategy is built on. A custom signer block is accepted in the same slot for non-SW receivers.

### 2. Envelope & signing — Standard Webhooks

The body is the Standard Webhooks envelope; `id` and `timestamp` are mirrored into the signed headers
via the shared `Signature`:

```
POST <subscriber-url>
webhook-id: msg_<uuid>
webhook-timestamp: 1721160000
webhook-signature: v1,<base64 hmac of "id.timestamp.body">
Content-Type: application/json
User-Agent: axn-webhooks/<version> (<app>)

{"id":"msg_<uuid>","timestamp":1721160000,"type":"lead_signed","data":{"lead_id":42}}
```

* Receivers verify with the inbound half's `verify :standard_webhooks` — end-to-end symmetry, and
  `id`/`timestamp` give idempotency + replay protection for free.
* `data:` is stringified for async serialization (as `SendWebhook.call_async` does today for Sidekiq
  compatibility).

### 3. Fan-out & async posture

* `emit` resolves the event's subscribers, then enqueues **one `Axn::Webhooks::Outbound::Deliver`
  axn per target** via `call_async` — each delivery is independent, so one slow/failing subscriber
  can't block another (matching today's per-subscriber shape, but as first-class retryable units).
* **`webhook-id` is generated once per (emission × target)** and **reused across every retry attempt
  of that delivery**, so receivers can dedup. This is the idempotency guarantee that makes
  at-least-once delivery safe.
* **Async posture mirrors inbound's `:auto`:** async when an axn async adapter is configured (the
  presence check, never a type branch — see [[axn-webhooks-async-design]]), else a **synchronous
  inline fallback** so the gem works standalone without Sidekiq. The sync path is best-effort: no
  cross-process retries/backoff, and it **emits a warning** (routed through the axn soft-error helper
  — see Dependencies) so the degraded mode is never silent.

### 4. Delivery contract — receipt confirmation + self-managed retry engine

Each `Deliver` attempt classifies the receiver's response. This table is the **canonical delivery
contract**, documented in the README so single-side (non-gem) consumers can implement either half.

| Receiver responds | Delivery does |
| -- | -- |
| **2xx** | success |
| **5xx, 429, 503 + `Retry-After`, timeout, connection error** | retryable → self-reschedule the next attempt |
| **other 4xx** (400, 401/403 bad-sig/auth, 404, 410 Gone, 422) | permanent → quiet `fail!`, reported once, no retry |
| **unexpected exception** (crash / OOM / network raise mid-flight) | propagates → adapter retries the un-acked job (at-least-once safety net) |

**Self-managed retry engine (one engine, adapter-agnostic).** On a retryable response, `Deliver`
computes its own delay and re-enqueues itself via axn's adapter-agnostic delayed-enqueue seam
(`call_async(_async: { wait: delay })`, carrying `attempt: n+1`), rather than raising and inheriting
the adapter's default backoff curve. Rationale:

* **We own the decay algorithm**, independent of e.g. Sidekiq's default (~25 tries over ~21 days,
  tuned for generic job failures — the wrong shape for webhook delivery, which wants a deliberate
  tail). Identical behavior across every axn adapter.
* **`Retry-After` is honored precisely:** `delay = max(backoff(attempt), retry_after_seconds)`.
* After `max_attempts`, report once (`on_exception`) + a structured "delivery exhausted" log/metric,
  then stop (no re-enqueue).

```ruby
Axn::Webhooks.outbound do
  # …
  max_attempts 8
  backoff ->(attempt) { [30 * (3**(attempt - 1)), 6.hours].min }   # + jitter; defaults shown
end
```

**At-least-once is preserved for crashes:** response-based retries are self-managed, but an
*unexpected* exception still propagates so the adapter retries the un-acked job as a safety net.
Because every attempt reuses the same `webhook-id`, a double-delivery from that safety net is
idempotent on the receiver side. (A successful re-enqueue returns normally, so the job is acked and
the adapter does **not** also retry — no double-counting.)

**Inbound-side symmetry.** The inbound half's staged outcome model already emits sender-meaningful
codes: verify mismatch → 401 (permanent), handler business `fail!` → 2xx (delivered), missing
handler / handler crash → 5xx (retryable "deploy-grace" window). This design adds one small inbound
affordance so a receiver can request redelivery *without* paging — a `retry_later!`-style hook
mapping to **503 + `Retry-After`** (distinct from a crash, which is a reported 5xx). Handlers get the
"without paging" half by including `Axn::Webhooks::Handler` (or a manual
`fails_on Axn::Webhooks::RetryLater`) so the deferral settles as a quiet failure instead of an
unhandled exception reported to `on_exception`. This inbound addition is **in scope for this
ticket**; the outbound engine honors 503 regardless of who produced it.

### 5. Observability

`Deliver` (and the `emit` fan-out) are Axns, so per-attempt metrics / OTel spans / structured logs +
`on_exception`-on-exhaustion come free — no hand-rolled `Honeybadger.notify` in the gem. The
`vendor_facet` setting (already shipped for inbound) extends naturally to stamp the event and/or
subscriber onto outbound pipeline calls for per-event/-subscriber grouping in Datadog (ties to
PRO-2818).

## Decisions

1. **Routing = sender-owned config now; DB-backed subscription store deferred** behind a `subscribers`/`to:`
   lambda resolver seam. README documents the deferral explicitly.
2. **Signing = `:standard_webhooks`** via the shared `Axn::Webhooks::Signature`; a custom signer block
   is accepted for non-SW receivers. Receivers migrate off `ActiveSupport::MessageVerifier` to the
   inbound `verify :standard_webhooks` (separate consuming-app work).
3. **API = central `Axn::Webhooks.outbound do … end` block + `Axn::Webhooks.emit(:event, data:)`**,
   symbol-keyed. Unknown event → immediate loud `Axn::Webhooks::Error`. Wire `type` defaults to the
   symbol string, `type:` overrides.
4. **Fan-out = one `Deliver` axn per target via `call_async`**; `webhook-id` generated once per
   (emission × target), stable across that delivery's retries.
5. **Retry = one self-managed engine** using axn's adapter-agnostic `_async: { wait: }` seam;
   `delay = max(backoff(attempt), Retry-After)`; own configurable decay curve; exhaustion reported
   once. Unexpected exceptions fall through to the adapter as an at-least-once safety net.
6. **Async posture = `:auto`** (async when an adapter is configured, else a **warned** best-effort
   sync fallback), never branching on adapter type — consistent with [[axn-webhooks-async-design]].
7. **Internals built as Axns** → `on_exception`/Honeybadger, metrics, OTel, structured logs for free;
   `vendor_facet` extends to outbound.
8. **Namespace** = `Axn::Webhooks::Outbound` (delivery engine + DSL), `Axn::Webhooks.outbound` /
   `Axn::Webhooks.emit` (registration + emission), reusing the shared `Axn::Webhooks::Signature`.

## Dependencies & follow-ups (separate tickets)

* **axn-core: promote the dev-loud/prod-quiet soft-error helper.** axn's
  `Axn::Internal::PipingError.swallow` (raises in dev when `Axn.config.raise_piping_errors_in_dev`,
  logs otherwise) is exactly the discipline outbound wants for its best-effort paths (subscriber
  resolution, `Retry-After` parsing, the sync-fallback warning), but it lives under `Axn::Internal::`
  ("don't depend on this"). Promote it to a **less-internal-but-not-user-facing** module
  (`Axn::<name>`, naming TBD with the axn maintainer) reusing the existing `raise_piping_errors_in_dev`
  knob, and update all downstream sibling-gem consumers (axn-webhooks, axn-mcp, axn-ruby_llm). While
  that's pending, axn-webhooks uses a trivial local shim so it is never blocked. **Also audit the
  `Axn::` top-level namespaces** — each new sibling gem adds one, so this ticket reconciles them to
  avoid conflicts. *(Own ticket, created after this spec.)*
* **Consuming-app migration.** Rewire teamshares-rails' `send_webhook` onto `Axn::Webhooks::Outbound`,
  move the event→listeners map into the sending app(s), and delete `WEBHOOK_EVENTS`. Migrate receivers
  to `verify :standard_webhooks`. *(Own ticket, like inbound's per-vendor migration.)*

## Open questions

None blocking — ready for an implementation plan. (Confirm during build: the wire-`type` default
symbol-string vs. dotted.)

## Related

* Sibling: the **inbound** half (PRO-2947, code-complete) — shares `Axn::Webhooks::Signature` and the
  `vendor_facet` setting; its staged outcome codes are the receiver side of §4's delivery contract.
* [[axn-webhooks-async-design]] — the never-branch-on-adapter async principle this reuses.
* [[axn-webhooks-inbound-complete]] — remaining inbound work (release + adoption).
* Observability: PRO-2818 (Datadog) — outbound Axn metrics/OTel + `vendor_facet` feed it.
