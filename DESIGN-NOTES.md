# axn-webhooks — design notes & gotchas

The [README](README.md) is the whole API. This document is the *why* behind the parts most likely to
surprise you, plus the traps worth naming. Nothing here is required reading to use the gem.

**Contents:** [Rails autoloading](#rails-autoloading-in-initializers) ·
[URL-signing verifiers](#url-signing-verifiers) ·
[Don't return an `Axn::Result` from `verify`](#dont-return-an-axnresult-from-a-verify-block) ·
[Basic auth is two-legged](#basic-auth-is-two-legged) ·
[Why unparseable bodies ack 200](#why-unparseable-bodies-ack-with-200) ·
[Async posture](#async-posture-auto-vs-explicit) ·
[Credentials and the queue](#credentials-never-enter-the-queue) ·
[Two timestamps](#two-timestamps-deliberately-different) ·
[Routing is sender-owned](#routing-is-sender-owned-config) ·
[Dimensions vs tags](#observability-dimensions-vs-tags)

## Rails autoloading in initializers

<sub>README: [Declaring an endpoint](README.md#declaring-an-endpoint)</sub>

`inbound`/`outbound` blocks are evaluated where they're declared — at boot, if that's an initializer
— and Rails disallows autoloading during initialization. Naming a class from `app/` while the
initializer runs raises `NameError` and fails the boot.

Handler classes are already safe: `dispatch to:` accepts a String, resolved per request. A custom
`verify` block needs the same treatment — keep the constant *inside* the block, which runs per
request:

```ruby
# NameError at boot — the constant is named while the initializer runs
checker = MyApp::SignatureChecker.new(secret: ENV.fetch("SECRET"))
Axn::Webhooks.inbound(:vendor) { verify { |req| checker.call(req) } }

# Fine — the constant is named when a request arrives
Axn::Webhooks.inbound(:vendor) do
  verify { |req| MyApp::SignatureChecker.verify(req, secret: ENV.fetch("SECRET")) }
end
```

## URL-signing verifiers

<sub>README: [Verifying](README.md#verifying) · [The request object](README.md#the-request-object)</sub>

Some vendors — Twilio most notably — sign the **request URL** rather than the body, and compare
against the URL as registered in their dashboard. Two properties of `Request#url` will bite.

**A mount whose path is the whole route adds a trailing slash.** Rack puts the mount point in
`SCRIPT_NAME` and leaves `PATH_INFO` as `"/"` for a request matching it exactly:

```ruby
mount Axn::Webhooks::Inbound[:twilio], at: "/webhooks/twilio"

# vendor POSTs to https://example.com/webhooks/twilio
req.url   # => "https://example.com/webhooks/twilio/"             <- note the slash
# ...and with a query string:
req.url   # => "https://example.com/webhooks/twilio/?callId=42"
```

The vendor signed the URL *without* that slash, so passing `req.url` straight to a validator rejects
every request — which reads in the logs exactly like a rotated secret. Split on the query, then chomp
the path:

```ruby
path, query = req.url.split("?", 2)
signed_url = [path.chomp("/"), query].compact.join("?")
```

Chomping the whole URL is **not** equivalent: it strips nothing when a query string is present, which
is precisely the case a status-callback URL (`…/update?callId=N`) exercises. Regex-matching `/` before
`?`-or-end isn't either — the leftmost match lands in the *query* for something like `?redirect=a/`.

A mount at a prefix (`at: "/webhooks"`, vendor posts `/webhooks/twilio`) leaves a non-`"/"`
`PATH_INFO` and so has no slash to strip, making the form above a no-op there — so it's safe to apply
unconditionally, **as long as the URL registered with the vendor doesn't itself end in `/`**. Both
cases produce a `req.url` ending in `/` and are indistinguishable at this layer, but one should be
chomped and the other must not be. Register the webhook URL without a trailing slash and it doesn't
come up.

**`url` reflects the scheme and host the proxy reported.** It comes from `Rack::Request#url`, so a CDN
or load balancer added in front, a change in `X-Forwarded-Proto` handling, or a new domain changes
what actually gets verified. The only symptom is `:signature_mismatch` on every request — again
indistinguishable from a rotated secret, so it's worth naming in whatever alerts on `reason`.

None of this applies to body-signing verifiers (`:hmac`, `:standard_webhooks`), which never read `url`.

## Don't return an `Axn::Result` from a `verify` block

<sub>README: [Custom `verify` blocks](README.md#custom-verify-blocks)</sub>

In an axn-consuming app the instinct is to put the check in an action. But the contract is read as
`check.is_a?(Signature::Check) ? check.ok? : !!check` — and an `Axn::Result` is neither a `Check` nor
a boolean, and is **truthy even when `ok?` is false**. A verifier returning one reports every rejected
request as verified and dispatches it, with no verify failure recorded anywhere.

If the logic belongs in an action, call it from the block and translate to a `Check`. Usually it
doesn't need to be an action at all: `Verify` is already the Axn boundary for this stage — it owns the
`expects`/`exposes` contract, the `sensitive:` redaction of the verifier, the `reason` dimension, and
the exception report. That's why both built-in strategies are a plain class and a lambda rather than
actions.

## Basic auth is two-legged

<sub>README: [`verify :basic_auth`](README.md#verify-basic_auth)</sub>

A client that doesn't authenticate preemptively — **Twilio is one** — sends its first request with no
`Authorization` header, expects a `401` carrying `WWW-Authenticate: Basic realm="…"`, and only then
repeats the request with credentials. Return a bare 401 and that retry never comes: every webhook is
dropped, and it reads as an ordinary stream of auth failures rather than an outage.

`verify :basic_auth` owns that challenge, along with constant-time comparison and fail-closed behavior
on a missing or blank credential (comparing against `""` would authenticate `Authorization: Basic Og==`
for anyone, and CI and secret managers can both set an empty string).

That bare first leg is **not** a verification failure — there's nothing to verify. It's answered before
`verify` runs at all, so it records nothing; without that, the highest-volume outcome on a healthy
Basic-auth endpoint would be a recorded failure, and a cross-vendor monitor on verify failures couldn't
tell a stream of them from an outage.

A custom block doesn't know which requests those are, so declare both halves yourself:

```ruby
Axn::Webhooks.inbound :vendor do
  verify { |req| my_own_check(req) }
  unauthorized_headers "WWW-Authenticate" => %(Basic realm="Webhook")
  challenge_required { |req| req.header("Authorization").to_s.strip.empty? }
end
```

The two go together: an endpoint that requires a challenge but has none to send raises at boot, since
challenging a client with nothing drops every request forever and records nothing about it.
`Endpoint#challenge_required?(request)` is public for callers driving `#verify`/`#handle` themselves —
those two stay honest about a bare request (it does not verify), so answer the challenge first.

Twilio [recommends signature verification over Basic auth](https://www.twilio.com/docs/usage/webhooks/webhooks-security);
so do we. It's one request rather than two, and it authenticates the *payload* rather than merely the
caller.

## Why unparseable bodies ack with 200

<sub>README: [Unparseable bodies](README.md#unparseable-bodies)</sub>

2xx is the only answer every vendor reads as "stop redelivering". Lob retries non-2xx for 5 days and
then disables the endpoint; Stripe, Slack and Shopify all retry non-2xx too, and the last two also
disable an endpoint after sustained failures. So a semantically tidy 400 buys a retry loop from most
senders for a body that can never parse.

Set `400` for a vendor that does honor 4xx as terminal (nicer status codes in their delivery
dashboard), or `500` to restore retry-inviting behavior. A declared `static_respond` still renders
here — Dropbox Sign and friends key the ack on the body text, not the status.

## Async posture: `:auto` vs explicit

<sub>README: [Sync vs async](README.md#sync-vs-async) · [Per-call overrides](README.md#per-call-overrides)</sub>

Three behaviors that look inconsistent side by side:

| | No adapter configured |
| -- | -- |
| inbound `mode: :auto` | runs sync |
| inbound `mode: :async` (or a route marked `async`) | reported exception → 500 |
| `emit(…)` (defaults to `:auto`) | warns once per emit, runs sync |
| `emit(…, async: true)` | raises |

They line up once you read `emit`'s default as `:auto`: **a missing adapter degrades to sync only
under `:auto`, never under an explicit request.**

Downgrading an explicit `async` would be wrong twice over. `async` is usually declared *because* the
handler outlives the vendor's ack window (Slack's 3s), so running it inline trades a clean 500 for a
vendor timeout, a redelivery, and duplicate processing. And it changes the response the vendor sees:
the async path acks with no handler result, while the sync path renders one — a handler `fail!`
included.

It's the same no-silent-downgrade stance outbound's `to:` takes: a *declared* resolver that returns
nil delivers nowhere rather than falling back to `subscribers`.

## Credentials never enter the queue

<sub>README: [Per-subscriber secrets and headers](README.md#per-subscriber-secrets-and-headers)</sub>

`Deliver` re-enqueues *itself* on a retry, so anything in its `expects` is persisted, plaintext, in the
queue backend (Redis for Sidekiq) for the life of the retry chain — `max_attempts` × the backoff curve,
hours by default.

So `Deliver` only ever carries a subscriber's **identity** (`subscriber_id`, a String). `sign`'s secret
and the `headers` resolver are called fresh **per delivery attempt** from that identity. This is also
why there is no per-emit `headers:` override: it's the obvious place to hang a bearer token, and it
would ride the payload for the whole retry lifetime.

> **This covers separately-resolved values only.** `Deliver` *does* carry `url:` — so a credential a
> receiver embeds in its own webhook URL (a Slack/Discord/Teams-style secret path segment, or a signed
> query token) is persisted for that same lifetime.

## Two timestamps, deliberately different

<sub>README: [`sign :standard_webhooks`](README.md#sign-standard_webhooks)</sub>

**Signing happens per attempt.** Each retry recomputes the signature with a fresh `webhook-timestamp`
header, so it lands inside the receiver's replay-tolerance window, while reusing the same `webhook-id`
from the first attempt, so the receiver can still dedup.

The envelope body's own `timestamp` field, by contrast, is fixed at emit time — it's part of the dedup
identity. So a retried delivery's signed header and its body field deliberately diverge. Read the
header as "when this attempt was signed", not the body's "when this event happened".

## Routing is sender-owned config

<sub>README: [Subscriber rows](README.md#subscriber-rows)</sub>

The event→targets map lives in each *sending* app's own `outbound` block, not in this gem. A
general-purpose DB-backed self-registration store — where receivers register their own endpoint URLs
at runtime, no deploy required — is a real future shape, but it's **intentionally deferred until a
real use-case justifies it**.

The `subscribers`/`to:` lambda is the seam it slots into with no API change: both are resolved fresh on
every `emit`, so swapping the lambda body for a DB lookup already picks up runtime changes, and the
`{ url:, id: }` row shape already carries the identity per-subscriber secrets and headers key off of.

## Observability: dimensions vs tags

<sub>README: [Per-vendor observability](README.md#per-vendor-observability)</sub>

`event` and `vendor` are stamped as **dimensions** — axn's bounded metrics facet. A resolved
`subscriber_id` is stamped as a **tag** (the high-cardinality log/trace facet), never a dimension: a
subscriber id off a live table is unbounded, and stamping it as a dimension would quietly blow past a
metrics backend's cardinality limits the first time a real subscriber table is wired up.
