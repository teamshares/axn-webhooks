# Changelog

## [Unreleased]

### Added
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
