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

# Twilio — custom verifier delegating to the vendor SDK. Twilio signs the URL, so the trailing
# slash a mount adds has to come off first — see "URL-signing verifiers" below.
Axn::Webhooks.inbound :twilio do
  verify do |req|
    path, query = req.url.split("?", 2)

    Twilio::Security::RequestValidator.new(ENV.fetch("TWILIO_AUTH_TOKEN"))
      .validate([path.chomp("/"), query].compact.join("?"), req.params, req.header("X-Twilio-Signature"))
  end
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

#### URL-signing verifiers

Some vendors — Twilio most notably — sign the **request URL** rather than the body, and compare
against the URL as registered in their dashboard. `Request#url` is rebuilt from the Rack env, and two
properties of that rebuild will bite.

**A mount whose path is the whole route adds a trailing slash.** Rack puts the mount point in
`SCRIPT_NAME` and leaves `PATH_INFO` as `"/"` for a request matching it exactly:

```ruby
mount Axn::Webhooks::Inbound[:twilio], at: "/webhooks/twilio"

# vendor POSTs to https://example.com/webhooks/twilio
req.url   # => "https://example.com/webhooks/twilio/"             <- note the slash
# ...and with a query string:
req.url   # => "https://example.com/webhooks/twilio/?callId=42"
```

The vendor signed the URL *without* that slash, so passing `req.url` straight to a URL-signing
validator rejects every request — a valid signature over a URL that doesn't match, which reads in the
logs exactly like a rotated secret. Split on the query, then chomp the path:

```ruby
path, query = req.url.split("?", 2)
signed_url = [path.chomp("/"), query].compact.join("?")
```

Chomping the whole URL is **not** equivalent: it strips nothing when a query string is present, which
is precisely the case a status-callback URL (`…/update?callId=N`) exercises. Matching `/` before
`?`-or-end across the whole URL isn't either — the leftmost match lands in the *query* for something
like `?redirect=a/`. A mount at a prefix (`at: "/webhooks"`, vendor posts `/webhooks/twilio`) leaves a
non-`"/"` `PATH_INFO` and so has no slash to strip, and the form above is a no-op there — so it is
safe to apply unconditionally rather than per-route, **as long as the URL registered with the vendor
doesn't itself end in `/`**. It's indistinguishable from the mount artifact at this layer: both
produce a `req.url` ending in `/`, but one should be chomped and the other must not be. Register the
webhook URL without a trailing slash (the natural spelling of an `at:` mount path) and this doesn't
come up.

**`url` reflects the scheme and host the proxy reported.** It comes from `Rack::Request#url`, so a CDN
or load balancer added in front, a change in `X-Forwarded-Proto` handling, or a new domain changes
what actually gets verified. The only symptom is `:signature_mismatch` on every request — again
indistinguishable from a rotated secret, so it is worth naming in whatever alerts on `reason`.

Nothing about this applies to body-signing verifiers (`:hmac`, `:standard_webhooks`), which never
read `url`.

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

`Signature` exports the ready-made verdicts, so a custom block rarely has to construct a `Check`:
`OK`, `MISMATCH`, `SIGNATURE_MISSING`, `CREDENTIALS_MISSING`, `CREDENTIALS_MISMATCH`. Returning
`SIGNATURE_MISSING` rather than `MISMATCH` when the header is absent earns its one extra line on a
guessable public path — it keeps ordinary unsigned scanner traffic out of `:signature_mismatch`,
which is the reason actually worth alerting on.

**Don't return an `Axn::Result` from a `verify` block.** In an axn-consuming app the instinct is to
put the check in an action, but the contract above is read as
`check.is_a?(Signature::Check) ? check.ok? : !!check` — and an `Axn::Result` is neither a `Check` nor
a boolean, and is **truthy even when `ok?` is false**. A verifier that returns one therefore reports
every rejected request as verified and dispatches it, with no verify failure recorded anywhere. If the
logic belongs in an action, call it from the block and translate:

```ruby
verify do |req|
  MyCheck.call(request: req).ok? ? Axn::Webhooks::Signature::OK : Axn::Webhooks::Signature::MISMATCH
end
```

Usually it doesn't need to be an action at all: `Verify` is already the Axn boundary for this stage —
it owns the `expects`/`exposes` contract, the `sensitive:` redaction of the verifier, the `reason`
dimension, and the exception report — which is why both built-in strategies are a plain class and a
lambda rather than actions.

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

# One endpoint, one handler; form-encoded body. See "URL-signing verifiers" below for why the
# URL is normalized before validation.
Axn::Webhooks.inbound :twilio do
  verify do |req|
    path, query = req.url.split("?", 2)

    Twilio::Security::RequestValidator.new(ENV.fetch("TWILIO_AUTH_TOKEN"))
      .validate([path.chomp("/"), query].compact.join("?"), req.params, req.header("X-Twilio-Signature"))
  end
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
  verify do |req|
    path, query = req.url.split("?", 2)

    Twilio::Security::RequestValidator.new(ENV.fetch("TWILIO_AUTH_TOKEN"))
      .validate([path.chomp("/"), query].compact.join("?"), req.params, req.header("X-Twilio-Signature"))
  end
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

**A missing adapter is only ever a fallback under `:auto`, never under an explicit request.** The
two look inconsistent side by side — `:auto` silently runs sync, an explicit `async` 500s, and
[outbound's `emit`](#async-posture) warns and runs sync — but they line up once you compare
like for like: `emit` defaults to `:auto`, so its fallback is `:auto` behavior, identical to
inbound's — and `emit(..., async: true)`, the explicit form, raises here too. The raise fires only when an app declared `async` and the configuration can't honor
it. Downgrading that silently would be wrong twice over: `async` is usually declared *because* the
handler outlives the vendor's ack window (Slack's 3s), so running it inline trades a clean 500 for a
vendor timeout, a redelivery, and duplicate processing — and it changes the response the vendor
sees, since the async path acks with no handler result while the sync path renders one (a handler
`fail!` included). It's also the same no-silent-downgrade stance outbound's `to:` takes: a *declared*
resolver that returns nil delivers nowhere rather than falling back to `subscribers`. That rule is what the shipped per-`emit` `async:` override follows: `emit(..., async: true)` raises
when no adapter is configured, exactly as an explicitly-`async` inbound route does, rather than
inheriting `Emit`'s `:auto` fallback.

### Nested endpoints

When several endpoints share a vendor's verification, declare it once and nest the endpoints that
differ:

```ruby
Axn::Webhooks.inbound :slack do
  verify :hmac, secret: ENV.fetch("SLACK_SIGNING_SECRET"), prefix: "v0=",
                replay: { timestamp: header("X-Slack-Request-Timestamp"), within: 300 }
  challenge_required { |req| req.params["type"] == "url_verification" }

  endpoint :interactivity do
    dispatch on: ->(e) { e["type"] }, to: { "block_actions" => async("Actions::Slack::HandleBlockActions") }
    respond { |result| json(result.response_action) }
  end

  endpoint :events do
    dispatch on: ->(e) { e.dig("event", "type") }, to: { "app_mention" => "Actions::Slack::HandleMention" }
  end
end
# => registers Inbound[:slack_interactivity] and Inbound[:slack_events]
```

* **Each child registers as `:"#{parent}_#{child}"`.** The parent (`Inbound[:slack]`) is **not**
  registered — a parent with `endpoint` blocks is a container, and declaring a top-level `dispatch`
  alongside them raises at boot rather than leaving an extra endpoint nobody mounted. A parent
  `respond`/`static_respond` is fine, and is often the point: it renders nothing on its own, and
  one shared renderer across a vendor's endpoints is exactly what nesting is for.
* **Children inherit every parent declaration** — `verify`, `challenge`, `challenge_required`,
  `unauthorized_headers`, `respond`, `static_respond` — and override any of it by re-declaring it.
  Siblings are independent; a declaration in one child never leaks into another. `dispatch` is the
  one thing a parent cannot declare (above), so each child brings its own.
  A child may swap renderer forms — declaring `static_respond` over an inherited `respond`, or the
  reverse — and the inherited one is dropped. Declaring both in the *same* block is still an error.
  There is no way to *un*-declare an inherited block outright: a child that must render nothing
  needs the parent's `respond` moved down into the siblings that do want it.
* **One level only.** An `endpoint` inside an `endpoint` raises.

Each child is validated exactly as a standalone endpoint would be, so a child that declares
`dispatch` without inheriting or declaring a `verify` still fails at boot.

Nesting is sugar, not a new capability: a shared options hash splatted with `**`, or a shared lambda
passed to `verify(&lambda)`, expresses the same thing and remains a fine choice.

**Note on block scoping**: The `inbound do … end` block is evaluated with `instance_exec` against an internal DSL, so `self` inside the block is NOT the surrounding object. You can reference `ENV`, constants, and local variables, but don't call surrounding-object helper methods or access its instance variables from within the block.

**Note on Rails autoloading**: `inbound` blocks are evaluated where they're declared — at boot, if
that's an initializer — and Rails disallows autoloading during initialization. So naming a class from
`app/` while the initializer runs raises `NameError` and fails the boot. Handler classes are already
safe: `dispatch to:` accepts a **string**, which is resolved via `const_get` per request. A custom
`verify` block needs the same treatment — keep the constant inside the block, which runs per request
rather than at boot:

```ruby
# NameError at boot — the constant is named while the initializer runs
checker = MyApp::SignatureChecker.new(secret: ENV.fetch("SECRET"))
Axn::Webhooks.inbound(:vendor) { verify { |req| checker.call(req) } }

# Fine — the constant is named when a request arrives
Axn::Webhooks.inbound(:vendor) do
  verify { |req| MyApp::SignatureChecker.verify(req, secret: ENV.fetch("SECRET")) }
end
```

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
  # `secret:` may be a plain value or a zero-arity callable, resolved fresh on every signing attempt
  # (the same convention as every inbound `verify` secret) — so a secret can rotate without a reboot.
  sign :standard_webhooks, secret: -> { ENV.fetch("WEBHOOK_SIGNING_SECRET") }

  # Default subscriber resolver — the seam a future DB-backed subscription store slots into.
  # Any event declared with no explicit `to:` falls back to this.
  subscribers ->(event) { Subscription.urls_for(event) }

  event :lead_signed, to: ["https://example.com/webhooks/lead_signed"]  # static list
  event :lead_closed                                                    # no `to:` -> resolved via `subscribers`
  event :invoice_paid, type: "invoice.paid", to: ["https://example.com/webhooks/invoice_paid"]  # override the wire `type`
  event :internal_only, to: ["https://internal.example/hook"], vendor: :internal  # override the vendor facet, this event only

  max_attempts 8                                                # default shown
  backoff ->(attempt) { [30 * (3**(attempt - 1)), 6 * 3600].min } # default shown (seconds; capped at 6h, jittered — see below)
  transport MyFaradayTransport                                  # optional; defaults to stdlib net/http
  timeouts open: 5, read: 10                                    # defaults shown, seconds; built-in transport only
  vendor :internal                                              # optional; the observability facet default for every event (overridable per event, above)
  user_agent -> { "#{Rails.application.class.module_parent_name} / #{Rails.application.config.git_sha}" } # optional suffix; plain value or callable
end

result = Axn::Webhooks.emit(:lead_signed, data: { lead_id: 42 })  # => Axn::Result
result.webhook_ids    # => ["msg_<uuid>", ...] — one per resolved target
result.target_count   # => 1
```

* **Symbols are the identity.** `emit(:unknown_event)` raises `Axn::Webhooks::Error` immediately,
  listing the known events — no silent no-op for a typo'd event name. A statically declared
  `event :x, to: []` warns at boot (it will deliver nowhere). A second `Axn::Webhooks.outbound` block
  replaces the first and logs a warning — only one is ever active.
* **Wire `type`** defaults to the symbol as a string (`:lead_signed` → `"lead_signed"`), overridable
  per event with `type:` when a receiver expects a dotted convention or another exact value.
* **`to:`** accepts a static Array or a lambda (`->(event) { … }`); the block-level `subscribers`
  resolver is the shared default when an event declares no `to:` at all. A static Array's URLs are
  validated as http/https at boot; a lambda's return value is not (it can't be, since it depends on
  runtime state) — validate what it returns yourself if that matters.
* **Fan-out**: `emit` resolves the event's subscribers and enqueues one independent, self-retrying
  `Axn::Webhooks::Outbound::Deliver` per target — one slow/failing subscriber can't block another.
  Each delivery gets its own stable `webhook-id`, generated once per (emission × target) and reused
  across every retry attempt of that delivery, so receivers can dedup. `emit`'s result exposes the
  full list of `webhook_ids` and a `target_count`, so a caller can record what actually went out.
* **`failed_count`** counts deliveries that came back failed — but **only on the synchronous
  fallback path**, and it is **always `0` on the async path**, because at `emit` time nothing has
  failed yet: the deliveries are enqueued, and a later failure is reported by `Deliver` itself
  (exhaustion via `on_exception`, a permanent 4xx via its own result). Note that is the *path*, not
  adapter presence — an `emit(..., async: false)` runs inline and counts failures even when an
  adapter is configured. `emit`'s
  result stays `ok` even when every delivery failed — fan-out succeeded, and a subscriber being
  down is not an emit failure. `target_count - failed_count` is the sync-path success count.
* **Per-call overrides.** `emit` accepts `to:` and `async:`:

  ```ruby
  Axn::Webhooks.emit(:lead_signed, data: { lead_id: 42 },
                     to:    "https://one-off.example/hook",  # String or Array
                     async: false)
  ```

  `to:` **replaces** the event's declared targets for that call — it never merges with them, the
  same stance a declared `to:` resolver returning nil takes. The event must still be declared (it
  supplies the wire `type` and `vendor`), and a one-off URL is validated as http(s) at emit time,
  raising `Axn::Webhooks::Error`. `async: true` **raises** when no adapter is configured rather
  than running inline — a missing adapter degrades to sync only under `:auto`, never under an
  explicit request (same rule as an inbound route marked `async`). `async: false` forces the inline
  path and suppresses the degraded-mode warning, since a caller asking for sync isn't degraded.

  There is deliberately no per-call `headers:`: it is the obvious place to hang a bearer token, and
  it would be serialized into the async job's args and persist in the queue for the whole retry
  lifetime — the opposite of the convention `secret:` follows (a callable re-resolved per attempt,
  never stored). Per-destination config belongs with the DB-backed subscription store.
* **`vendor`** stamps the same observability facet (`Axn::Webhooks.config.vendor_facet`) inbound
  endpoints already use, letting Datadog/Honeybadger group outbound deliveries by event or
  subscriber. A per-event `vendor:` overrides the block-level default; an event with neither is
  unstamped.

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
can still dedup a redelivered message). The envelope body's own `timestamp` field, by contrast, is
fixed once at emit time (it's part of the dedup identity) — so a retried delivery's signed
`webhook-timestamp` header and its body's `timestamp` field deliberately diverge; read the header as
"when this attempt was signed", not the body's "when this event happened".

`user-agent` is `axn-webhooks/<version>`, plus an optional suffix — `axn-webhooks/<version>
(<value>)` — from `user_agent` in the `outbound` block (a plain value or a zero-arity callable,
resolved per attempt).

#### `sign :hmac`

For a receiver that expects a plain signature header rather than the Standard Webhooks envelope:

```ruby
# minimal — one header, signature over the raw body
sign :hmac, secret: -> { ENV.fetch("PARTNER_SECRET") }, header: "X-Signature"
# => X-Signature: 3f9a1c…

# …or a replay-protectable signature, Slack-style
sign :hmac,
     secret:           -> { ENV.fetch("PARTNER_SECRET") },
     header:           "X-Signature",
     timestamp_header: "X-Timestamp",
     signing_string:   "v0:{timestamp}:{body}",
     prefix:           "v0="
# => X-Timestamp: 1755740000
#    X-Signature: v0=3f9a1c…
```

`secret:` (plain or zero-arity callable, re-resolved per attempt) and `header:` are required — there
is no universal signature-header name, the same reason inbound's `verify :hmac` requires
`signature:`. `digest:` (`:sha256`), `encoding:` (`:hex`), `prefix:` (`nil`) and `signing_string:`
(`"{body}"`) mirror the inbound verifier's options, so a `sign :hmac` sender and a `verify :hmac`
receiver configured alike round-trip.

`digest:`, `encoding:` and both header names are validated at declaration time: an unsupported
digest/encoding, or a header name that isn't a valid HTTP field token (no spaces, colons or
newlines), fails at boot rather than inside every delivery attempt. `header:` and
`timestamp_header:` may not be the same name as each other, nor any header the delivery pipeline
sets after signing: `content-type` and `user-agent` (which `Deliver` merges in afterwards) or
`content-length` (which the transport regenerates from the request body at send time). In every one
of those cases the later value replaces the signature and each delivery ships unverifiable. Braces in
`signing_string:` must be exactly `{timestamp}` or `{body}`; a malformed one (`{time-stamp}`, or an
unclosed `{timestamp`) is rejected rather than silently signed as literal text, so a literal brace
is not supported there.

`signing_string:` is a **template**, not a callable: `{timestamp}` and `{body}` are the only
placeholders, and an unknown one is rejected at declaration time — which a lambda would make
impossible. Referencing `{timestamp}` without declaring `timestamp_header:` is also rejected: the
receiver would have no way to reconstruct the signed string. If you need logic a template can't
express, use the custom `sign { |id:, timestamp:, body:| … }` block, which has always been there.

A secret that resolves to a blank or non-String value raises `Axn::Webhooks::Error` rather than
signing with an empty key — the error names the value's class or shape, never its bytes.

Note there is no id header: a signature bound to a per-message id is what `:standard_webhooks` is
for.

### Transport

The HTTP call is an injectable seam (`.post(url:, body:, headers:) -> Transport::Response`, a
`Data.define(:status, :headers, :body)` — `body:` defaults to `nil`, so a transport built against the
original two-field shape still works). The default is stdlib `net/http` — no new runtime dependency —
and a consuming app can swap in its own object (e.g. Faraday-backed) via `transport` in the `outbound`
block. `timeouts open:`/`read:` (defaults 5s/10s) only reach the **built-in** transport — a custom one
owns its own timeout configuration, since the documented seam is `.post(url:, body:, headers:)` with
no timeout kwargs guaranteed.

### Async posture

Mirrors inbound's `:auto`: **async when an axn async adapter is configured** for `Deliver` (an
`async :sidekiq`/`async :active_job` global default, per axn's own presence-check semantics — never
a branch on adapter type), else a **synchronous inline fallback** so the gem works standalone without
Sidekiq. The sync path is best-effort: no cross-process retries/backoff, and it logs a warning (once
per `emit` call, not once per subscriber) so the degraded mode is never silent. That degrade-rather-
than-raise behavior is what `:auto` means, and it is the **default**; a caller who explicitly demands
async with `emit(..., async: true)` gets a raise instead when no adapter is configured, exactly as an
explicitly-`async` inbound route does (see [per-route sync/async](#per-route-syncasync-on-one-endpoint)
and the per-call overrides above).

### Delivery contract

Each delivery attempt classifies the receiver's response. This is the canonical contract — useful
both for reading this gem's `Deliver` behavior and for a single-side (non-gem) implementer of either
half:

| Receiver responds | Delivery does |
| -- | -- |
| **2xx** | success |
| **408, 425, 429, 5xx, 503 + `Retry-After`, timeout, connection error** | retryable → self-reschedule the next attempt |
| **other 4xx** (400, 401/403 bad-sig/auth, 404, 410 Gone, 422) | permanent → quiet `fail!`, no retry (a silent business failure surfaced via the `Deliver` result + axn's routine outcome logging, NOT via `on_exception`) — the failure message includes a truncated (500-byte) copy of the response body, the one piece of receiver-supplied detail a bare status code can't carry |
| **unexpected exception** (crash / OOM / network raise mid-flight) | propagates → adapter retries the un-acked job (at-least-once safety net) |

**One self-managed retry engine, adapter-agnostic.** On a retryable response, `Deliver` computes its
own delay and re-enqueues itself via axn's adapter-agnostic delayed-enqueue seam
(`call_async(_async: { wait: delay })`, carrying `attempt: n + 1`) rather than inheriting whatever
default backoff curve the underlying adapter has — identical retry behavior across every axn adapter,
and `Retry-After` is honored precisely: `delay = max(backoff(attempt), retry_after_seconds)`. The
default `backoff` curve applies **equal jitter** (half the computed delay is fixed, half is random) so
a fan-out event whose receiver is down doesn't have every failing target retry in lockstep. After
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
change: both are resolved fresh on **every** `emit`, never memoized at boot, so swapping the lambda
body for a DB lookup already picks up rows added or removed at runtime.

That much works today. What a DB-backed store also wants, and this gem does **not** have yet:

* **A secret per subscriber.** `sign` installs one process-global signer, and it is handed only
  `id:`, `timestamp:` and `body:` — no URL, no subscriber handle. A shared secret across every row
  is the only shape currently expressible.
* **Validation of what the resolver returns.** A statically declared `to:` array is checked for
  http(s) URLs at boot; a lambda's return value is not (it can't be). A malformed row is reported to
  `Axn.config.on_exception` when `Deliver` rejects it, but `emit`'s own result still counts it in
  `target_count` and still reports `ok`. Validate rows yourself, and treat URLs that came from
  outside your own deploy as untrusted (there is no SSRF allowlist here).
* **A way to record what went where.** `webhook_ids` is a bare Array with no URL attached, so
  persisting a delivery row per subscription means re-resolving and relying on ordering.

Resolution also runs inline in whatever process called `emit`, so a store that raises (a database
outage) raises out of `emit` — inside your `after_commit`, if that's where you emit from.

### Boot-time validation

An `outbound` block fails loudly at declaration time — rather than as an unexpected exception mid-
delivery, which the async adapter would otherwise retry as if it were a network failure — for:
`max_attempts` that isn't a positive Integer; a `backoff` that doesn't accept the attempt number
(arity 0); a `to:` that is neither an Array nor a callable; and a statically-declared `to:` URL that
isn't a valid http/https URL. A callable `to:`'s *return value* isn't validated (it depends on
runtime state), nor is a callable `secret:`'s.

### Testing

`Axn::Webhooks::Outbound.reset!` clears the declared `outbound` block — call it in an `after` hook
between examples that each declare their own, the same way `Axn::Webhooks::Inbound.reset!` clears
registered vendors.

## Development

- `bin/refresh` — pull latest and install dependencies (fails on a dirty working tree).
- `bundle exec rake` — run the default task (specs + rubocop) before pushing.
