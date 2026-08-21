# Changelog

## [Unreleased]

### Documentation
- README: explain why a missing async adapter degrades to sync under `:auto` (inbound and outbound
  alike) but raises under an explicitly-declared `async`. The three behaviors read as inconsistent
  side by side; they line up once `emit` is understood as always-`:auto` (it has no way to *ask* for
  async). Records the reasons the explicit case must not silently downgrade — `async` is typically
  declared because the handler outlives the vendor's ack window, and the async path acks with no
  handler result where the sync path renders one — and the corollary for a future per-`emit`
  `async:` override.
- README: correct "swap the lambda body for a DB lookup and nothing else in this gem needs to move"
  in the outbound routing section. Runtime resolution genuinely works (now covered end-to-end by
  spec), but a DB-backed subscriber store additionally wants a secret per subscriber (the signer is
  process-global and never sees the URL), validation of resolver-returned URLs (only static `to:`
  arrays are boot-checked; a malformed row is reported but still counted in `emit`'s `target_count`),
  and a `webhook_id`→URL correlation for persisting delivery records. Also notes that resolution runs
  inline in the emitting process, so a store outage raises out of `emit`.
- README: document URL-signing verifiers, and correct the Twilio example. Vendors that sign the
  request URL (Twilio) must strip the trailing slash a mount adds — Rack leaves `PATH_INFO` as `"/"`
  when the mount point is the whole route, so `Request#url` carries a slash the vendor's registered
  URL does not, and the previous example passed `req.url` straight to `RequestValidator#validate`.
  Anyone following it rejected every request, with `:signature_mismatch` as the only symptom — which
  reads identically to a rotated secret. Also notes that `url` reflects proxy-reported scheme/host, so
  a CDN or `X-Forwarded-Proto` change silently breaks verification the same way.
- README: warn that a `verify` block must not return an `Axn::Result`. The contract is read as
  `check.is_a?(Signature::Check) ? check.ok? : !!check`, and an `Axn::Result` is neither — and is
  truthy when `ok?` is false, so a verifier that returns one reports every rejected request as
  verified and dispatches it. In an axn-consuming app "put the check in an action" is the obvious
  instinct, and this is the one place it fails open.
- README: note that Rails disallows autoloading during initialization, so a custom `verify` block must
  name its constant inside the block rather than at declaration time. (`dispatch to:` was already
  safe — a string handler is resolved via `const_get` per request.)
- Fixed the gemspec description and two `Signature` comments that still described outbound signing as
  future work; it has shipped since the initial outbound PR.
- README: documented the outbound `vendor`/`user_agent`/`timeouts` knobs, boot-time validation, the
  equal-jitter default backoff, the expanded retryable-status list, `Outbound.reset!` as the
  test-teardown API, and that a delivery's envelope-body `timestamp` and its signed
  `webhook-timestamp` header deliberately diverge across retries.

### Added (Inbound)
- **Nested `inbound` endpoints.** An `inbound` block may now contain `endpoint(name) { … }` blocks,
  each registering as `:"#{parent}_#{child}"` and inheriting every parent declaration (overridable
  by re-declaring) except `dispatch`, which a parent cannot declare. Lets one vendor's
  `verify`/`challenge`/`respond` be written once across several endpoints.
  The parent itself registers nothing; declaring a top-level `dispatch` alongside `endpoint` blocks
  raises at boot, as does nesting an `endpoint` inside an `endpoint` or reusing a child name. A
  parent `respond`/`static_respond` is allowed and inherited — sharing one renderer across a
  vendor's endpoints is a primary use — and a child may swap forms, dropping the inherited one,
  while declaring both in the same block stays an error. Each child is validated exactly as a standalone endpoint
  would be.

### Changed (Outbound)
- **`sign :hmac` copies the Strings it validates.** Validation runs once at declaration, so
  retaining the caller's object let an app mutate `header:` afterwards — `replace("Content-Type")`
  walks past both the field-name grammar and the reserved-header rule, and `Deliver` then overwrites
  the signature. `header:`, `timestamp_header:`, `signing_string:` and `prefix:` are now duped and
  frozen. (`secret:` deliberately isn't: it may be a callable, and a String one is re-read per call.)
- **`sign :hmac` and per-emit `async:` are validated harder at the boundary.** `digest:`/`encoding:`
  are checked against `Signature`'s supported sets at declaration time (a typo previously booted
  fine and raised inside every delivery attempt — on the async path, after the job was enqueued);
  header names must be valid HTTP field tokens (`Net::HTTP` serializes whatever key it is handed, so
  a space produced a malformed request and a newline could append wire headers); and `header:`/
  `timestamp_header:` may not collide case-insensitively, which silently replaced the signature with
  the timestamp. Neither may name a header `Deliver` manages (`content-type`/`user-agent`),
  which loses the signature the same way, and a malformed `signing_string:` brace (`{time-stamp}`,
  `{timestamp`) is rejected instead of being signed as literal text. `emit(async:)` is now `type: :boolean`, so a config-derived `"false"` no longer
  reads as truthy and demands async.
- **`emit` accepts per-call `to:` and `async:` overrides.** `to:` (a String or Array) replaces the
  event's declared targets for one call — never merges — and validates the one-off URL at emit time
  as an `Axn::Webhooks::Error`. `async: true` raises when no adapter is configured rather than
  silently running inline (a missing adapter degrades only under `:auto`, never under an explicit
  request); `async: false` forces the inline path and suppresses the degraded-mode warning. No
  per-call `headers:` — per-destination config is deferred to the DB-backed subscription store,
  since a Hash of headers would persist a bearer token in async job args for the whole retry
  lifetime.
- **Added `sign :hmac`**, a parametric outbound HMAC preset mirroring inbound's `verify :hmac`
  (`digest:`/`encoding:`/`prefix:`/`signing_string:`), so a receiver expecting a plain
  `X-Signature: <hex>` no longer needs a hand-written signer block. `header:` is required; an
  optional `timestamp_header:` plus a `{timestamp}`/`{body}` template covers Slack-style
  `v0:ts:body` schemes. The template is validated at declaration time — unknown placeholders, and
  `{timestamp}` with no header to carry it, are both rejected at boot — as is a `secret:` callable
  that can't be invoked with zero arguments. A secret resolving to a blank or non-String value
  raises rather than signing with an empty key, and the error never carries the secret's bytes.
- **`emit` now exposes `failed_count`.** The synchronous fallback path called `Deliver.call` and
  discarded the result, so a failed delivery still left `emit` `ok` with the target counted as
  delivered. `failed_count` is always `0` on the async path (nothing has failed at emit time), and
  `emit`'s own result deliberately stays `ok` regardless — the count is the surface, not the outcome.
- **`Outbound::Config` is now genuinely frozen**, making good on the "immutable" claim in its own doc
  comment. Freezing naively would have broken reads: `Axn::Configurable` memoizes a static default
  into an ivar on first read, so any setting an `outbound` block never assigned (`max_attempts`,
  `vendor`, `user_agent`, `open_timeout`, `read_timeout`) raised `FrozenError` **from the reader**.
  `Config#initialize` now materializes all seven settings before freezing itself, the events map and
  each event spec — copying a static `to:` array rather than freezing the caller's own object, which
  previously left an application holding a frozen constant it never froze while its Strings stayed
  mutable, so a `String#replace` could rewrite the published config past its boot-time validation.
  The list of settings to materialize is derived from `Axn::Configurable` rather
  than hand-maintained, so adding a new `setting` needs nothing else — forgetting would otherwise
  turn that setting's own reader into a `FrozenError`. Caller-supplied objects — the signer, a `to:`
  resolver, an injected transport — are deliberately left mutable. `Outbound.install`/`reset!` are serialized behind a mutex; `config`
  reads stay lock-free, which is safe precisely because what they publish is frozen.

### Fixed (Outbound)
- **`sign :standard_webhooks, secret:` now accepts a callable**, resolved fresh per signing attempt —
  matching every inbound `verify` secret's convention (`Resolvers.resolve`), which outbound quietly
  didn't honor. A `secret:` lambda (the form both this README and every consuming app's initializer
  use for every other webhook secret, so it resolves per request/attempt rather than being frozen at
  boot) previously got `.to_s`'d into its `#<Proc:...>` source location and signed with that as the
  key — every single delivery byte-for-byte unverifiable on the receiving end, and *silently*: the
  receiver just 401s, `Deliver` classifies a 401 as a permanent failure (quiet `fail!`, deliberately
  no page), and nothing anywhere named the cause. `Signer::StandardWebhooksSigner` now resolves a
  callable secret per call; a secret that still isn't a decodable `whsec_<base64>` value after
  resolution now raises a named `Axn::Webhooks::Error` instead of a bare `ArgumentError` from inside
  `Base64.strict_decode64`. That check now also rejects a blank secret and one missing the required
  `whsec_` prefix — both previously decoded "successfully" (an empty or unprefixed value is still
  valid base64) and signed every delivery with an empty or wrong key, indistinguishable from any
  other receiver-side misconfiguration. The error message never includes the secret's actual bytes
  (only its class, or a shape description like "a whsec_-prefixed String that failed to decode") —
  it can be raised on every delivery attempt (a callable secret re-resolves per call, and may
  transiently resolve to something malformed), which is exactly when it'd otherwise flow the live
  signing credential into whatever logger/exception reporter `Axn.config.on_exception` is wired to.
  A callable `secret:` that cannot be invoked with zero arguments (it's documented arity-free —
  resolved fresh with no args per signing attempt) is now rejected at boot instead of raising
  `ArgumentError` on every real signing attempt.
- A permanent-4xx failure message's truncated response-body snippet no longer risks
  `Encoding::CompatibilityError` (mixing the ASCII-8BIT net/http labels every response body with, and
  the UTF-8 ellipsis) or a dangling invalid byte sequence from cutting a multibyte character at the
  500-byte boundary — both turned an intended quiet `fail!` into an unhandled exception the async
  adapter would retry.
- Boot-time URL validation now requires a host, not just an http(s) scheme — `"https:foo"`,
  `"https:"`, and `"https:///hook"` all parse as scheme-only `https` with no host, previously
  accepted and left to fail unexpectedly inside `Transport`'s request construction at delivery time.
  It also now requires a String outright — a non-String `to:` entry (e.g. a `URI` object) parsed
  fine via `#to_s` here, but the original object is what stayed in the declaration and was later
  handed to `Deliver` as `url:` (`expects :url, type: String`), rejected at emission time despite
  passing this check.
- The `backoff` boot-time check now verifies the callable actually accepts one positional argument
  (via the new `Outbound::CallableArity`, built on `#parameters`) instead of trusting `#arity` —
  `->(attempt:) { }` (a required keyword) and `->(a, b, *rest) { }` (needs two positional args) both
  reported an arity that passed the old check, then raised `ArgumentError` on the very first
  `config.backoff.call(attempt)`. `user_agent`, if configured as a callable, gets the same
  zero-argument check — `Deliver` resolves it with no args per delivery attempt.
- `Axn::Webhooks.emit` no longer resolves the event's `vendor` ahead of `Emit.call!` — that lookup
  raises the same "unknown outbound event" error `Emit` itself already raises internally, but doing
  it before entering the action bypassed axn's executor (and its `on_exception` reporting) for an
  unregistered event, silently downgrading what's meant to be a loud, reported failure. `Emit`'s
  `vendor` reader now computes `Config#vendor_for(event)` fresh on every read rather than caching it
  into an ivar set inside `#call` — axn resolves `dimension`/`tag` facets input-phase (eagerly,
  before the body runs), so a value only set inside `#call` read as unset there: `Emit`'s own
  `:vendor` facet stamped `nil` even though the identical value, threaded down to `Deliver`, stamped
  correctly.
- `StandardWebhooksSigner#decoded_secret`'s `rescue ArgumentError` is now scoped to only the Base64
  decode step, not the whole method — a callable `secret:`'s own resolver raising `ArgumentError`
  for an unrelated reason (e.g. a secret-store wrapper rejecting a malformed response) was
  previously rewritten into the generic invalid-secret message, discarding the resolver's actual
  diagnostic before Axn's exception reporter ever saw it.

### Added (Outbound)
- **`vendor`** — a block-level default (and per-event override) that stamps the same
  `Axn::Webhooks.config.vendor_facet` dimension/tag inbound endpoints already use, onto both `Emit`
  and `Deliver`. Previously dead: both classes already `include VendorFacet`, but nothing ever passed
  a `vendor:`, so the facet was always `nil`. `event` is now also stamped as its own unconditional
  dimension on both — same shape as inbound's `reason`, bounded to the events a sending app declares.
- **`user_agent`** — a suffix (plain value or zero-arity callable, resolved per attempt) appended to
  the fixed `axn-webhooks/<version>` User-Agent as `axn-webhooks/<version> (<value>)`. "Which app,
  which deploy sent this hook" is the first question in any delivery investigation, and there was
  previously no way to answer it from the header.
- **`timeouts open:`/`read:`** — a DSL override for the built-in transport's `open_timeout`/
  `read_timeout` (previously hardcoded 5s/10s with no way to change them short of replacing the whole
  transport). Only forwarded to the built-in `Transport` — a custom injected transport keeps owning
  its own timeout configuration, since the documented seam (`.post(url:, body:, headers:)`) makes no
  promise about accepting timeout kwargs.
- A permanent-4xx failure message now includes a truncated (500-byte) copy of the receiver's response
  body — previously discarded entirely (`Transport::Response` carried only `status`/`headers`), so
  `"permanent delivery failure (HTTP 422) for lead_signed to https://..."` was the whole diagnostic,
  with no way to see *why* the receiver rejected it. `Transport::Response` gains a `body:` field
  (defaulting to `nil`, so a custom transport built against the two-field shape keeps working
  unmodified).
- `Axn::Webhooks.emit`'s result now exposes `webhook_ids` (one per resolved target) and
  `target_count` — previously nothing, so a caller had no way to record what an emission actually
  fanned out to.
- The default `backoff` curve now applies **equal jitter** (half the computed delay fixed, half
  random) — previously an exact deterministic curve, so every failing target of a fan-out event
  retried in lockstep, converging on the same instant against a receiver that was already struggling.
- `retryable?` now also treats **408 Request Timeout** and **425 Too Early** as retryable, alongside
  the existing 5xx/429.
- Boot-time validation on the `outbound` block: `max_attempts` must be a positive Integer; `backoff`
  must accept the attempt number; `to:` must be an Array or a callable; a statically-declared `to:`
  URL must be a valid http/https URL with a host; `timeouts open:`/`read:` must each be a positive
  Numeric. Each previously either behaved unexpectedly at delivery time (an arity-0 `backoff` blows
  up mid-delivery; a non-Array/non-callable `to:` is silently mangled by `Array(...)`; a non-Numeric
  timeout, e.g. a String from `ENV.fetch`, raises `NoMethodError` from inside `Net::HTTP`) or crashed
  as an unhandled exception the async adapter would retry forever (a malformed or hostless static
  URL raises inside `Transport.post`'s `URI.parse`/`#request_uri`). The `backoff` check inspects
  `#arity` when the callable has one (a Proc/lambda) and `#method(:call).arity` otherwise (a plain
  object with its own `def call(attempt)`, which has no `#arity` method) — not the other way around:
  `Proc#call` is itself variable-arity, so `#method(:call).arity` on a Proc is always `-1` regardless
  of what it actually declares, which would silently accept a zero-arity one.

  Every one of these checks — along with an unknown `sign` strategy and a missing `sign` declaration
  — is a pure declaration mistake, decided once when the block is evaluated and never at runtime, so
  each raises plain `ArgumentError` rather than the gem's own `Axn::Webhooks::Error` (reserved for
  conditions a caller might legitimately rescue at runtime, e.g. emitting an unregistered event).
  `max_attempts`/`backoff`/`transport`/`vendor`/`user_agent`/`timeouts` are now declared via
  `Axn::Configurable::Settings` (the same DSL `Axn::Webhooks` itself and sibling gems use) rather
  than hand-rolled ivars — `events` stays hand-written, since it's a Hash cross-validated as a whole
  from one DSL block rather than a flat setting.
- A second `Axn::Webhooks.outbound` block now logs a warning before silently replacing the first
  (previously a bare, silent assignment) — only one outbound declaration is ever active at a time.

### Added
- `Signature::SIGNATURE_MISSING`, the fifth exported verdict, alongside `OK`, `MISMATCH`, and the two
  `CREDENTIALS_*`. A custom `verify` block can only distinguish "no signature header at all" from "the
  signature didn't match" if it reads the header itself, and a bare falsey return collapses both into
  `:signature_mismatch` — which on a guessable public path buries the alertable case under ordinary
  unsigned scanner traffic. The README recommends returning a `Check` for exactly this, so the verdict
  it wants is now exported rather than hand-constructed. `Signature.hmac_check` returns the same
  constant internally.
- Verification failures now name their cause. `Signature.hmac` checked the replay window first and
  returned a bare `false`; a signature mismatch returned the same bare `false`; `Verify` mapped both
  to `fail!("signature mismatch")`. The two were therefore indistinguishable in the logs — and in the
  replay case the message was actively wrong, since the signature was valid. That cost hours on the
  Lob outage (os-app#5128), where every real delivery 401'd with a *valid* signature (the replay guard
  rejected it, because the timestamp was epoch-**ms** read as epoch-s) but the only evidence said
  "signature mismatch", sending the investigation into secret rotation and secret drift first.
  - New `Signature.hmac_check(...)` returns a `Signature::Check` (`ok?`, `reason`, `skew`,
    `suggested_unit`) instead of a boolean. `Signature.hmac` is now literally `hmac_check(...).ok?` — same behavior, byte for byte,
    and the replay window still lives in exactly one place rather than being duplicated into each
    verifier. New public `Signature.skew(timestamp:, now:, unit:)` returns the signed drift in
    seconds (positive = the timestamp is in the past), or nil if it's absent/unparseable;
    `within_tolerance?` is now defined in terms of it.
  - `reason` is one of four: `:replay_window` (valid timestamp, outside the window — carries `skew`),
    `:replay_timestamp_invalid` (absent or unparseable timestamp), `:signature_missing` (no signature
    header), `:signature_mismatch` (the HMAC genuinely didn't match). The last three were all
    "signature mismatch" before, though each names a different misconfiguration.
  - `Verify` exposes `reason`, `skew` and `suggested_unit` on the result, uses a reason-specific
    message, and stamps
    `reason` as a `dimension` (`from: :result`), so verify failures are groupable in Datadog/OTel —
    the missing signal behind PRO-3125's monitor, which could alert on verify failures but not
    classify them. Unlike `:vendor`, this dimension is *not* gated behind
    `Axn::Webhooks.config.vendor_facet`: it's a closed enum, not a per-endpoint identity, so a default
    install needs it as much as a configured one.
  - A `:replay_window` rejection also carries `suggested_unit` — the scale that *would* have put the
    timestamp inside the window, via `Signature.mismatched_unit` (added in PRO-3142) — stamped as a
    second bounded dimension and appended to the message ("— would fit as unit: `:ms`"). Its
    presence splits the misconfigured half of `:replay_window` from the genuine half, and its value
    names the fix; `skew` alone (~1.8 **trillion** seconds for epoch-ms read as epoch-seconds) says
    only that something is very wrong. Since PRO-3142 made `unit:` infer the scale per timestamp,
    this is non-nil only when a `unit:` was explicitly **pinned** and doesn't fit — so
    `reason: :replay_window` with no `suggested_unit` now overwhelmingly means a genuine stale
    delivery. A timestamp is not a secret and the HTTP response is a bare 401 either way, so nothing
    extra reaches the sender.
  - The built-in `:hmac` and `:standard_webhooks` strategies now return a `Signature::Check` rather
    than a boolean. Custom `verify` blocks are unaffected — the documented
    `->(request) { Boolean }` contract still holds and a falsey return reports
    `:signature_mismatch` — but a custom block may now return a `Check` to name its own cause.
- **`verify :basic_auth`** — HTTP Basic auth as a first-class strategy, owning the whole mechanism
  rather than leaving each app to hand-roll it: constant-time credential comparison (hashing first,
  so credential *length* doesn't leak the way a bytesize precheck would), the
  `WWW-Authenticate: Basic realm="…"` challenge described below, and fail-closed on a missing or
  blank username/password. That last one matters — comparing against `""` would authenticate
  `Authorization: Basic Og==` for anyone, and CI and secret managers can both set an empty string,
  so blank-but-present counts as missing and raises (a reported exception) rather than quietly
  returning 401. Credentials resolve through `Resolvers`, so `-> { ENV.fetch("…") }` works as it
  does for `:hmac` and a rotated secret is picked up without a reboot. `realm:` defaults to
  `"Webhook"` and is escaped per RFC 7230 quoted-string rules.
- **`unauthorized_headers`** on the `inbound` DSL, for a custom `verify` block that needs to supply
  its own 401 challenge. A declaration wins over the verifier's own `#unauthorized_headers`.
- Two new `Signature::REASONS` for the above: **`:credentials_missing`** and
  **`:credentials_mismatch`**, so a Basic-auth rejection isn't reported as `:signature_mismatch` on
  an endpoint where no signature exists. `:credentials_missing` means the client presented an
  `Authorization` header that wasn't a Basic credential — it meant to authenticate and got it wrong,
  which is a real and low-volume signal; the bare handshake leg is challenged before `Verify` runs
  (see below) and so never lands here. `:credentials_mismatch` is credentials offered and rejected.
- **The Basic-auth challenge leg no longer records a verify failure** (PRO-3148). Under RFC 7617 a
  client that doesn't authenticate preemptively sends one bare request per *successful* webhook, so
  settling that leg as a `Verify` failure made the highest-volume outcome on a perfectly healthy
  endpoint a recorded failure — which broke the thing `reason` exists for. A cross-vendor "verify
  failures" monitor saw a permanent stream from every Basic-auth endpoint and none from signature
  endpoints, and could only be quietened by teaching it which vendors happen to use Basic auth:
  exactly the vendor-specific knowledge that rots. `Endpoint#to_response` now asks whether the
  request is an authentication attempt at all and, when it isn't, answers with the 401 challenge
  *before* `Verify` runs. Same 401 on the wire, still no path to a handler — and strictly safer than
  the `done!` this invites, which settles the result as a *success* and would dispatch a request
  that presented no credentials.
  - New public **`Endpoint#challenge_required?(request)`**, sourced from the verifier's own
    `#challenge_required?` when it has one. `verify :basic_auth` has one (true when `Authorization`
    is absent or blank); the signature strategies don't, so they are byte-identical in behaviour and
    telemetry. `#verify` and `#handle` are deliberately unchanged — they are the verification stage,
    and a bare request honestly doesn't verify — so a caller driving them by hand asks this first.
  - The predicate runs inside its own Axn (`Inbound::ChallengeRequired`), like the verifier, the
    `parse:` step and the GET challenge resolver: it's request-dependent code reading adversarial
    input, and it runs ahead of every other boundary on the POST path, so a raise would otherwise
    escape as an unhandled Rack exception. A crash reads as "can't tell" and verifies normally — the
    pre-precondition behaviour, which can neither dispatch an unauthenticated request nor drop an
    authenticated one — and is reported once via `on_exception`. An endpoint with no predicate makes
    no such call at all, so the signature strategies gain no stage.
  - New **`challenge_required { |req| … }`** `inbound` declaration, mirroring `unauthorized_headers`
    (a declaration wins over the verifier's own predicate). Needed when a custom `verify` block
    wraps a two-legged verifier the gem can't see through. An endpoint that requires a challenge but
    has none to send raises at boot — whether the predicate came from this declaration or from a
    verifier's own `#challenge_required?`, since `Verifiers.register` is public: a client told to
    retry but not told how is the PRO-3146 silent drop, and skipping `Verify` would now make it
    invisible as well as broken.

### Changed
- `Verify`'s error prefix is now the mechanism-neutral **"Webhook verification failed"** (was
  "Webhook signature verification failed"). It prefixes *every* reason's message, so with
  `verify :basic_auth` it read "Webhook signature verification failed: Basic credentials rejected"
  — announcing a signature failure on an endpoint that has no signature, in the first words an
  operator reads, which is exactly the misdirection `reason` was added to end. The signature cases
  lose nothing: their own half of the message still names the signature. Only the human-readable
  string changed — `reason` (the thing to match on programmatically) is untouched.

### Fixed
- A verified request whose body doesn't parse no longer 500s, which invited an unbounded vendor retry
  loop (PRO-3143). `parse.call(request)` raised inside `Dispatch`, the outcome mapper turned any
  exception into a 500, and vendors retry non-2xx — Lob for 5 days, then it disables the endpoint — so
  the gem's answer to "this body is malformed" was to ask the sender to deliver it again forever, for a
  class of failure a retry can never fix. `Dispatch#parse_event` now wraps whatever the parse step
  raises in the new `Axn::Webhooks::UnparseableBody < Axn::Webhooks::Error` (the original preserved as
  `cause`), and `Inbound::Endpoint#response_for` maps that class to the new `unparseable_status` —
  **200** by default — in a branch ahead of the generic exception→500 one. It stays an axn exception
  outcome, deliberately not in any `fails_on`, so `Axn.config.on_exception` still reports it exactly
  once: report, then ack. The whole step is wrapped rather than an allowlist of known JSON errors, so a
  custom XML/form/protobuf `parse:` proc gets the terminal outcome without referencing this gem's error
  classes; an `UnparseableBody` such a proc raises itself passes through unwrapped. A handler crash,
  a missing/unresolvable handler, and an unmatched event with no `otherwise:` all still 500 (retrying
  those can help — a deploy may resolve them), and verify still 401s first.
- `Dispatch`'s `rescue Axn::Webhooks::RetryLater` moved from wrapping just the handler's `call!` to
  wrapping the whole `call`, so a `parse:` proc that does I/O can still ask for redelivery (`503`)
  rather than having a transient failure acked away as unparseable — the one thing the parse step
  doesn't treat as terminal. Incidentally a `RetryLater` raised by a `with:` extractor or an
  `otherwise:` callable now maps to 503 too, instead of a reported 500.
- **A verify failure's 401 can now carry response headers, and HTTP Basic auth endpoints actually
  work.** `Endpoint#to_response` returned `Response.new(status: 401)` unconditionally — a bare 401,
  with no way for a verifier to contribute headers to it. That silently breaks every vendor that
  does *reactive* Basic auth (RFC 7617): a client which doesn't authenticate preemptively sends its
  first request with **no** `Authorization` header, expects a 401 carrying
  `WWW-Authenticate: Basic realm="…"`, and only then repeats the request with credentials. Twilio
  documents exactly this behaviour for webhook URLs, so with a bare 401 the second leg never
  happens: every webhook is dropped, and the outage is near-invisible because the dropped requests
  look like ordinary auth failures. This cost buyout ~27h of missing inbound-call alerts and
  voicemail transcriptions (`teamshares/buyout-app#2690`, reverted in `#2699`) and was hard to
  diagnose precisely because the observability read "all failures, no successes" — those were all
  first legs; the credentialed second leg never existed, so it showed up as neither. Endpoints
  using a signature strategy are unaffected and still return a bare 401 (there is nothing to
  challenge a signing client *with*).
- **`Verify` no longer logs its verifier.** `expects :verifier` was not marked `sensitive: true`,
  so Axn's per-call info logging rendered the verifier on every request. Harmless for the lambda
  the signature strategies build (`Proc#inspect` is just a source location) but not for any
  verifier that *holds* a secret in an ivar — the default `Object#inspect` would have written a
  plaintext credential to the application log on every single request. Marked sensitive at the
  boundary, since a custom `verify` block can't be relied on to have thought about it.
- `dispatch to:`/map entries can now target an `Axn::Factory.build(...)` product.
  `Axn::Factory` gives every generated class a debug `.name` (`"AnonymousAxn_<object_id>"`) so its
  instances can be identified in logs, but `Router#constantize` used `name.nil?` to decide whether a
  Module target was truly anonymous (and thus must be used as-is) versus a named class safe to
  re-resolve via `const_get` for Zeitwerk reload-safety. A factory product's name is a non-nil String
  that was never assigned to a constant, so it took the re-resolve branch and blew up with
  `NameError: uninitialized constant AnonymousAxn_62968` — the one construct the anonymous-class
  branch exists for could never reach it. The test is now "does this name actually resolve to a
  constant" (`Object.const_defined?`), not "is it nil" — a real named class still re-resolves by name
  every call, while an unresolvable name (truly anonymous, or a factory's debug name) is used as-is.
- `Request#params` now parses `multipart/form-data` bodies. `extract_params` recognized only
  `application/x-www-form-urlencoded` as a form body, so a multipart POST fell through to the
  query-string branch and `params` came back empty (`raw_body` was correct either way — only
  `params` was wrong). Dropbox Sign posts the entire event as a single multipart `json` field and
  its verification reads that field twice — `Content-MD5` is
  `Base64(hex(HMAC-MD5(api_key, json_field)))`, and the payload is `JSON.parse(params["json"])` —
  so **every live Dropbox Sign delivery 401'd**. A spec that posted the same fields urlencoded
  passed, which is why nothing caught it. Multipart parsing is delegated to `Rack::Request#POST`
  (which handles both encodings across Rack 3 minors), fed a `StringIO` over the already-captured
  `raw_body` rather than the live `rack.input` — re-reading the real stream would yield `{}` on a
  bare Rack/streaming host, whose input is readable but *not* rewindable, and would leave the input
  at EOF for anything downstream. File parts are spilled to `Tempfile`s by Rack, which *assigns*
  (not appends) `env["rack.tempfiles"]` — so those are handed back to the caller's env, where
  `Rack::TempfileReaper` can actually reap them. A malformed body yields `{}` rather than raising: a hostile
  *unverified* request must not be able to crash the pipeline before `verify` runs. The existing
  contract is unchanged: `params` is
  the request's primary param source, never a query+form merge, and GET/HEAD always read the query
  string.
- **Security:** `Request#inspect` no longer renders `raw_body`/`headers` in full. The inbound
  pipeline's own axns (`BuildRequest`, `Verify`, `Dispatch`, `Challenge`) auto-log their
  `request:`/`env:` fields at `:info` by default, and `Request` relied on `Object#inspect`, which
  dumped every instance variable — so a webhook's complete raw body (and headers, including the
  vendor signature) was logged multiple times per request with no way for a consuming app to
  suppress it (`sensitive:` only covers fields *the consumer* declares, not the gem's own internal
  ones). `Request#inspect`/`#pretty_print` now redact both fields, and the gem's own `request:`/
  `env:` declarations are additionally marked `sensitive: true` as defense in depth.
- `Request.from_rack` now rewinds `rack.input` **before** reading it, not only after. Rack 3's
  `Rack::Request#POST` no longer rewinds after parsing a form-urlencoded body, and Rails' default
  middleware stack runs `Rack::MethodOverride` (which calls `#POST` looking for `_method`) ahead of
  the router — so a mounted endpoint received an input already at EOF for **every form-encoded
  POST**, silently emptying both `raw_body` and `params`. That broke dispatch *and* signature
  verification for exactly the vendors that post forms (Twilio, Slack), while JSON vendors were
  unaffected (MethodOverride only parses forms), which is why no existing spec caught it. The
  dummy Rails app now runs `Rack::MethodOverride` explicitly — `config.api_only` had dropped it, so
  the app under test was not representative of a real Rails host.
- `Request.from_rack` no longer requires `rack.input` to be present. It was mandatory under Rack 2
  but is **optional** under Rack 3, so a bodyless request may omit the key entirely — which
  `Rack::MockRequest.env_for` does, and therefore so does every Rails request/integration spec. The
  hard `env.fetch("rack.input")` turned that into a `KeyError` → reported exception → **500 on the
  bodyless GET challenge handshake**, i.e. the exact Nylas/Meta flow `challenge` exists to serve. A
  missing input is now read as an empty body. The pre-existing "malformed env" spec asserted the old
  behavior via `{ "REQUEST_METHOD" => "POST" }`; since no hand-built env is sparse enough to break
  parsing anymore, it now stubs `from_rack` to raise so it still pins the real invariant (a
  BuildRequest failure maps to a clean 500 rather than escaping as a raise).

### Added
- `Axn::Webhooks.config.unparseable_status` (default `200`) and a per-endpoint
  `dispatch unparseable_status:` override — the HTTP status an inbound endpoint returns when a verified
  request's body doesn't parse (see the Fixed entry above). The default is a 2xx rather than the tidier
  400 because 2xx is the only answer every vendor reads as "stop redelivering": Lob, Stripe, Slack and
  Shopify all retry non-2xx, and the last two also disable an endpoint after sustained failures. Set
  `400` for a vendor that does honor 4xx as terminal, or `500` to restore the previous behavior. Both
  levels validate the value as an Integer in `200..599` (the config setting via `ArgumentError` on
  assignment, the DSL via `Axn::Webhooks::Error` at declaration time) against the shared
  `Axn::Webhooks::Response.valid_status?`. A declared `static_respond` still renders its body on this
  row — Dropbox Sign and friends key the ack on the body text, not the status, so a bare status-only
  response would be read as a failed delivery and redelivered anyway. `Response#with_status(status)`
  (new) is what restamps it: the block picked its status for the success path, but the gem owns the
  outcome→status mapping. `Endpoint#default_ack` takes an optional `status:` for that one caller and
  leaves the other rows (including a block's own `text("queued", status: 202)`) untouched.
- A dispatch entry's `with:` now accepts a **Symbol** as the rename-only shape — `with: :payload` is
  `{ payload: event }`, the whole parsed event under a different kwarg name, where the lambda form
  read as a stutter (`with: ->(event) { { data: event } }` names the same value twice). For endpoints
  whose parsed object isn't naturally an "event": a Slack interaction is a `payload`, and on the
  events endpoint "event" is already taken by `event["event"]`. Composes with `async()`/`sync()`
  (`async("H", with: :payload)`) and changes nothing about the callable form or the `event:` default.
  A `with:` that is neither a Symbol nor callable now raises `Axn::Webhooks::Error` at resolve time
  instead of `NoMethodError`-ing on `.call`. Note this hands the whole raw event to the handler, so on
  an **async** route it lands in the job args (Redis, retry sets, the Sidekiq UI) — prune with a
  callable instead when the payload carries secrets or PII.
- Dispatch handler targets now accept the **class itself**, not only a class-name string — `to: Foo`,
  `to: { "k" => Foo }`, and `async(Foo)`/`sync(Foo)` all work alongside the string forms. A named
  class is reduced to its name and re-resolved via `const_get` on every request, so a class object
  passed at declaration time stays reload-safe under Rails/Zeitwerk (no captured-then-stale object);
  an anonymous class is used as-is. Strings remain the recommended default in initializers (they never
  force the handler to be autoloadable at boot).
- `async(call, **opts)` / `sync(call, **opts)` dispatch-map DSL sugar — terse builders for a
  per-route entry: `async("H")` == `{ call: "H", async: true }`, `sync("H")` == `{ call: "H",
  async: false }`. Callable directly inside a `dispatch to: { … }` map (the `inbound` block is
  instance_exec'd against the DSL) and compose with a `with:` extractor. Pure sugar over the
  existing `async:` entry — no change to resolution.
- Per-route sync/async on one endpoint (interaction-platform pattern) — a dispatch-map Hash entry
  accepts an optional `async:` boolean (`{ call: "Handler", async: true }`), so one endpoint under
  one `respond` block can multiplex async-ack routes and sync-body routes (Slack `view_submission`
  vs `block_actions`, Discord, Telegram). Precedence, most-specific first: the entry's `async:`, then
  an explicit endpoint `mode:`, then a declared `respond` (sync — Decision D preserved), then `:auto`
  adapter detection. A non-boolean `async:` raises at resolve time; `async: true` on an adapter-less
  handler settles as a reported exception (unchanged guard).
- `Axn::Webhooks.retry_later!(after: nil)` and `Axn::Webhooks::RetryLater < Axn::Webhooks::Error` (`#retry_after`) — the receiver-side half of the 503 delivery contract: a handler raises this (directly, or via the new helper) to ask the sender to redeliver later. `Axn::Webhooks::Response.service_unavailable(retry_after: nil)` builds the matching 503 response, with a `retry-after` header only when given. `Axn::Webhooks::Error` now lives in the new `lib/axn/webhooks/errors.rb`, required first (before `version` and everything else) so `Error`/`RetryLater` are defined before any file that references them at load or runtime. `Axn::Webhooks::Dispatch` now rescues a `RetryLater` raised by the synchronous handler call around it, exposing the new `retry_later` (`type: :boolean, default: false`) and `retry_after` (`allow_nil: true`) instead of surfacing it as an exception outcome; `Inbound::Endpoint#response_for` maps a `dispatched.retry_later` of `true` to `Response.service_unavailable(retry_after: dispatched.retry_after)` as its first check, ahead of the exception/failure mapping — so raising `RetryLater` at all always means 503, whether or not `after:` was given (`after:` only controls whether the `Retry-After` header is present). Only the synchronous dispatch path is wired this way — a `retry_later!` raised inside an async worker is just a worker exception, unrelated to the HTTP response already sent.
- `Axn::Webhooks::Handler` (new `lib/axn/webhooks/handler.rb`, required from `lib/axn/webhooks.rb` right after `webhooks/errors`) — the recommended `include` for an inbound webhook handler that wants `retry_later!`'s "without paging" promise to actually hold: it includes `Axn` and declares `fails_on Axn::Webhooks::RetryLater`, so a `RetryLater` the handler raises settles as a quiet failure, not an unhandled exception. Without it (a plain `include Axn` handler calling `retry_later!`), `Dispatch`'s rescue still maps the response to 503 — but axn's own executor classifies the unhandled `RetryLater` as an exception FIRST, inside the handler's own boundary, and reports it via `Axn.config.on_exception` (e.g. Honeybadger) on every single deferral, exactly the paging the feature was meant to avoid. `include Axn::Webhooks::Handler` (or an equivalent manual `fails_on Axn::Webhooks::RetryLater`) closes that gap.
- `Axn::Webhooks.emit(event, data: {}) → Axn::Result` and its backing `Axn::Webhooks::Outbound::Emit` axn — the outbound fan-out entrypoint. Validates the event via `Outbound.config` (`#wire_type`/`#targets_for`, raising `Axn::Webhooks::Error` loudly on an unknown event), then per resolved target generates a fresh `Envelope.new_id`, builds the envelope body, and enqueues one `Outbound::Deliver`. Delivery goes async via `Deliver.call_async` when an async adapter is configured (per-`Deliver` setting, else the global default — the same presence-check pattern as inbound `Dispatch`, never branching on adapter type); otherwise it falls back to a synchronous inline `Deliver.call` with a `Axn.config.logger.warn` (best-effort, no cross-process retries).
- `Axn::Webhooks::Outbound::Deliver` — the per-attempt delivery axn and self-managed retry engine: signs each attempt with a fresh timestamp (reusing the stable `webhook_id`) via `Outbound.config.signer`, POSTs via `Outbound.config.transport`, and classifies the response — 2xx succeeds; a permanent 4xx `fail!`s quietly (no reschedule); a 5xx/429/retryable network error (`Transport::RETRYABLE_NETWORK_ERRORS`) reschedules itself via `call_async(..., attempt: attempt + 1, _async: { wait: })` where `wait` is `max(backoff(attempt), Retry-After)`; exhaustion (`attempt >= max_attempts`) reports once via `Axn.config.on_exception` (never raises, so the async adapter doesn't re-retry an already-exhausted job) then `fail!`s. Only `expects :url, :webhook_id, :body, :event, :attempt` — secret/curve/transport are read from `Outbound.config` at call time so nothing sensitive rides the job payload. An unexpected (non-network) exception is left unrescued and surfaces as a loud axn exception, the async adapter's at-least-once crash safety net.
- `Axn::Webhooks.outbound { … }` — the declaration surface: evaluates the block in `Outbound::DSL` (`sign`, `subscribers`, `max_attempts`, `backoff`, `transport`, `event name, to:, type:`) and installs a single process-global `Outbound::Config`. `Axn::Webhooks::Outbound.config` returns it (raising `Axn::Webhooks::Error` if `outbound` was never declared); `.reset!` clears it (for tests). `Config#targets_for(event)` resolves a static `to:` Array, else the block-level `subscribers` resolver, else `[]` — and raises `Axn::Webhooks::Error` listing known events for an unknown one; `#wire_type(event)` is the per-event `type:` override or the event name; `#max_attempts`/`#backoff` default to 8 attempts and a capped exponential curve; a statically empty `to: []` warns (not raises) at boot. `lib/axn/webhooks/outbound.rb` is now the umbrella requiring the Signer/Envelope/Transport/Config/DSL files.
- `Axn::Webhooks::Outbound::Transport` — the injectable HTTP seam: `.post(url:, body:, headers:, open_timeout: 5, read_timeout: 10) → Transport::Response` (`Data.define(:status, :headers)`), backed by stdlib `net/http` so the gem gains no new runtime dependency. `RETRYABLE_NETWORK_ERRORS` names the exception classes callers treat as retryable when raised by a transport (`Timeout::Error`, connection/DNS/IO errors); a consuming app may inject its own object with the same `.post` signature (e.g. Faraday-backed) via Outbound config.
- `Axn::Webhooks::Outbound::Envelope` — builds the Standard Webhooks message body (`.build(id:, type:, data:, now:) → String`, a `{id,timestamp,type,data}` JSON string) and its idempotency id (`.new_id → "msg_<uuid>"`). Deliberately decoupled from signing: the body is fixed at emit time (part of the dedup identity), while the signature is recomputed per delivery attempt.
- `Axn::Webhooks::Outbound::Signer` — builds a `#call(id:, timestamp:, body:) → Hash` signer from a `sign` declaration. The `:standard_webhooks` strategy is the outbound face of the inbound `verify :standard_webhooks` (same `whsec_` secret, `id.timestamp.body` HMAC, `v1,<base64>` signature), so a receiver already verifying Standard Webhooks accepts it; a custom block is called verbatim and must return the header hash itself.
- `Axn::Webhooks::Response.json(body, status:, headers:)` and `RespondContext#json` — a synchronous
  JSON response body for inbound `respond` blocks, alongside the existing `ack`/`text`/`xml`. Accepts
  a Hash/Array (JSON-encoded) or a pre-serialized String; sets `content-type: application/json`.
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
- `Axn::Webhooks::Inbound::DSL#static_respond` — a webhook response body that does not read the
  handler's result (its block takes no arguments, unlike `respond`), so it renders on every
  non-error dispatch outcome: sync success, async enqueue, `otherwise: :ack`, and business
  `fail!`. Unlike `respond`, declaring it never forces sync dispatch and is compatible with
  explicit `mode: :async`. Mutually exclusive with `respond` (raises at registration if both are
  declared). Fixes the README's DropboxSign example, which was wrong for any consuming app with
  an axn async adapter configured.
- `unit:` option on `replay:` (`verify :hmac`) and on `Signature.hmac`/`.within_tolerance?` directly — `:auto` (default, see below), `:seconds`, `:ms`/`:milliseconds`, or `:microseconds`. Vendors sending epoch milliseconds (Lob) or finer resolutions no longer need a hand-rolled `timestamp[0, 10]`-style slice to fake seconds; the raw epoch value is divided by the unit's divisor before the tolerance comparison. A `Time` timestamp ignores `unit:` (already unambiguous); an unrecognized `unit:` raises `ArgumentError` immediately, regardless of timestamp type. `verify :hmac`'s `replay:` hash now also raises `ArgumentError` for any key outside `timestamp`/`within`/`unit` — a typo (e.g. `units:`) previously fell silently back to `unit: :seconds`, quietly failing verification for every epoch-ms vendor with zero diagnostic.

### Changed
- `unit:` now defaults to **`:auto`**, inferring the timestamp's scale from its magnitude, rather than
  to `:seconds`. A single declared unit cannot express a vendor that sends more than one, and Lob does:
  real deliveries arrive through Svix as 10-digit epoch seconds, while its dashboard's debug send emits
  13-digit milliseconds. Pinning either one breaks the other — `unit: :ms` puts every Svix delivery in
  January 1970, a ~56-year skew that 401s the request before the HMAC even runs, which is what took
  Lob's live traffic down (os-app#5128) and forced a `timestamp[0, 10]` slice back into consumer config.
  Inference is unambiguous: seconds, milliseconds and microseconds sit 1000× apart and their
  plausible-date bands don't overlap (a 13-digit value read as seconds is the year 58,601), so the
  bands are `< 1e11` → seconds, `< 1e14` → ms, else microseconds. It cannot widen what's accepted —
  a wrong-scale reading of any timestamp lands ~56 years from now, which no realistic tolerance
  admits — so no stale timestamp becomes acceptable by being reinterpreted. A correctly-configured
  `unit: :seconds` endpoint is unaffected; the only behavior change is that a millisecond or
  microsecond sender now verifies instead of silently 401ing. An explicit `unit:` still works and is
  now a deliberate lockdown: pin a vendor to one scale and a change in what it sends fails loudly
  rather than being absorbed. An explicit `unit: nil`/`false` (e.g. an unset env var) still raises
  `ArgumentError` rather than falling back to the default.
- `Signature.mismatched_unit(timestamp:, tolerance:, now:, unit:)` — returns the unit that *would*
  have put a rejected timestamp inside the window, or `nil` when the configured unit already fits,
  the timestamp is missing/unparseable, or no scale rescues it. `nil` therefore means a genuine
  replay and a symbol means a misconfigured `unit:`. Pure and side-effect-free — it logs nothing and
  classifies nothing on its own; it exists for the verify-failure diagnostics to build on.
- `Axn::Webhooks::Error` now includes `Axn::Error`, core's public-error boundary, so a consuming app's
  `rescue Axn::Error` catches this gem's errors alongside core's (and `RetryLater` with them — the tag
  is inherited). `Axn::Error` is a marker module rather than a base class, so the hierarchy is
  unchanged: `Error` is still a plain `StandardError`, nothing gains ancestry, and every existing
  `rescue Axn::Webhooks::Error` / `rescue Axn::Webhooks::RetryLater` behaves exactly as before.
- The `axn` dependency floor is now `>= 0.1.0-alpha.5` (was `>= 0.1.0-alpha.4.3`) — the first release
  carrying the three axn APIs this gem had been tracking off `main`: `Axn::Error`,
  `Axn.config.default_async?`, and `Axn::Extensions.best_effort`. `Axn::Error` in particular is a
  load-time dependency (`Axn::Webhooks::Error` includes it), so an older axn raised
  `uninitialized constant Axn::Error` while requiring the gem rather than failing lazily. The
  development `Gemfile`'s temporary `github: "teamshares/axn", branch: "main"` pin is dropped
  accordingly (both the gem's own Gemfile and `spec_rails/dummy_app`'s); axn now resolves from
  RubyGems.
- The packaged gem now ships an allowlist of paths (`lib/`, `README.md`, `CHANGELOG.md`,
  `LICENSE.txt`, and `AGENTS-consuming.md` if ever written) rather than filtering a denylist. Dev
  artifacts that previously rode along — `AGENTS.md`, the `CLAUDE.md` symlink, and `Rakefile` — are
  no longer in the released `.gem`; nothing under `lib/` changed, so runtime behavior is unaffected.
  Matches the shared convention in axn core, where a growing exclude list kept leaking new dev files.
- Added `rack` (`>= 3.0`, `< 4`) as a runtime dependency. The gem requires Rack 3 (`Response#to_rack`'s
  lowercase header keys are required by Rack 3's SPEC), which means Rails 7.1+ (the first Rails
  whose actionpack allows Rack 3); Rails 7.0 (Rack 2 only) is not supported.
- Clearer README intro and gemspec description, with explicit mention of dispatch.
- Removed unnecessary rubocop pragma from dispatch parse example.

### Fixed
- `Outbound::Deliver#report_exhaustion` now passes the running `Deliver` INSTANCE (`self`), not the
  class, as `action:` to `Axn.config.on_exception` — matching axn's own internal convention (the
  action instance, not its class) and the instance-only state (`action.result`) axn's
  `on_exception` relies on to enrich the report; the configured reporter (e.g. Honeybadger) also
  receives the real instance rather than a bare `Class` object.
- `Outbound::Deliver#call`'s retryable-network rescue is now scoped to ONLY the `post` (HTTP) call,
  not the whole method body. Previously the method-level `rescue *Transport::RETRYABLE_NETWORK_ERRORS`
  also wrapped `retry_or_exhaust!`'s own `call_async` reschedule call — so if the async adapter
  (e.g. Redis/Sidekiq) raised a `Timeout::Error`/`IOError` while ENQUEUING the follow-up job, that
  enqueue failure was misinterpreted as another delivery network error and `retry_or_exhaust!` ran
  a second time in the same attempt (a duplicate enqueue), instead of propagating. An enqueue
  failure from `call_async` now always propagates as a loud exception outcome — the current job
  goes un-acked and the async adapter's own retry path handles the outage (at-least-once), matching
  the documented crash-safety-net contract for unexpected exceptions.
- `Outbound::Config#targets_for` now actually invokes a per-event `to:` lambda
  (`event :x, to: ->(event){ [...] }`), arity-aware like the inbound `Resolvers.resolve` (a
  0-arity proc is called with no args, else called with the event). Previously `spec[:to]` being a
  truthy `Proc` short-circuited `Array(list)`, wrapping the Proc itself in a single-element array
  and handing it to `Deliver` as a bogus delivery `url` — the documented "`to:` accepts a static
  Array OR a lambda" contract was silently broken. The block-level `subscribers` fallback is now
  invoked the same arity-aware way for consistency (a `->(event){...}` still works as before).
- `Outbound::Deliver#parse_retry_after` now also parses the HTTP-date form of `Retry-After`
  (RFC 7231, e.g. `"Wed, 21 Oct 2015 07:28:00 GMT"`, sent during maintenance windows), not just
  integer-seconds. It's parsed via stdlib `Time.httpdate` (`require "time"`, no new runtime
  dependency) and converted to the remaining seconds, clamped to `>= 0`. Previously an HTTP-date
  Retry-After failed to parse and silently fell back to the computed backoff, retrying earlier than
  the server asked for.
  (5xx/429/network error) occurs with no async adapter configured. Previously it unconditionally
  called `self.class.call_async` to reschedule, which raises a `NotImplementedError` (a
  `ScriptError`, not rescued by axn's `StandardError`-only exception boundary) — escaping `Deliver`,
  escaping `Outbound::Emit`'s per-target fan-out loop, and aborting delivery to any remaining
  targets. `Deliver` now checks adapter presence first (mirroring inbound `Dispatch`'s own
  `self.class._async_adapter` / `Axn.config.default_async?` check, never branching on
  adapter type): with no adapter configured, a retryable failure is now treated like an exhausted
  retry budget — reported once via `Axn.config.on_exception`, then `fail!`s quietly — matching the
  documented best-effort, no-cross-process-retries promise of the synchronous fallback path.
  Also: `Outbound::Emit`'s sync-fallback warning now logs once per `emit` call, not once per
  resolved target, so a high-fan-out event no longer spams one warn line per subscriber.
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
- `Outbound::Config#targets_for` no longer falls back to the block-level `subscribers` resolver
  when an event DECLARES a per-event `to:` resolver that itself resolves to `nil` (e.g. a DB lookup
  finding no recipients for this event). A declared `to:` — static Array (including `[]`) or
  callable — now always wins, wrapping its (possibly `nil`) result in `Array(...)`; `subscribers`
  is consulted only when the event declared no `to:` at all. Previously a declared resolver
  returning `nil` silently fell through to the default audience, sending the webhook to
  subscribers the event's own `to:` explicitly meant to exclude.
- `Outbound::Deliver` now looks up the `Retry-After` response header case-insensitively instead of
  assuming the stdlib net/http lowercase-keyed form. `Transport` is a public injectable seam — a
  custom transport (e.g. Faraday-backed) may return a plain Hash with `"Retry-After"` or
  `"RETRY-AFTER"` — and HTTP header names are case-insensitive, so the previous exact-key lookup
  silently missed the server's requested delay on such transports and retried on backoff alone.
- `Outbound::Config#wire_type` now stringifies a per-event `type:` override the same way it already
  stringifies the default (event-name) branch. A non-String override (e.g. `event :invoice_paid,
  type: :invoice_paid`) was previously returned unchanged, and `Emit` passes it straight through as
  `event:` to `Deliver`, whose `expects :event, type: String` rejected it — so a Symbol (or other
  non-String) `type:` override made the event undeliverable.
- `Outbound::Deliver`'s exhaustion report now runs from an `on_failure` callback
  (`report_exhaustion_if_needed`, gated on a new `@exhaustion_error` ivar set only by
  `retry_or_exhaust!`'s exhaustion branch) instead of being called inline immediately before
  `fail!`. Previously `Axn.config.on_exception(error, action: self, ...)` ran BEFORE `fail!` had
  settled the result, so a reporter reading `action.result` (as axn's own `on_exception` does, and
  as a real reporter like Honeybadger may) observed a pre-finalized, still-`ok?` result — undercutting
  the entire point of handing it the action instance. `on_failure` only fires on `fail!` (never on
  an unhandled exception) and axn dispatches it after `@context.__record_exception` has already
  marked the context failed, so the reporter now sees the genuine, finalized failure it exists to
  describe. The gate ensures a permanent-4xx `fail!` (which also triggers `on_failure`, but never
  sets `@exhaustion_error`) does not report.
