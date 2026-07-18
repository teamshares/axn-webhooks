# Changelog

## [Unreleased]

### Added
- `Axn::Webhooks::Request` — a Rails-agnostic wrapper (`raw_body`, `header`, `params`, `url`, `http_method`) that verifiers and dispatchers read from.
- `Axn::Webhooks::Signature` — parametric HMAC primitive (`hmac` / `compute` / `secure_compare`) with sha256/sha1/md5 digests; hex, base64, and base64-urlsafe encodings; prefix stripping; multi-candidate (key-rotation) headers; always constant-time.
- `Axn::Webhooks::Signature` replay protection — optional `timestamp:` / `tolerance:` bidirectional window (`within_tolerance?`), accepting epoch Integer/String or `Time`.
- Dual Rails-testing layout: a bootable `spec_rails/dummy_app/` Rails suite (its own bundle) alongside the existing Rails-free `spec/` suite, wired up via `rake spec_rails` / `rake verify` and split CI jobs.
- `Axn::Webhooks::Resolvers` — deferred request-value lookups (`header`/`raw_body`/`params`/`url`) and a `resolve` helper used by the `inbound` DSL and verifier strategies.
- `Axn::Webhooks::Verify` — the verify stage as an Axn: a signature mismatch fails quietly (no exception report); a verifier that raises is surfaced as a loud exception.
