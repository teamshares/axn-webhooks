# Changelog

## [Unreleased]

### Added
- `Axn::Webhooks::Request` — a Rails-agnostic wrapper (`raw_body`, `header`, `params`, `url`, `http_method`) that verifiers and dispatchers read from.
- `Axn::Webhooks::Signature` — parametric HMAC primitive (`hmac` / `compute` / `secure_compare`) with sha256/sha1/md5 digests; hex, base64, and base64-urlsafe encodings; prefix stripping; multi-candidate (key-rotation) headers; always constant-time.
