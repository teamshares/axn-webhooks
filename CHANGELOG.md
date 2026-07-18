# Changelog

## [Unreleased]

### Added
- `Axn::Webhooks.emit(event, data: {}) → Axn::Result` and its backing `Axn::Webhooks::Outbound::Emit` axn — the outbound fan-out entrypoint. Validates the event via `Outbound.config` (`#wire_type`/`#targets_for`, raising `Axn::Webhooks::Error` loudly on an unknown event), then per resolved target generates a fresh `Envelope.new_id`, builds the envelope body, and enqueues one `Outbound::Deliver`. Delivery goes async via `Deliver.call_async` when an async adapter is configured (per-`Deliver` setting, else the global default — the same presence-check pattern as inbound `Dispatch`, never branching on adapter type); otherwise it falls back to a synchronous inline `Deliver.call` with a `Axn.config.logger.warn` (best-effort, no cross-process retries).
- `Axn::Webhooks::Outbound::Deliver` — the per-attempt delivery axn and self-managed retry engine: signs each attempt with a fresh timestamp (reusing the stable `webhook_id`) via `Outbound.config.signer`, POSTs via `Outbound.config.transport`, and classifies the response — 2xx succeeds; a permanent 4xx `fail!`s quietly (no reschedule); a 5xx/429/retryable network error (`Transport::RETRYABLE_NETWORK_ERRORS`) reschedules itself via `call_async(..., attempt: attempt + 1, _async: { wait: })` where `wait` is `max(backoff(attempt), Retry-After)`; exhaustion (`attempt >= max_attempts`) reports once via `Axn.config.on_exception` (never raises, so the async adapter doesn't re-retry an already-exhausted job) then `fail!`s. Only `expects :url, :webhook_id, :body, :event, :attempt` — secret/curve/transport are read from `Outbound.config` at call time so nothing sensitive rides the job payload. An unexpected (non-network) exception is left unrescued and surfaces as a loud axn exception, the async adapter's at-least-once crash safety net.
- `Axn::Webhooks.outbound { … }` — the declaration surface: evaluates the block in `Outbound::DSL` (`sign`, `subscribers`, `max_attempts`, `backoff`, `transport`, `event name, to:, type:`) and installs a single process-global `Outbound::Config`. `Axn::Webhooks::Outbound.config` returns it (raising `Axn::Webhooks::Error` if `outbound` was never declared); `.reset!` clears it (for tests). `Config#targets_for(event)` resolves a static `to:` Array, else the block-level `subscribers` resolver, else `[]` — and raises `Axn::Webhooks::Error` listing known events for an unknown one; `#wire_type(event)` is the per-event `type:` override or the event name; `#max_attempts`/`#backoff` default to 8 attempts and a capped exponential curve; a statically empty `to: []` warns (not raises) at boot. `lib/axn/webhooks/outbound.rb` is now the umbrella requiring the Signer/Envelope/Transport/Config/DSL files.
- `Axn::Webhooks.swallow_soft_error(desc, exception:)` — local stand-in for a future promoted axn-core helper: logs a swallowed exception via `Axn.config.logger.warn`, but re-raises in development when `Axn.config.raise_piping_errors_in_dev` is set.
- `Axn::Webhooks::Outbound::Transport` — the injectable HTTP seam: `.post(url:, body:, headers:, open_timeout: 5, read_timeout: 10) → Transport::Response` (`Data.define(:status, :headers)`), backed by stdlib `net/http` so the gem gains no new runtime dependency. `RETRYABLE_NETWORK_ERRORS` names the exception classes callers treat as retryable when raised by a transport (`Timeout::Error`, connection/DNS/IO errors); a consuming app may inject its own object with the same `.post` signature (e.g. Faraday-backed) via Outbound config.
- `Axn::Webhooks::Outbound::Envelope` — builds the Standard Webhooks message body (`.build(id:, type:, data:, now:) → String`, a `{id,timestamp,type,data}` JSON string) and its idempotency id (`.new_id → "msg_<uuid>"`). Deliberately decoupled from signing: the body is fixed at emit time (part of the dedup identity), while the signature is recomputed per delivery attempt.
- `Axn::Webhooks::Outbound::Signer` — builds a `#call(id:, timestamp:, body:) → Hash` signer from a `sign` declaration. The `:standard_webhooks` strategy is the outbound face of the inbound `verify :standard_webhooks` (same `whsec_` secret, `id.timestamp.body` HMAC, `v1,<base64>` signature), so a receiver already verifying Standard Webhooks accepts it; a custom block is called verbatim and must return the header hash itself.
- `Axn::Webhooks::Inbound::Endpoint#call(env)` — `Inbound[:vendor]` is now directly a Rack app:
  `mount Axn::Webhooks::Inbound[:vendor], at: "/webhooks/vendor"` in Rails, or
  `run Axn::Webhooks::Inbound[:vendor]` in a bare `Rack::Builder`/`config.ru`. `POST` runs
  `#to_response`; `GET` runs `#challenge_response` (or 405 with no declared `challenge`); any other
  verb 405s. A malformed Rack env is caught by the new `Inbound::BuildRequest` axn and mapped to a
  reported 500, never an unhandled exception.
- `Axn::Webhooks::Response#to_rack` — renders a Response as the `[status, headers, [body]]` triple
  a Rack app returns.
- `challenge` DSL declaration + `Axn::Webhooks::Inbound::Challenge` — the GET-echo handshake
  (Nylas `?challenge=`, Meta `?hub.challenge=` + `if:` guard on `hub.verify_token`). A missing/
  rejected challenge is a quiet 400; a resolver or guard that raises is reported and mapped to 500.
  `Endpoint#challenge_response(request) → Response` is testable without a Rack env, mirroring
  `#verify`/`#handle`/`#to_response`.
- `Axn::Webhooks::Request.from_rack(env)` — builds a Request from a Rack env: pristine raw body
  (read once from `rack.input`, then rewound if rewindable), headers from `HTTP_*`/`CONTENT_TYPE`/
  `CONTENT_LENGTH`, params from the request's primary param source (form-decoded body when the
  content type is `application/x-www-form-urlencoded`, else the query string), url, and
  http_method.
- `Axn::Webhooks.config.vendor_facet` (`setting`, default `false`, `one_of: [false, :dimension, :tag]`) — when set, stamps the registered vendor name onto the verify/dispatch/respond pipeline as that observability facet (Datadog/OTel dimension or tag), via the new `Axn::Webhooks::VendorFacet` mixin shared by `Verify`/`Dispatch`/`Respond`/`Challenge`.
- `Axn::Webhooks::Inbound::Endpoint#to_response(request) → Response` — the staged HTTP outcome mapping: verify mismatch/crash → 401; missing handler/unmatched/parse error/handler crash → 500; `otherwise: :ack` and handler business `fail!` → a bare 2xx ack; a genuine handler success → the declared `respond` block's body (default bare ack).
- `Axn::Webhooks::Request` — a Rails-agnostic wrapper (`raw_body`, `header`, `params`, `url`, `http_method`) that verifiers and dispatchers read from.
- `Axn::Webhooks::Signature` — parametric HMAC primitive (`hmac` / `compute` / `secure_compare`) with sha256/sha1/md5 digests; hex, base64, and base64-urlsafe encodings; prefix stripping; multi-candidate (key-rotation) headers; always constant-time.
- `Axn::Webhooks::Signature` replay protection — optional `timestamp:` / `tolerance:` bidirectional window (`within_tolerance?`), accepting epoch Integer/String or `Time`.
- Dual Rails-testing layout: a bootable `spec_rails/dummy_app/` Rails suite (its own bundle) alongside the existing Rails-free `spec/` suite, wired up via `rake spec_rails` / `rake verify` and split CI jobs.
- `Axn::Webhooks::Resolvers` — deferred request-value lookups (`header`/`raw_body`/`params`/`url`) and a `resolve` helper used by the `inbound` DSL and verifier strategies.
- `Axn::Webhooks::Verify` — the verify stage as an Axn: a signature mismatch fails quietly (no exception report); a verifier that raises is surfaced as a loud exception.
- `Axn::Webhooks.inbound(:vendor) { … }` + `Axn::Webhooks::Inbound[:vendor]` — block-per-endpoint registration and lookup, with a custom-block verifier slot and the `Verifiers` strategy registry.
- `verify :hmac` strategy — parametric HMAC (digest/encoding/prefix/custom signing string/replay window) over a `Request`, built on `Axn::Webhooks::Signature`.
- `verify :standard_webhooks` strategy — the Standard Webhooks / Svix scheme (`whsec_` secret, `id.timestamp.body` signing, `v1,` candidate extraction with key rotation, ±tolerance window). Removes any need for the `svix` gem.
- `Axn::Webhooks::Inbound::Router` — resolves a parsed webhook event to a handler (single `to:`, keyed `on:`+map, or name-from-key convention with `via:`), with a `with:` scalar extractor and `otherwise:` (`:ack` or a user callable). Missing/unmatched targets raise loudly.
- `Axn::Webhooks::Dispatch` — the dispatch stage as an Axn (parse → resolve → `Handler.call!`): a handler `fail!` is a quiet failure; a missing/unmatched handler, parse error, or handler crash is a loud exception reported once. Exposes the handler's own `Axn::Result` as `handler_result` so callers can read its exposures. `Axn::Webhooks::Parsers` builds the body parser (`:json` default or a proc).
- `dispatch` DSL + `Axn::Webhooks::Inbound::Endpoint#handle` — declare routing in an `inbound` block (`dispatch to:`/`on:`/`otherwise:`/`via:`/`parse:`); `handle(request)` runs verify then dispatch and returns the final `Axn::Result`.
- `Axn::Webhooks::Response` — a Rails-agnostic HTTP response value (status/body/headers) with `.ack`/`.text`/`.xml` factories, produced by the staged HTTP outcome mapping and rendered against Rack in a later phase.
- `respond` DSL declaration + `Axn::Webhooks::Inbound::RespondContext` — captures a block mapping a genuine handler success to a `Response`; the block runs with `ack`/`text`/`xml` available as bare calls.
- `dispatch mode:` — the async seam, resolved dynamically: an explicit `:async` delegates to the handler's own `.call_async` (inheriting whatever axn async adapter the app configured — never branches on `:sidekiq`/`:active_job`), an explicit `:sync` runs inline, and the default (`:auto`) runs **async when an adapter is configured for the handler, else sync** — except a custom `respond` (a result-returning hook) always forces sync. An explicit `mode: :async` + custom `respond` is rejected at `inbound` registration time (you can't read a handler result you enqueued). Dispatching `:async` against a handler with no adapter configured (explicitly disabled or never set) is a clean, reported `Axn::Webhooks::Error` (500-bound) rather than an uncaught `NotImplementedError` escaping the axn boundary; adapter presence is a truthiness check, so an explicitly-disabled handler (`_async_adapter == false`) is correctly treated as unconfigured and runs sync under `mode: :auto`.

### Changed
- Added `rack` (`>= 3.0`, `< 4`) as a runtime dependency. The gem requires Rack 3 (`Response#to_rack`'s
  lowercase header keys are required by Rack 3's SPEC), which means Rails 7.1+ (the first Rails
  whose actionpack allows Rack 3); Rails 7.0 (Rack 2 only) is not supported.
- Clearer README intro and gemspec description, with explicit mention of dispatch.
- Removed unnecessary rubocop pragma from dispatch parse example.

### Fixed
- `Request.from_rack`'s `params` no longer merges query-string params into a form-urlencoded
  body's params. `url` (via `Rack::Request#url`) already includes the query string, so the
  previous merge double-counted query params for URL-signing verifiers doing
  `validate(req.url, req.params, signature)` (e.g. Twilio's `RequestValidator`), causing valid
  signed callbacks to be rejected. `params` is now the request's single primary param source:
  form body fields only for `application/x-www-form-urlencoded` (query still reachable via
  `url`), and the query string otherwise (GET challenges, JSON POSTs, etc.).
- `Request.from_rack` no longer unconditionally calls `rewind` on `rack.input`. A Rack 3 stack
  without `Rack::RewindableInput::Middleware` in front (e.g. a bare `Rack::Builder` mount on a
  streaming server) may hand us a non-rewindable input, and calling `rewind` on it raised —
  turning a valid webhook into an unhandled 500 before verification ever ran. The full body is
  still read into `raw_body` before the (now guarded) rewind, so the pristine-body guarantee is
  unaffected.
- `verify` is now required whenever `dispatch` is declared. The no-op always-succeeds verifier
  (added to support challenge-only endpoints with no `verify`) had been returned whenever either
  `dispatch` or `challenge` was present without `verify`, which meant an endpoint declaring
  `dispatch` but no `verify` would process unverified webhooks. Registering such an endpoint now
  raises `Axn::Webhooks::Error` immediately; the no-op verifier remains available only for
  challenge-only endpoints (no `dispatch`).
- `Dispatch`'s async-adapter detection now lets a handler's own explicit setting (including `async false`, an opt-out) win over the global default adapter, matching axn's own `call_async` precedence. Previously a handler explicitly disabled for async was still treated as "configured" whenever a truthy global default was set, so `mode: :auto`/`:async` would call `call_async` for real and axn's `NotImplementedError` — a `ScriptError`, not rescued by the Dispatch axn boundary — escaped `Dispatch.call` uncaught. It's now caught before `call_async` is ever reached and reported as a clean `Axn::Webhooks::Error`.
- `Response#to_rack` now returns a mutable headers hash so Rails/Rack middleware (which sets response headers) works; the `Response` value object itself stays frozen. Array multi-value headers (e.g. Set-Cookie) pass through as Arrays, the native format required by Rack 3.
- `Request.from_rack`'s `url` now includes the `SCRIPT_NAME` mount prefix (built via
  `Rack::Request#url` instead of hand-assembling `PATH_INFO` alone). A mounted endpoint (e.g.
  `mount Axn::Webhooks::Inbound[:vendor], at: "/webhooks/codat"` in Rails, or a `Rack::Builder#map`
  block) puts the mount prefix in `SCRIPT_NAME` and leaves only the remainder in `PATH_INFO`, so
  the previous `url` silently dropped the prefix — breaking URL-based verifiers (notably Twilio's
  `RequestValidator`, which HMACs the full request URL) for otherwise-valid mounted requests.
- `Request.from_rack`'s `rack.input` rewind is now rescued, not just `respond_to?`-guarded. A
  non-seekable stream (e.g. a pipe or socket) can `respond_to?(:rewind)` yet still raise
  `Errno::ESPIPE` when actually called, which the previous guard didn't catch — turning a valid
  webhook into an unhandled 500 after the body had already been safely captured into `raw_body`.
  The rewind is best-effort courtesy only; any failure is now silently swallowed.
- `Request.extract_params` no longer treats a `GET`/`HEAD` request's (empty) body as form params
  just because it carries a default `application/x-www-form-urlencoded` `Content-Type` header —
  a common shape for challenge handshakes (Nylas/Meta). Previously this shadowed `QUERY_STRING`
  with an empty-body parse, so `req.params["challenge"]` returned `nil` and a valid `?challenge=`
  GET request 400'd. `GET`/`HEAD` now always read params from the query string; `POST` (and other
  body-carrying methods) keep the form-body-only behavior above.
