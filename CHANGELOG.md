# Changelog

All notable changes to this project are documented here. This project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

_Nothing yet._

## [0.1.0] - 2026-08-24

_Prepared, not yet tagged — the version is cut immediately on merge. Update this date if that slips._

Initial release. Webhook handling for [axn](https://github.com/teamshares/axn) in both directions,
built on one shared signature primitive, and usable in or out of Rails.

Everything below is new in this release; the pre-release iteration that produced it is in the git
history rather than here.

### Requirements

- Ruby >= 3.2.1, `axn` >= 0.1.0-alpha.5, `rack` >= 3.0 (< 4).
- Rack 3 is required (`Response` uses lowercased header names and Rack 3's native Array multi-value
  headers). Under Rails, `axn`'s own `activesupport >= 7.2` floor makes the effective minimum
  **Rails 7.2+**.

### Signature primitive

- `Axn::Webhooks::Signature` — a standalone, Rails-agnostic HMAC verifier. `sha256`/`sha1`/`md5`
  digests; `hex`/`base64`/`base64_urlsafe` encodings; prefix stripping; multi-candidate
  (key-rotation) signature headers; always constant-time.
- Replay protection via `timestamp:`/`tolerance:` — a bidirectional window accepting an epoch
  Integer/String or a `Time`.
- `unit:` (default `:auto`) infers a timestamp's scale from its magnitude, so vendors that send epoch
  seconds, milliseconds, or microseconds — sometimes more than one, as Lob does — need no
  configuration. Pin `:seconds`/`:ms`/`:microseconds` to make a change in what a vendor sends fail
  loudly instead of being absorbed.
- `hmac` answers *whether* a request verified; `hmac_check` answers *why* it didn't, returning a
  `Signature::Check` (`ok?`, `reason`, `skew`, `suggested_unit`). `Signature.mismatched_unit` answers
  the "would another scale have fit?" question on its own, side-effect-free.
- Exported verdicts for custom verifiers: `OK`, `MISMATCH`, `SIGNATURE_MISSING`,
  `CREDENTIALS_MISSING`, `CREDENTIALS_MISMATCH`.

### Inbound

- `Axn::Webhooks.inbound(:vendor) { … }` declares an endpoint; `Axn::Webhooks::Inbound[:vendor]`
  looks it up. Endpoints are declared once (e.g. a Rails initializer) and registered process-globally.
- **Verification strategies:** `verify :hmac` (parametric — digest, encoding, prefix, custom signing
  string, replay window), `verify :standard_webhooks` (the Standard Webhooks / Svix scheme, removing
  any need for the `svix` gem), `verify :basic_auth` (owning the full two-legged handshake, including
  the `WWW-Authenticate` challenge that clients like Twilio require), or a custom `verify` block.
  `verify` is mandatory whenever `dispatch` is declared.
- A **custom `verify` block's return value is duck-typed on `#ok?`** — any object reporting its own
  verdict (a `Signature::Check`, an `Axn::Result`) is asked for it; any other truthy value means
  verified; `nil`/`false` mean rejected. A literal `whsec_` secret is validated at declaration.
- **Verification failures name their cause** on the result and as a bounded `reason` metrics
  dimension: `:replay_window` (carrying `skew` and `suggested_unit`), `:replay_timestamp_invalid`,
  `:signature_missing`, `:signature_mismatch`, `:credentials_missing`, `:credentials_mismatch`.
- **`dispatch`** routes a verified, parsed event to a handler Axn — a single `to:`, an explicit
  `on:` + map, or name-from-key convention (with an optional `via:` transform). Targets may be a
  class-name String or the class itself, both resolved lazily per request (reload-safe under
  Zeitwerk). A map entry's `with:` renames or projects the handler's arguments; `otherwise:` takes
  `:ack` or a callable for unmatched keys.
- **`respond`** renders a body from the handler's own result (TwiML, a JSON instruction body);
  **`static_respond`** renders a fixed body that doesn't read the result, and so stays compatible
  with async dispatch. The two are mutually exclusive.
- **Staged HTTP outcome mapping** (`#to_response`): verify rejection or verifier crash → 401;
  missing/unmatched handler or handler crash → 500 (reported once); unparseable body →
  `unparseable_status` (default **200**, since 2xx is the only answer every vendor reads as "stop
  redelivering"); `otherwise: :ack` and a handler's business `fail!` → 2xx ack; success → the declared
  response body.
- **Async dispatch** — `mode: :auto` (default) runs async when the handler has an axn async adapter
  configured and sync otherwise; `:async`/`:sync` pin it. A dispatch-map entry's `async:` flag, with
  `async(…)`/`sync(…)` sugar, overrides per route — the interaction-platform pattern (Slack, Discord)
  where one URL needs both disciplines. This gem never branches on adapter type.
- **Nested endpoints** — an `inbound` block may contain `endpoint(name) { … }` blocks that inherit
  the parent's `verify`/`challenge`/`respond`/`unauthorized_headers` and register as
  `:"#{parent}_#{child}"`. One level deep.
- **`challenge`** — the GET-echo handshake (Nylas, Meta), with an optional `if:` guard, taught to the
  same mount. `challenge_required` declares the bare-first-leg predicate for a custom verifier.
- **Rack mounting** — `Inbound[:vendor]` is itself a Rack app: `mount … at:` in Rails routes, or
  `map(…) { run … }` in a `config.ru`. No controller needed.
- **`Axn::Webhooks::Request`** — a Rails-agnostic view of the request (`raw_body`, `header`, `params`,
  `url`, `http_method`), built from a Rack env or constructed directly in tests. Captures pristine
  body bytes, parses form-urlencoded and multipart bodies, and redacts `raw_body`/headers from
  `inspect`/`pp` so payloads never reach logs or exception reports.
- **`retry_later!`** — `Axn::Webhooks.retry_later!(after:)` from a handler (or a `parse:` proc, or a
  `with:` extractor) maps to a 503 with an optional `Retry-After`, asking the sender to redeliver.
  `include Axn::Webhooks::Handler` in place of `include Axn` declares the `fails_on` that keeps a
  deferral from paging on every occurrence.

### Outbound

- `Axn::Webhooks.outbound { … }` declares events, subscribers, signing, and delivery policy once;
  `Axn::Webhooks.emit(:event, data:)` fans out from wherever the triggering event happens. An unknown
  event symbol raises immediately, listing the known ones.
- **Standard Webhooks envelope** — `{id, timestamp, type, data}` with `webhook-id`/`webhook-timestamp`
  /`webhook-signature` headers, so a receiver's own `verify :standard_webhooks` accepts it. Signing
  happens **per attempt** (fresh timestamp, stable `webhook-id`) so retries land inside the receiver's
  replay window while staying dedupable.
- **`sign :hmac`** — a parametric outbound preset mirroring `verify :hmac`, for receivers that expect
  a plain signature header. `digest:`/`encoding:`/`prefix:`/`signing_string:` (a `{timestamp}`/`{body}`
  template) and both header names are validated at declaration.
- **Subscriber resolution** — a per-event `to:` (static Array or lambda) or a block-level
  `subscribers` resolver, both re-resolved on every `emit`. A row may be a bare URL String or a
  `{ url:, id: }` Hash carrying a subscriber identity that `sign`'s `secret:` and the `headers`
  resolver can key off of.
- **Credentials stay out of the queue.** `Deliver` carries only a subscriber's *identity*; the signing
  secret and per-destination `headers` are re-resolved from it on every attempt, never serialized into
  the job payload for the life of the retry chain.
- **Target policy** — `allowed_hosts` (exact or `*.` wildcard, case-insensitive) and `allow_url` (the
  parsed `URI`, for real IP-range logic). A static `to:` is checked at boot; a resolver's rows are
  checked at every `emit` and collected into `rejected`/`rejected_count` rather than failing the fan-out.
- **Self-managed, adapter-agnostic retries.** `Deliver` computes its own backoff and re-enqueues
  itself via axn's delayed-enqueue seam, so retry behavior is identical across adapters. 2xx succeeds;
  408/425/429/5xx/timeouts reschedule (honoring `Retry-After`, including its HTTP-date form); other
  4xx is a permanent quiet `fail!` carrying a truncated copy of the response body; an unexpected
  exception propagates so the adapter's at-least-once safety net applies. `max_attempts` defaults to
  8, and the default backoff curve applies equal jitter and caps at 6h. Exhaustion reports once and
  then stops.
- **`emit`'s result** exposes `webhook_ids`, `target_count` (rows actually enqueued), `deliveries`
  (one `{ webhook_id:, url:, subscriber_id: }` per target, for persisting delivery records without
  re-resolving), `rejected`/`rejected_count`, and `failed_count` (sync path only).
- **Per-call overrides** — `emit(…, to:)` replaces the event's targets for one call (validated
  identically, raising on a bad URL); `emit(…, async:)` pins the dispatch path.
- **Injectable transport** — `.post(url:, body:, headers:) -> Transport::Response`, defaulting to
  stdlib `net/http` so the gem adds no HTTP dependency. `timeouts open:`/`read:` (5s/10s) configure
  the built-in one.
- **Boot-time validation** of the whole `outbound` block: `max_attempts`, `backoff` arity, `to:` shape
  and static entries, `allowed_hosts`, `allow_url`/`headers` arity, every `sign :hmac` option, and a
  literal `sign :standard_webhooks` secret's `whsec_<base64>` format.

### Shared

- `Axn::Webhooks.config.vendor_facet` (`false` by default; `:dimension` or `:tag`) stamps the
  registered vendor name onto every verify/dispatch/respond/challenge call, and onto outbound
  deliveries via `vendor`. A resolved `subscriber_id` is always stamped as a tag, never a dimension.
- `Axn::Webhooks::Error` includes `Axn::Error`, so a consuming app's existing axn error handling
  covers this gem. `Axn::Webhooks.deprecator` is a dedicated `ActiveSupport::Deprecation` instance a
  Rails app can register and govern.
- `Axn::Webhooks::Inbound.reset!` / `Outbound.reset!` clear the process-global registries for tests.
- The packaged gem ships an allowlist of paths (`lib/`, `README.md`, `DESIGN-NOTES.md`,
  `CHANGELOG.md`, `LICENSE.txt`), so development artifacts never leak into the release.
