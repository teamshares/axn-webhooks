# axn-webhooks

Webhook handling for [axn](https://github.com/teamshares/axn), both directions, on one signature primitive:

* **Inbound** — verify a vendor's signature, dispatch the event to a handler action, and acknowledge — declared per vendor, and runnable in or out of Rails.
* **Outbound** — declare your own events and subscribers, and emit signed, self-retrying deliveries — declared once per sending app.

## Installation

Add to your Gemfile:

```ruby
gem "axn-webhooks"
```

## Signature primitive

`Axn::Webhooks::Signature` is a standalone, Rails-agnostic HMAC verifier:

```ruby
Axn::Webhooks::Signature.hmac(
  secret:    ENV["WEBHOOK_SECRET"],
  payload:   request.raw_body,                 # exact bytes the vendor signed
  signature: request.header("X-Signature"),
  digest:    :sha256,                           # :sha256 (default) | :sha1 | :md5
  encoding:  :hex,                              # :hex (default) | :base64 | :base64_urlsafe
  prefix:    nil,                               # e.g. "v0=" for Slack
  timestamp: request.header("X-Timestamp"),     # optional replay guard
  tolerance: 300,
)
```

It always uses a constant-time comparison and supports multi-signature (key-rotation) headers.

`hmac` answers *whether* a request verified. `hmac_check` answers *why* it didn't — same check,
returning an `Axn::Webhooks::Signature::Check` instead of a boolean (`hmac` is literally
`hmac_check(...).ok?`, so there is only ever one replay window and one comparison):

```ruby
check = Axn::Webhooks::Signature.hmac_check(secret:, payload:, signature:, timestamp:, tolerance: 300)
check.ok?            # => false
check.reason         # => :replay_window
check.skew           # => 10_000  (seconds, signed: positive = in the past; only for :replay_window)
check.suggested_unit # => nil     (a Symbol only when a pinned `unit:` is what missed the window)
```

`mismatched_unit` answers that last question on its own — the scale that *would* have put a
timestamp inside the window, or `nil` when the configured `unit:` already fits, the timestamp is
missing/unparseable, or no scale rescues it. Side-effect-free, so a caller decides what to do with it
(`hmac_check` uses it to fill `suggested_unit`):

```ruby
Axn::Webhooks::Signature.mismatched_unit(timestamp:, tolerance: 300, unit: :seconds)  # => :ms
```

### Replay protection

Pass `timestamp:` and `tolerance:` to guard against replayed requests — `hmac` returns `false` if
the timestamp is more than `tolerance` seconds from now, in either direction. Epoch seconds,
milliseconds and microseconds are all handled without configuration:

```ruby
Axn::Webhooks::Signature.hmac(
  secret:, payload:, signature:,
  timestamp: request.header("X-Timestamp"),  # epoch s, ms or µs — inferred per timestamp
  tolerance: 300,
)
```

`unit:` defaults to `:auto`, which reads the scale off each timestamp's magnitude. The three scales
sit 1000× apart and their plausible-date ranges don't overlap — a 13-digit value read as seconds is
the year 58,601 — so inference is unambiguous for anything a vendor could legitimately send. It also
can't widen what's accepted: a misread lands ~56 years off, which no realistic tolerance admits.

This matters for vendors that send **more than one** unit. Lob delivers epoch seconds through Svix
and epoch milliseconds from its dashboard's debug send; no single fixed unit is correct for it.

Pass `unit:` explicitly to pin a vendor to one scale, so a change in what it sends fails loudly
instead of being absorbed:

```ruby
Axn::Webhooks::Signature.hmac(
  secret:, payload:, signature:,
  timestamp: request.header("X-Timestamp"),
  tolerance: 300,
  unit:      :ms,   # :auto (default) | :seconds | :ms | :milliseconds | :microseconds
)
```

`unit:` only describes the resolution of the incoming `timestamp:` — `tolerance:`/`within:` is
always in seconds, regardless of `unit:`. A `Time` timestamp ignores `unit:` entirely (it's already
unambiguous). An unrecognized `unit:` raises `ArgumentError` immediately, even when `timestamp:`
happens to be a `Time` — the unit is validated before the timestamp is inspected.

The same `unit:` option is available on `verify :hmac`'s `replay:` hash, and is equally optional:

```ruby
Axn::Webhooks.inbound :lob do
  verify :hmac, secret: ENV.fetch("LOB_WEBHOOK_SECRET"), signature: header("X-Lob-Signature"),
                replay: { timestamp: header("X-Lob-Signature-Timestamp"), within: 300 }
end
```

## Inbound endpoints

Declare each vendor webhook in one place (e.g. a Rails initializer). The symbol you pass to
`inbound` is the vendor's name — pick whatever you'll reference it by:

```ruby
# Codat — Standard Webhooks (Svix) preset
Axn::Webhooks.inbound :codat do
  verify :standard_webhooks, secret: ENV.fetch("CODAT_WEBHOOK_SECRET")
end

# Merge (merge.dev) — parametric HMAC
Axn::Webhooks.inbound :merge_dev do
  verify :hmac,
    secret:    ENV.fetch("MERGE_WEBHOOK_SIGNATURE_KEY"),
    signature: header("X-Merge-Webhook-Signature"),
    encoding:  :base64_urlsafe
end

# Twilio — custom verifier delegating to the vendor SDK
Axn::Webhooks.inbound :twilio do
  verify { |req| Twilio::Security::RequestValidator.new(ENV.fetch("TWILIO_AUTH_TOKEN"))
                   .validate(req.url, req.params, req.header("X-Twilio-Signature")) }
end

# A vendor gated by HTTP Basic auth rather than a signature
Axn::Webhooks.inbound :legacy_vendor do
  verify :basic_auth,
    username: -> { ENV.fetch("WEBHOOKS_AUTH_USERNAME") },
    password: -> { ENV.fetch("WEBHOOKS_AUTH_PASSWORD") },
    realm:    "Webhook"   # optional; appears in the WWW-Authenticate challenge
end
```

#### A note on `verify :basic_auth`

Basic auth is a two-legged protocol, and the second leg is easy to lose. A client that doesn't
authenticate preemptively — **Twilio is one** — sends its first request with no `Authorization`
header, expects a `401` carrying `WWW-Authenticate: Basic realm="…"`, and only then repeats the
request with credentials. Return a bare 401 and that retry never comes: every webhook is dropped,
and it reads as an ordinary stream of auth failures rather than an outage.

`verify :basic_auth` owns that challenge for you, along with constant-time comparison and
fail-closed behaviour on a missing or blank credential (comparing against `""` would authenticate
`Authorization: Basic Og==` for anyone, and CI and secret managers can both set an empty string).
If you hand-roll Basic auth in a custom `verify` block instead, declare the challenge yourself:

```ruby
Axn::Webhooks.inbound :vendor do
  verify { |req| my_own_check(req) }
  unauthorized_headers "WWW-Authenticate" => %(Basic realm="Webhook")
end
```

That bare first leg is **not** a verification failure — there is nothing to verify. It's answered
with the challenge before `verify` runs at all, so it records nothing: without that, the
highest-volume outcome on a healthy Basic-auth endpoint would be a recorded failure, and a
cross-vendor monitor on verify failures couldn't tell a stream of them from an outage. The request
still gets the same `401` and still can never reach a handler.

`verify :basic_auth` knows which requests those are. A custom block doesn't, so say so — the same
way you declare its challenge, and with the same precedence (a declaration wins):

```ruby
Axn::Webhooks.inbound :vendor do
  verify { |req| my_own_check(req) }
  unauthorized_headers "WWW-Authenticate" => %(Basic realm="Webhook")
  challenge_required { |req| req.header("Authorization").to_s.strip.empty? }
end
```

The two go together: an endpoint that requires a challenge but has none to send raises at boot —
whether the predicate came from a `challenge_required` declaration or from a custom verifier's own
`#challenge_required?` — since challenging a client with nothing drops every request forever and,
now that answering the challenge skips `verify`, records nothing about it.

`Endpoint#challenge_required?(request)` is public for callers who drive `#verify`/`#handle`
themselves rather than mounting the endpoint: those two stay honest about a bare request (it does
not verify), so answer the challenge before asking them.

Prefer signature verification where the vendor offers it: it's one request rather than two, it
authenticates the *payload* and not merely the caller, and it needs no challenge — Twilio
[recommends it over Basic auth](https://www.twilio.com/docs/usage/webhooks/webhooks-security) for
exactly these reasons.

Verify a request (dispatch/respond and HTTP mounting land in later phases):

```ruby
result = Axn::Webhooks::Inbound[:codat].verify(request)  # => Axn::Result
result.ok?  # signature valid?
```

### Why verification failed

A rejected request is always a bare 401 on the wire, but the *cause* is on the result and on the
call's log/metric line as a bounded `reason` dimension — so verify failures can be grouped and
alerted on separately rather than all reading as "signature mismatch":

```ruby
result.reason  # => :replay_window
result.skew    # => 10_000  (seconds, signed: positive = the timestamp is in the past)
result.error   # => "Webhook verification failed: replay window exceeded (timestamp skew 10000s)"
```

| `reason` | What it means | Usually caused by |
| -- | -- | -- |
| `:replay_window` | Validly-formed timestamp, outside the window. Carries `skew`. | A genuine replay or real clock drift — since `unit:` [infers the scale](#replay-protection), a wrong unit can only cause this if one was explicitly pinned |
| `:replay_timestamp_invalid` | The timestamp is absent or unparseable | A typo'd `replay: { timestamp: header(…) }` name, or a vendor that stopped sending it |
| `:signature_missing` | No signature header at all | A typo'd `signature:` header name, or an unsigned sender |
| `:signature_mismatch` | The HMAC genuinely didn't match | Wrong/rotated secret, or the wrong `signing_string` |
| `:credentials_missing` | `verify :basic_auth` only. An `Authorization` header that isn't a Basic credential. The bare first leg of the handshake is [challenged before verification](#a-note-on-verify-basic_auth) and never reaches here. | A client that meant to authenticate and used the wrong scheme, or a scanner |
| `:credentials_mismatch` | `verify :basic_auth` only. Credentials were offered and rejected. | Wrong/rotated `username:`/`password:`, or a scanner guessing |

A `:replay_window` rejection additionally carries **`suggested_unit`** — the scale that *would* have
put the timestamp inside the window (`Signature.mismatched_unit`), stamped as its own dimension:

```ruby
result.reason         # => :replay_window
result.suggested_unit # => :ms     -- nil for a genuine replay
result.error          # => "…: replay window exceeded (timestamp skew -1784947346919s) — would fit as unit: :ms"
```

Since `unit:` [infers the scale per timestamp](#replay-protection) by default, this is only ever
non-nil when a `unit:` was explicitly pinned and doesn't fit. Its **presence** splits the
misconfigured half of `:replay_window` from the genuine half — a group-by that says "this endpoint's
pinned `unit:` is wrong" rather than "someone is replaying us" — and its **value** names the fix.

The built-in `:hmac` and `:standard_webhooks` strategies report all four reasons above. A **custom `verify` block**
keeps the documented `->(request) { Boolean }` contract — a falsey return is reported as
`:signature_mismatch`. To name its own cause, a custom block may return a
`Axn::Webhooks::Signature::Check` (e.g. by delegating to `Signature.hmac_check`) instead of a boolean.

### The request object

Verifiers, `parse:`, and `challenge` blocks all receive an `Axn::Webhooks::Request` — a
Rails-agnostic view of the inbound request, so the same endpoint works behind a Rack mount, a
controller, or a plain test constructor:

| | |
|---|---|
| `raw_body` | the exact bytes the vendor signed (frozen; never re-encoded) |
| `header(name)` | case-insensitive header lookup |
| `params` | the request's **primary** param source (see below) |
| `url` | full URL including scheme, host, mount prefix, and query string |
| `http_method` | upcased (`"POST"`, `"GET"`, …) |

`params` is one source, never a query+form merge — `url` already carries the query string, and
merging both would double-count query params for URL-signing verifiers (Twilio's
`validate(req.url, req.params, sig)` HMACs it once via the url already):

- **POST with a form body** — `application/x-www-form-urlencoded` (Twilio) or
  `multipart/form-data` (Dropbox Sign, which posts the whole event in a single `json` field) →
  the form fields. A malformed multipart body yields `{}` rather than raising, so an unverified
  sender can't crash the pipeline ahead of `verify`.
- **Everything else** — JSON POST, and any GET/HEAD (the Nylas/Meta challenge handshake) → the
  query string.

`inspect`/`pp` redact `raw_body` and headers, since webhook payloads routinely carry bank
account numbers, credentials, and addresses that must not reach logs or exception reports.

### Dispatch to a handler

Add `dispatch` to route the (verified, parsed) event to a handler Axn. The body is parsed as
JSON by default (string keys) — pass `parse:` for other bodies. Handlers receive the whole
event as `event:`, or scalar args via a `with:` extractor (`with: :payload` is the rename-only
shorthand: the whole event, under that kwarg name instead of `event:`). A handler target may be a class-name
**string** or the **class itself** (`"Actions::Codat::ConnectionUpdated"` or
`Actions::Codat::ConnectionUpdated`) — both resolve the constant lazily at request time, so either
form stays reload-safe under Rails/Zeitwerk. Strings are the safe default when declaring endpoints in
an initializer, since they never force the handler to be autoloadable at boot.

```ruby
Axn::Webhooks.inbound :codat do
  verify :standard_webhooks, secret: ENV.fetch("CODAT_WEBHOOK_SECRET")
  dispatch on: ->(e) { e["eventType"] },
           to: { "connection.updated" => "Actions::Codat::ConnectionUpdated" },
           otherwise: :ack        # unknown-but-expected events: log + 2xx (omit to raise loudly)
end

# One endpoint, one handler; form-encoded body:
Axn::Webhooks.inbound :twilio do
  verify { |req| Twilio::Security::RequestValidator.new(ENV.fetch("TWILIO_AUTH_TOKEN"))
                   .validate(req.url, req.params, req.header("X-Twilio-Signature")) }
  dispatch to: "Actions::Twilio::HandleSms", parse: ->(req) { req.params }
end

result = Axn::Webhooks::Inbound[:codat].handle(request)  # verify + dispatch => Axn::Result
result.handler_result  # the handler's own Axn::Result (nil on ack / failure)
```

A missing handler class or an unmatched event with no `otherwise:` is reported to your
`Axn.config.on_exception` and returned as a failed result — never an unhandled exception.
Handlers run synchronously or asynchronously depending on `mode:` — see [Async dispatch](#async-dispatch) below.

### Respond with a custom body

By default a successful request gets a bare 2xx ack — most vendors want nothing else. Add
`respond` when the body itself depends on what the handler computed — an instruction body like
TwiML, or a JSON instruction body. The block receives the handler's own `Axn::Result` and runs
with `ack`/`text`/`xml`/`json` available as bare calls:

```ruby
# Twilio call-control: the handler computes TwiML; respond renders it.
Axn::Webhooks.inbound :twilio do
  verify { |req| Twilio::Security::RequestValidator.new(ENV.fetch("TWILIO_AUTH_TOKEN"))
                   .validate(req.url, req.params, req.header("X-Twilio-Signature")) }
  dispatch to: "Actions::Twilio::HandleCall", parse: ->(req) { req.params }
  respond { |result| xml(result.twiml) }   # handler exposes :twiml
end

# JSON instruction body: pass a Hash/Array (JSON-encoded) or a pre-serialized String.
Axn::Webhooks.inbound :slack do
  verify { |req| … }
  dispatch to: "Actions::Slack::HandleInteraction"
  respond { |result| json(result.response_action, status: 200) }   # handler exposes :response_action
end
```

`respond` only runs for a genuine handler success — an unmatched event acked via
`otherwise: :ack`, a handler's own business `fail!`, and a verify failure or crash all get
their own fixed status (see below) regardless of any declared `respond`. For a literal body
that doesn't need to read the handler's result — a fixed string the vendor requires no matter
how dispatch resolves — see `static_respond` below.

#### static_respond

For a body that must render regardless of how dispatch resolves — including async enqueue,
`otherwise: :ack`, and business `fail!` — use `static_respond` instead. Unlike `respond`, its
block takes **no arguments** (it never reads the handler's result), so declaring it does not
force sync dispatch and is compatible with explicit `mode: :async`:

```ruby
# DropboxSign requires this exact literal string, and DropboxSign's handler must run async
# (it makes outbound API calls) — static_respond renders regardless of dispatch outcome:
Axn::Webhooks.inbound :dropbox_sign do
  verify { |req| … }
  dispatch to: "Actions::DropboxSign::HandleWebhook"   # stays async under mode: :auto
  static_respond { text("Hello API Event Received") }
end

response = Axn::Webhooks::Inbound[:dropbox_sign].to_response(request)  # => Axn::Webhooks::Response
response.status   # => 200
response.body     # => "Hello API Event Received"
```

`respond` and `static_respond` are mutually exclusive — declaring both on one endpoint raises at
registration time.

### The staged HTTP outcome mapping

`Axn::Webhooks::Inbound[:vendor].to_response(request)` runs the whole pipeline and maps the
outcome to an HTTP status:

| Stage | Outcome | Status |
| -- | -- | -- |
| Verify | a rejected signature (see [Why verification failed](#why-verification-failed)), or the verifier itself crashes | 401 |
| Dispatch | missing/unresolvable handler, unmatched event with no `otherwise:`, or a handler crash | 500 (reported to `Axn.config.on_exception`) |
| Dispatch | the body doesn't parse | `unparseable_status` — **200** by default (still reported) |
| Dispatch | unknown-but-expected event (`otherwise: :ack`) | 2xx ack |
| Handle | the handler's own business `fail!` ("we don't care") | 2xx ack (logged) |
| Handle | success | the declared `respond` body, or a bare 2xx ack |

A declared `static_respond` renders on every row above except the 401 row and the 500 row — and,
not shown in the table above, a `retry_later!` 503 — including `otherwise: :ack`, business
`fail!`, a genuine handler success with no `respond` declared, and an unparseable body (where it
renders under the configured status rather than its own).

### Async dispatch

By default (`mode: :auto`) a handler runs **async when it has an axn async adapter configured**
(an `async :sidekiq` / `async :active_job` on the handler, or a host-app global default), and
**sync otherwise** — so it works out of the box standalone and automatically uses async once you
wire an adapter up, the same way you would for any other axn. This gem never references a
specific adapter (`:sidekiq`/`:active_job`); it only checks whether one is present.

Pin a mode explicitly when you want to override the default:

```ruby
Axn::Webhooks.inbound :merge_dev do
  verify :hmac, secret: ENV.fetch("MERGE_WEBHOOK_SIGNATURE_KEY"), signature: header("X-Merge-Webhook-Signature")
  dispatch to: "Actions::MergeDev::HandleWebhook", mode: :async   # force async (handler must have an adapter)
end
```

A custom `respond` block reads the handler's own result, so those hooks always run **sync** (you
can't read a result you enqueued) regardless of adapter config — and declaring both an explicit
`mode: :async` and a custom `respond` raises at registration time.

`static_respond`, by contrast, never reads a result, so it never forces sync and is compatible
with an explicit `mode: :async` — it's the right choice for a vendor like DropboxSign that needs
both a literal ack body and an async handler.

#### Per-route sync/async on one endpoint

`mode:` is endpoint-wide, but a single fixed URL sometimes needs both disciplines per message —
the interaction-platform pattern (Slack, Discord, Telegram) multiplexes a synchronous body and
ack-then-async on one Request URL. Set a per-route `async:` on any explicit-map entry to override
just that route; the helpers `async(...)` / `sync(...)` build the entry for you (they're plain DSL
methods, so they're callable right inside the `to:` map):

```ruby
# Slack interactivity: one URL, one respond block, per-message discipline.
Axn::Webhooks.inbound :slack do
  verify :hmac, secret: ENV.fetch("SLACK_SIGNING_SECRET"), signing_string: ->(r) { "v0:#{r.header('X-Slack-Request-Timestamp')}:#{r.raw_body}" }
  dispatch on: ->(e) { e["type"] },
           to: {
             "view_submission" => "Actions::Slack::HandleViewSubmission",       # sync (respond default): returns a response_action body
             "block_actions"   => async("Actions::Slack::HandleBlockActions"),  # ack now, run async
           }
  respond { |result| json(result.response_action) }  # sync route renders JSON; async route auto-acks (bare 2xx)
end
```

`async("H")` is sugar for `{ call: "H", async: true }` and `sync("H")` for `{ call: "H", async: false }`;
both pass extra kwargs through, so they compose with a `with:` extractor: `async("H", with: ->(e) { … })`,
`sync("H", with: :payload)`.

The per-route flag is the most specific rung of the mode decision — precedence, most specific first:
the entry's `async:`, then an explicit endpoint `mode:`, then a declared `respond` (which keeps sync
as the per-route **default**), then `:auto` adapter detection. So on a `respond` endpoint a route is
sync unless you mark it `async` — a route that acks-async simply produces no result and the `respond`
block acks it (nil result → bare 2xx), while a sync route's result is rendered. A route marked
`async` whose handler has no adapter is reported as an exception (the same guard as `mode: :async`).

**Note on block scoping**: The `inbound do … end` block is evaluated with `instance_exec` against an internal DSL, so `self` inside the block is NOT the surrounding object. You can reference `ENV`, constants, and local variables, but don't call surrounding-object helper methods or access its instance variables from within the block.

### Mounting

An `Inbound[:vendor]` endpoint is a Rack app — mount it directly, no controller needed. The Rack
mount requires **Rack 3** (so **Rails 7.1+**); Rails 7.0 (Rack 2) is not supported.

```ruby
# config/routes.rb (Rails)
Rails.application.routes.draw do
  mount Axn::Webhooks::Inbound[:codat], at: "/webhooks/codat"
end
```

```ruby
# config.ru (no Rails)
require "axn-webhooks"
map "/webhooks/codat" { run Axn::Webhooks::Inbound[:codat] }
```

The mount owns the whole path and every verb: `POST` runs verify → dispatch → respond; `GET` runs
a declared `challenge`, or 405s if none was declared. Any other verb — including `HEAD` on a bare `Rack::Builder` mount without `Rack::Head` upstream — returns 405. (Rails inserts `Rack::Head` before middleware, so `HEAD` becomes `GET` there.)

### Challenge (GET-echo handshake)

Some vendors (Nylas, Meta) verify a new endpoint with a `GET` request before sending real events:

```ruby
Axn::Webhooks.inbound :nylas do
  verify { |req| ... }
  challenge ->(req) { req.params["challenge"] }   # echoed verbatim, 200 text/plain
end

Axn::Webhooks.inbound :meta do
  challenge ->(req) { req.params["hub.challenge"] },
            if: ->(req) { req.params["hub.verify_token"] == ENV.fetch("META_VERIFY_TOKEN") }
end
```

No extra `routes.rb` line is needed — `challenge` just teaches the same mount how to answer `GET`.
An `if:` guard rejection (e.g. a bad Meta `hub.verify_token`) is a **403**; a missing/nil challenge
value is a **400**; a `challenge`/`if:` proc that raises is reported and mapped to **500**. (Slack's
in-band `url_verification` handshake is NOT this — it's a normal `dispatch` entry, since Slack sends
it as a POST event, not a GET.)

### Unparseable bodies (`unparseable_status`)

A verified request whose body doesn't parse is **terminal, not retryable** — a redelivery of the same
bytes will never parse either. So the parse step reports (you want to know a vendor is sending
garbage) and then **acks**:

```ruby
Axn::Webhooks.configure { |c| c.unparseable_status = 400 }             # global; default 200

Axn::Webhooks.inbound :lob do
  verify :hmac, secret: ENV.fetch("LOB_WEBHOOK_SECRET"), signature: header("Lob-Signature")
  dispatch to: "Actions::Lob::HandleWebhook", unparseable_status: 200  # per-endpoint override
end
```

Whatever the `parse:` step raises is wrapped in `Axn::Webhooks::UnparseableBody` (the original stays
reachable as `cause`) and reported to `Axn.config.on_exception` exactly once — it's a real exception
outcome, just not one the vendor should act on. Because the whole step is wrapped rather than a list
of known JSON errors, a custom XML/form/protobuf `parse:` proc gets the same treatment without
knowing about this gem's error classes.

The default is **200** rather than the semantically tidier 400 because 2xx is the only answer every
vendor reads as "stop redelivering": Lob retries non-2xx for 5 days and then disables the endpoint,
Stripe, Slack and Shopify all retry non-2xx too, and the last two also disable an endpoint after
sustained failures. Set `400` for a vendor that does honor 4xx as terminal (nicer status codes in
their delivery dashboard), or `500` to restore the old retry-inviting behavior. A declared
`static_respond` still renders its body here — Dropbox Sign and friends key the ack on the body text,
not the status, so without it they'd redeliver anyway.

A `parse:` proc that does I/O (a lookup that could fail transiently) can opt back into redelivery by
raising [`retry_later!`](#asking-for-redelivery-retry_later) — that's the one thing the parse step
doesn't treat as terminal.

### Per-vendor observability (`vendor_facet`)

```ruby
Axn::Webhooks.configure { |c| c.vendor_facet = :dimension }  # or :tag; default false
```

When set, every `verify`/`dispatch`/`respond`/`challenge` call for a registered endpoint is stamped
with the endpoint's registered name as that Datadog/OTel facet — `:dimension` for a bounded,
low-cardinality grouping (Teamshares' choice); `:tag` for the higher-cardinality path. Ships `false`
(no stamping) so a standalone consumer opts in explicitly.

This setting governs the **vendor** facet only. `Verify`'s
[`reason` dimension](#why-verification-failed) is stamped unconditionally: it's a closed four-value
enum rather than a per-endpoint identity, so there's no cardinality decision to defer to the
consumer — group by `reason`, filter by `vendor`.

## Outbound (sending webhooks)

Declare your own events and their subscribers once (e.g. a Rails initializer), then emit by symbol
from wherever the triggering event happens:

```ruby
Axn::Webhooks.outbound do
  # Standard Webhooks signing (reuses Axn::Webhooks::Signature under the hood) — symmetric with
  # a receiver's own `verify :standard_webhooks`. A custom signer block is accepted in the same slot.
  sign :standard_webhooks, secret: ENV.fetch("WEBHOOK_SIGNING_SECRET")

  # Default subscriber resolver — the seam a future DB-backed subscription store slots into.
  # Any event declared with no explicit `to:` falls back to this.
  subscribers ->(event) { Subscription.urls_for(event) }

  event :lead_signed, to: ["https://example.com/webhooks/lead_signed"]  # static list
  event :lead_closed                                                    # no `to:` -> resolved via `subscribers`
  event :invoice_paid, type: "invoice.paid", to: ["https://example.com/webhooks/invoice_paid"]  # override the wire `type`

  max_attempts 8                                                # default shown
  backoff ->(attempt) { [30 * (3**(attempt - 1)), 6 * 3600].min } # default shown (seconds; capped at 6h)
  transport MyFaradayTransport                                  # optional; defaults to stdlib net/http
end

Axn::Webhooks.emit(:lead_signed, data: { lead_id: 42 })  # => Axn::Result
```

* **Symbols are the identity.** `emit(:unknown_event)` raises `Axn::Webhooks::Error` immediately,
  listing the known events — no silent no-op for a typo'd event name. A statically declared
  `event :x, to: []` warns at boot (it will deliver nowhere).
* **Wire `type`** defaults to the symbol as a string (`:lead_signed` → `"lead_signed"`), overridable
  per event with `type:` when a receiver expects a dotted convention or another exact value.
* **`to:`** accepts a static Array or a lambda (`->(event) { … }`); the block-level `subscribers`
  resolver is the shared default when an event declares no `to:` at all.
* **Fan-out**: `emit` resolves the event's subscribers and enqueues one independent, self-retrying
  `Axn::Webhooks::Outbound::Deliver` per target — one slow/failing subscriber can't block another.
  Each delivery gets its own stable `webhook-id`, generated once per (emission × target) and reused
  across every retry attempt of that delivery, so receivers can dedup.

### Envelope & signing

The body is the Standard Webhooks envelope; `id` and `timestamp` are mirrored into the signed
headers:

```
POST <subscriber-url>
webhook-id: msg_<uuid>
webhook-timestamp: 1721160000
webhook-signature: v1,<base64 hmac of "id.timestamp.body">
content-type: application/json
user-agent: axn-webhooks/<version>

{"id":"msg_<uuid>","timestamp":1721160000,"type":"lead_signed","data":{"lead_id":42}}
```

Receivers verify with the inbound half's `verify :standard_webhooks` — end-to-end symmetry, and
`id`/`timestamp` give idempotency + replay protection for free. **Signing happens per attempt**: each
retry recomputes the signature with a fresh `webhook-timestamp` (so it lands inside the receiver's
replay-tolerance window) while reusing the same `webhook-id` from the first attempt (so the receiver
can still dedup a redelivered message).

### Transport

The HTTP call is an injectable seam (`.post(url:, body:, headers:) -> Transport::Response`, a
`Data.define(:status, :headers)`). The default is stdlib `net/http` — no new runtime dependency — and
a consuming app can swap in its own object (e.g. Faraday-backed) via `transport` in the `outbound`
block.

### Async posture

Mirrors inbound's `:auto`: **async when an axn async adapter is configured** for `Deliver` (an
`async :sidekiq`/`async :active_job` global default, per axn's own presence-check semantics — never
a branch on adapter type), else a **synchronous inline fallback** so the gem works standalone without
Sidekiq. The sync path is best-effort: no cross-process retries/backoff, and it logs a warning (once
per `emit` call, not once per subscriber) so the degraded mode is never silent.

### Delivery contract

Each delivery attempt classifies the receiver's response. This is the canonical contract — useful
both for reading this gem's `Deliver` behavior and for a single-side (non-gem) implementer of either
half:

| Receiver responds | Delivery does |
| -- | -- |
| **2xx** | success |
| **5xx, 429, 503 + `Retry-After`, timeout, connection error** | retryable → self-reschedule the next attempt |
| **other 4xx** (400, 401/403 bad-sig/auth, 404, 410 Gone, 422) | permanent → quiet `fail!`, no retry (a silent business failure surfaced via the `Deliver` result + axn's routine outcome logging, NOT via `on_exception`) |
| **unexpected exception** (crash / OOM / network raise mid-flight) | propagates → adapter retries the un-acked job (at-least-once safety net) |

**One self-managed retry engine, adapter-agnostic.** On a retryable response, `Deliver` computes its
own delay and re-enqueues itself via axn's adapter-agnostic delayed-enqueue seam
(`call_async(_async: { wait: delay })`, carrying `attempt: n + 1`) rather than inheriting whatever
default backoff curve the underlying adapter has — identical retry behavior across every axn adapter,
and `Retry-After` is honored precisely: `delay = max(backoff(attempt), retry_after_seconds)`. After
`max_attempts`, exhaustion is reported **once** (via `Axn.config.on_exception`) and then delivery
stops — it never raises, so the async adapter doesn't also retry an already-exhausted job. If no
async adapter is configured at all, a retryable failure is treated the same as an exhausted retry
budget (reported once, no retry), matching the sync fallback's best-effort promise.

**At-least-once is preserved for crashes**: response-based retries are self-managed, but an
*unexpected* exception still propagates so the adapter retries the un-acked job as a safety net.
Because every attempt reuses the same `webhook-id`, a double-delivery from that safety net is
idempotent on the receiver side.

### Asking for redelivery (`retry_later!`)

A handler on the **inbound** side can ask the sender to redeliver later without paging, independent
of the outbound engine above:

```ruby
class HandleWebhook
  include Axn::Webhooks::Handler
  def call
    Axn::Webhooks.retry_later!(after: 30) unless dependency_ready?  # => 503, Retry-After: 30
  end
end
```

Raising `Axn::Webhooks::RetryLater` (directly, or via the `Axn::Webhooks.retry_later!(after: nil)`
helper) **always** maps to a **503** — `after:` only controls whether the `Retry-After` header is
present, distinct from a crash (which is a reported plain 500). It's rescued around the whole
synchronous dispatch, so anything the request runs in-process can defer — the handler, a `parse:`
proc, a `with:` extractor, an `otherwise:` callable. That also makes it the escape hatch for a
`parse:` proc that does I/O, whose other errors are [terminal](#unparseable-bodies-unparseable_status).
The affordance requires **synchronous** dispatch: a `retry_later!` raised inside an async worker is
just a worker exception, unrelated to the HTTP response already sent.

**"Without paging" requires `include Axn::Webhooks::Handler`** (in place of plain `include Axn`) —
it's a thin concern that includes `Axn` and declares `fails_on Axn::Webhooks::RetryLater`, so a
deferral settles as a quiet failure instead of an unhandled exception. Without it (or an equivalent
manual `fails_on Axn::Webhooks::RetryLater`), a plain `include Axn` handler calling `retry_later!`
still 503s the response (`Dispatch` rescues the exception either way), but it **also** reports to
`Axn.config.on_exception` (e.g. Honeybadger) on every single deferral — the opposite of the
"without paging" promise.

### Routing: sender-owned config today

**Routing is sender-owned config, not a service.** The event→targets map lives in each *sending*
app's own `outbound` block (`to:` / `subscribers`), not in this gem. A general-purpose DB-backed
self-registration store — where receivers register their own endpoint URLs at runtime, no deploy
required to add a listener — is a real future shape, but it's **intentionally deferred until a real
use-case justifies it**. The `subscribers`/`to:` lambda is the seam it will slot into with no API
change: swap the lambda body for a DB lookup and nothing else in this gem needs to move.

## Development

- `bin/refresh` — pull latest and install dependencies (fails on a dirty working tree).
- `bundle exec rake` — run the default task (specs + rubocop) before pushing.
