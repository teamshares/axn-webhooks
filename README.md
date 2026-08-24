# axn-webhooks

Webhook handling for [axn](https://github.com/teamshares/axn), both directions, on one signature
primitive. Works in or out of Rails.

* **[Inbound](#inbound)** — verify a vendor's signature, dispatch the event to a handler action, and
  acknowledge. Declared per vendor; mounts as a Rack app, no controller needed.
* **[Outbound](#outbound)** — declare your own events and subscribers, and emit signed,
  self-retrying deliveries. Declared once per sending app.

**Contents:** [Installation](#installation) · [Quick start](#quick-start) · [Inbound](#inbound) ·
[Outbound](#outbound) · [Signature primitive](#signature-primitive) · [Testing](#testing)

The *why* behind the surprising parts — and the traps worth naming — lives in
[DESIGN-NOTES.md](DESIGN-NOTES.md).

## Installation

```ruby
gem "axn-webhooks"
```

Requires Ruby 3.2.1+ and Rack 3. Under Rails, `axn`'s own ActiveSupport 7.2 floor makes **Rails 7.2+**
the effective minimum.

## Quick start

### Receiving a webhook

Declare the endpoint once (e.g. `config/initializers/webhooks.rb`):

```ruby
Axn::Webhooks.inbound :codat do
  verify :standard_webhooks, secret: ENV.fetch("CODAT_WEBHOOK_SECRET")
  dispatch on: ->(e) { e["eventType"] },
           to: { "connection.updated" => "Actions::Codat::ConnectionUpdated" }
end
```

Mount it:

```ruby
# config/routes.rb
mount Axn::Webhooks::Inbound[:codat], at: "/webhooks/codat"
```

Write the handler as an ordinary Axn:

```ruby
module Actions
  module Codat
    class ConnectionUpdated
      include Axn::Webhooks::Handler   # includes Axn; makes `retry_later!` a quiet failure

      expects :event

      def call
        Connection.find_by(external_id: event.dig("data", "connectionId"))&.refresh!
      end
    end
  end
end
```

That's the whole loop: a signed POST is verified, parsed, routed, and acked with a bare 200.

### Sending a webhook

```ruby
Axn::Webhooks.outbound do
  sign :standard_webhooks, secret: -> { ENV.fetch("WEBHOOK_SIGNING_SECRET") }  # "whsec_<base64>"

  event :lead_signed, to: ["https://partner.example/hooks/leads"]
end

Axn::Webhooks.emit(:lead_signed, data: { lead_id: 42 })
```

The receiver gets a signed Standard Webhooks envelope.

**Retries need an async adapter.** With an `async :sidekiq` / `async :active_job` default configured
for axn, each delivery retries itself on a retryable failure, up to `max_attempts`. Without one,
`emit` falls back to a best-effort inline send that logs a warning and does **not** retry — the first
retryable failure is treated as exhausted, so a transient receiver outage drops the delivery. See
[Async posture](DESIGN-NOTES.md#async-posture-auto-vs-explicit).

---

# Inbound

## Declaring an endpoint

`Axn::Webhooks.inbound(:name) { … }` registers an endpoint; `Axn::Webhooks::Inbound[:name]` looks it
up. The symbol is the vendor's name — whatever you'll reference it by.

```ruby
# Standard Webhooks (Svix) preset
Axn::Webhooks.inbound :codat do
  verify :standard_webhooks, secret: ENV.fetch("CODAT_WEBHOOK_SECRET")
end

# Parametric HMAC
Axn::Webhooks.inbound :merge_dev do
  verify :hmac,
    secret:    ENV.fetch("MERGE_WEBHOOK_SIGNATURE_KEY"),
    signature: header("X-Merge-Webhook-Signature"),
    encoding:  :base64_urlsafe
end

# HTTP Basic auth rather than a signature
Axn::Webhooks.inbound :legacy_vendor do
  verify :basic_auth,
    username: -> { ENV.fetch("WEBHOOKS_AUTH_USERNAME") },
    password: -> { ENV.fetch("WEBHOOKS_AUTH_PASSWORD") }
end

# Custom verifier delegating to a vendor SDK
Axn::Webhooks.inbound :twilio do
  verify do |req|
    path, query = req.url.split("?", 2)   # see URL-signing verifiers in DESIGN-NOTES.md

    Twilio::Security::RequestValidator.new(ENV.fetch("TWILIO_AUTH_TOKEN"))
      .validate([path.chomp("/"), query].compact.join("?"), req.params, req.header("X-Twilio-Signature"))
  end
end
```

Blocks are evaluated with `instance_exec` against an internal DSL, so `self` is **not** the
surrounding object. `ENV`, constants and local variables are fine; the surrounding object's helper
methods and ivars are not.

### DSL reference

| Declaration | Purpose |
| -- | -- |
| `verify :strategy, **opts` / `verify { \|req\| … }` | How to authenticate the request. Required whenever `dispatch` is declared. |
| `dispatch …` | Route the parsed event to a handler. See [Dispatching](#dispatching-to-a-handler). |
| `respond { \|result\| … }` | Render a body from the handler's result. See [Responding](#responding). |
| `static_respond { … }` | Render a fixed body that doesn't read the result. |
| `challenge resolver, if: nil` | Answer a vendor's `GET` verification handshake. |
| `challenge_required { \|req\| … }` | Mark a request as the bare first leg of a challenge-response auth handshake. |
| `unauthorized_headers "H" => "v"` | Extra headers on the 401 (e.g. `WWW-Authenticate`). |
| `endpoint(:child) { … }` | [Nested endpoints](#nested-endpoints) sharing this block's declarations. |

Inside a block, `header(name)`, `raw_body`, `params` and `url` build deferred lookups against the
request, and `async(target, **)` / `sync(target, **)` build dispatch-map entries.

## Verifying

| Strategy | For | Key options |
| -- | -- | -- |
| `verify :standard_webhooks` | Standard Webhooks / Svix (Codat, Lob, …) | `secret:`, `tolerance:` (300) |
| `verify :hmac` | Anything signing the body with an HMAC | `secret:`, `signature:`, `signing_string:`, `digest:`, `encoding:`, `prefix:`, `replay:` |
| `verify :basic_auth` | Vendors gated by HTTP Basic auth | `username:`, `password:`, `realm:` (`"Webhook"`) |
| `verify { \|req\| … }` | Anything else (vendor SDKs, URL signing) | — |

Every `secret:`/`username:`/`password:` accepts a plain value, or one of the **deferred shapes**
re-resolved per request so a rotation needs no reboot: a **lambda/proc** (`-> { ENV.fetch("SECRET") }`,
or 1-arity to receive the request), a **`header(…)`/`params`/`raw_body`/`url` resolver**, or a
**Symbol** naming a `Request` method. Anything else — including a provider object that merely
responds to `#call`, or a `Method` — is treated as a literal value, and rejected at declaration if
it isn't a usable secret.

A blank or missing secret is always rejected, never used: `""` is a legal HMAC key, so signing with
one would make the expected signature something any stranger could compute. Literals fail at boot;
deferred shapes are checked on every request, since they can go missing long after boot.

### `verify :hmac`

| Option | Default | Notes |
| -- | -- | -- |
| `secret:` | required | Plain value or callable. |
| `signature:` | required | Usually `header("X-…-Signature")`. There is no universal header name. |
| `signing_string:` | `:raw_body` | `:raw_body`, or a lambda building the exact signed string. |
| `digest:` | `:sha256` | `:sha256` / `:sha1` / `:md5` |
| `encoding:` | `:hex` | `:hex` / `:base64` / `:base64_urlsafe` |
| `prefix:` | `nil` | Stripped before comparison, e.g. `"v0="` for Slack. |
| `replay:` | `nil` | `{ timestamp:, within:, unit: }` — see [Replay protection](#replay-protection). |

```ruby
Axn::Webhooks.inbound :slack do
  verify :hmac, secret:         ENV.fetch("SLACK_SIGNING_SECRET"),
                signature:      header("X-Slack-Signature"),
                prefix:         "v0=",
                signing_string: ->(r) { "v0:#{r.header('X-Slack-Request-Timestamp')}:#{r.raw_body}" },
                replay:         { timestamp: header("X-Slack-Request-Timestamp"), within: 300 }
end
```

### `verify :standard_webhooks`

Implements [Standard Webhooks](https://www.standardwebhooks.com/) — the cross-vendor spec (Zapier,
Twilio, Svix and others) for signed webhooks. It's what Codat, Lob and any Svix-backed sender emit,
and it's the same scheme this gem's own [`sign :standard_webhooks`](#sign-standard_webhooks) sends,
so the two halves round-trip. Full details in the
[specification](https://github.com/standard-webhooks/standard-webhooks).

Per that spec the secret is **`whsec_<base64>`** — the prefix is stripped and the rest Base64-decoded
to the raw HMAC key. Pass the vendor's value verbatim, prefix included. `id:`, `timestamp:` and
`signature:` default to the spec's `webhook-*` headers and rarely need overriding; `tolerance:`
defaults to 300 seconds.

A secret missing the prefix is rejected, and the check happens as early as it possibly can:

| Secret form | Checked | On failure |
| -- | -- | -- |
| a literal (`"whsec_…"`, or anything else) | at declaration | `ArgumentError` — your boot fails, not your traffic |
| a callable or `header(…)` resolver | on **every request** | `Axn::Webhooks::Error` — reported to `Axn.config.on_exception`, 401 |

A callable can't be settled at boot (it may read a secret store, or an env var set after boot), so
it's validated each time it resolves. Either way the error names the value's *shape*, never its
bytes.

> **Why this is checked so aggressively:** the decode used to coerce with `to_s`, so a secret that
> resolved to `nil` — an unset env var, or a `header(…)` on an absent header — became an **empty
> HMAC key**. Anyone who knew the credential was missing could sign with that empty key and verify.
> A missing secret now fails loudly instead of authenticating strangers, and it can never degrade
> into a quiet `:signature_mismatch` that reads like a rotated key.

### `verify :basic_auth`

Handles the full two-legged handshake for you, including the `WWW-Authenticate` challenge that
clients like Twilio require before they will send credentials at all — see
[Basic auth is two-legged](DESIGN-NOTES.md#basic-auth-is-two-legged) for why that matters and what a custom block
has to do instead. Prefer signature verification wherever the vendor offers it.

### Custom `verify` blocks

The contract is `->(request) { Boolean }`. A return value is read as:

| Return | Read as |
| -- | -- |
| an object responding to `ok?` (a `Signature::Check`, an `Axn::Result`, …) | whatever its `ok?` says |
| any other truthy value | verified |
| `nil` / `false` | rejected |

So returning an `Axn::Result` works — a failed one rejects the request rather than silently
verifying it. To name your own failure *cause*, return an `Axn::Webhooks::Signature::Check`;
`Signature` exports ready-made verdicts (`OK`, `MISMATCH`, `SIGNATURE_MISSING`,
`CREDENTIALS_MISSING`, `CREDENTIALS_MISMATCH`), so you rarely have to build one:

```ruby
verify do |req|
  MyCheck.call(request: req).ok? ? Axn::Webhooks::Signature::OK : Axn::Webhooks::Signature::MISMATCH
end
```

Without a `Check`, a rejection is reported as `:signature_mismatch`.

> **Gotcha: `ok?` on an `Axn::Result` means the action SUCCEEDED, not that the signature was
> valid.** The two coincide only if your action `fail!`s on a bad signature. An action that
> succeeds while carrying its verdict in an exposure (`expose(valid: false)`) still reads as
> verified — so `fail!` on rejection, or translate to a `Check` as above. See
> [Don't return an Axn::Result](DESIGN-NOTES.md#dont-return-an-axnresult-from-a-verify-block).

### Why verification failed

A rejection is always a bare 401 on the wire, but the cause is on the result and stamped as a
bounded `reason` metrics dimension, so failures can be grouped and alerted on separately:

```ruby
result = Axn::Webhooks::Inbound[:codat].verify(request)
result.reason  # => :replay_window
result.skew    # => 10_000  (seconds, signed: positive = the timestamp is in the past)
result.error   # => "Webhook verification failed: replay window exceeded (timestamp skew 10000s)"
```

| `reason` | What it means | Usually caused by |
| -- | -- | -- |
| `:replay_window` | Valid timestamp, outside the window. Carries `skew`. | A genuine replay or real clock drift |
| `:replay_timestamp_invalid` | Timestamp absent or unparseable | A typo'd `replay: { timestamp: … }`, or a vendor that stopped sending it |
| `:signature_missing` | No signature header at all | A typo'd `signature:` header name, or an unsigned sender |
| `:signature_mismatch` | The HMAC genuinely didn't match | Wrong/rotated secret, or the wrong `signing_string` |
| `:credentials_missing` | (`:basic_auth`) An `Authorization` header that isn't a Basic credential | A client using the wrong scheme, or a scanner |
| `:credentials_mismatch` | (`:basic_auth`) Credentials offered and rejected | Wrong/rotated credentials, or a scanner guessing |

A `:replay_window` rejection also carries **`suggested_unit`** — the scale that *would* have fit
(`nil` for a genuine replay). Since `unit:` [infers the scale](#replay-protection) by default, it is
only ever set when a `unit:` was explicitly pinned and is wrong, which cleanly splits misconfiguration
from attack.

## Mounting

An endpoint is itself a Rack app.

```ruby
# config/routes.rb (Rails)
Rails.application.routes.draw do
  mount Axn::Webhooks::Inbound[:codat], at: "/webhooks/codat"
end
```

```ruby
# config.ru (no Rails)
require "axn-webhooks"
map("/webhooks/codat") { run Axn::Webhooks::Inbound[:codat] }
```

The mount owns the whole path and every verb: `POST` runs verify → dispatch → respond; `GET` runs a
declared `challenge`, or 405s; anything else is a 405 — including `HEAD` on a bare `Rack::Builder`
mount with no `Rack::Head` upstream. (Rails inserts `Rack::Head`, so `HEAD` becomes `GET` there.)

Or drive it yourself from a controller — `#verify`, `#handle` and `#to_response` all take an
`Axn::Webhooks::Request`.

## Dispatching to a handler

`dispatch` routes the verified, parsed event to a handler Axn.

| Option | Default | Notes |
| -- | -- | -- |
| `to:` | — | A handler, a map, or a namespace. See [Routing forms](#routing-forms). |
| `on:` | `nil` | `->(event) { key }` — makes `to:` a map or namespace. |
| `otherwise:` | `nil` | `:ack` or a callable for unmatched keys. Omit to raise loudly. |
| `via:` | `nil` | Custom key → constant-name transform (namespace routing only). |
| `parse:` | `:json` | `:json`, or `->(request) { … }` for other bodies. |
| `mode:` | `:auto` | `:auto` / `:async` / `:sync`. See [Sync vs async](#sync-vs-async). |
| `unparseable_status:` | global | Per-endpoint override of [`unparseable_status`](#unparseable-bodies). |

Handler targets may be a class-name **String** or the **class itself** — both resolve the constant
lazily per request, so either stays reload-safe under Zeitwerk. Strings are the safe default in an
initializer, since they never force the handler to be autoloadable at boot.

```ruby
result = Axn::Webhooks::Inbound[:codat].handle(request)  # verify + dispatch => Axn::Result
result.handler_result  # the handler's own Axn::Result (nil on ack / failure)
```

A missing handler class, or an unmatched event with no `otherwise:`, is reported to
`Axn.config.on_exception` and returned as a failed result — never an unhandled exception.

### Routing forms

| Declaration | Resolves to |
| -- | -- |
| `to: "Handler"` (no `on:`) | that one handler, for every event |
| `on: ->(e) { … }, to: { key => target }` | the target the key maps to — an explicit map |
| `on: ->(e) { … }, to: "Namespace"` | `Namespace::<KeyCamelized>` — by convention, no map to maintain |

A String `to:` means different things with and without `on:`: alone it's the handler, with `on:` it's
the **namespace** keys resolve under. The convention splits the key on `.` and `_` and capitalizes
each part (`"connection.updated"` → `Actions::Codat::ConnectionUpdated`); `via:` replaces that
transform:

```ruby
dispatch on: ->(e) { e["eventType"] },
         to:  "Actions::Codat",
         via: ->(key) { "#{key.split('.').map(&:capitalize).join}Handler" }
```

Namespace routing has no map to miss, so `otherwise:` doesn't apply — an unknown key is a
constant-resolution failure at request time.

### Handler arguments (`with:`)

By default a handler receives the whole parsed event as `event:`. To change that, use the
**map-entry Hash** form, where `with:` is a Symbol (rename-only) or a callable returning the kwargs:

```ruby
dispatch on: ->(e) { e["type"] },
         to: {
           # rename only — handler declares `expects :payload`
           "interaction"  => { call: "Actions::Slack::HandleInteraction", with: :payload },
           # project to scalars — handler declares `expects :lead_id, :status`
           "lead.updated" => { call: "Actions::Leads::Update", with: ->(e) { { lead_id: e["id"], status: e["status"] } } },
         }
```

`with:` lives on the entry, not on `dispatch` — `dispatch to: "H", with: :payload` raises
`ArgumentError: unknown keyword: :with`. The `async(…)`/`sync(…)` helpers build the same Hash and
pass `with:` through, so `async("H", with: :payload)` composes.

### `otherwise:`

`:ack` logs the unmatched key and returns a 2xx. A **callable** is invoked with the event first (its
return value is ignored) and then acks — the seam for alerting without failing the request:

```ruby
dispatch on: ->(e) { e["type"] },
         to: { "lead.updated" => "Actions::Leads::Update" },
         otherwise: ->(event) { Honeybadger.notify("unhandled webhook", context: { type: event["type"] }) }
```

## Responding

By default a successful request gets a bare 2xx ack — most vendors want nothing else.

**`respond`** renders a body from what the handler computed. The block receives the handler's
`Axn::Result` and runs with `ack`/`text`/`xml`/`json` available as bare calls:

```ruby
Axn::Webhooks.inbound :twilio do
  verify { |req| … }
  dispatch to: "Actions::Twilio::HandleCall", parse: ->(req) { req.params }
  respond { |result| xml(result.twiml) }            # handler exposes :twiml
end
```

`json` takes a Hash/Array (JSON-encoded) or a pre-serialized String, and all four take
`status:`/`headers:`.

**`static_respond`** renders a fixed body that never reads the result. Its block takes no arguments,
so it doesn't force sync dispatch:

```ruby
# DropboxSign requires this exact literal string, and its handler must run async:
Axn::Webhooks.inbound :dropbox_sign do
  verify { |req| … }
  dispatch to: "Actions::DropboxSign::HandleWebhook"
  static_respond { text("Hello API Event Received") }
end
```

Declaring both on one endpoint raises at registration.

### HTTP status reference

`Inbound[:vendor].to_response(request)` runs the whole pipeline and maps the outcome:

| Stage | Outcome | Status | `static_respond` renders? |
| -- | -- | -- | -- |
| Verify | rejected signature, or the verifier crashed | 401 | no |
| Dispatch | missing/unresolvable handler, unmatched event with no `otherwise:`, handler crash | 500 (reported) | no |
| Dispatch | body doesn't parse | [`unparseable_status`](#unparseable-bodies) — **200** by default (reported) | yes |
| Dispatch | unknown-but-expected event (`otherwise: :ack`) | 2xx ack | yes |
| Handle | handler's own business `fail!` | 2xx ack (logged) | yes |
| Handle | [`retry_later!`](#asking-for-redelivery) | 503 (+ `Retry-After`) | no |
| Handle | success | declared `respond` body, or a bare 2xx ack | yes |

`respond` runs **only** for a genuine handler success; every other row gets its fixed status
regardless.

## Sync vs async

By default (`mode: :auto`) a handler runs **async when it has an axn async adapter configured** — an
`async :sidekiq` / `async :active_job` on the handler, or a host-app global default — and **sync
otherwise**. This gem never references a specific adapter; it only checks whether one is present.

| Setting | Behavior |
| -- | -- |
| `mode: :auto` (default) | Async if an adapter is configured, else sync |
| `mode: :async` | Always async; reported as an exception if no adapter is configured |
| `mode: :sync` | Always inline |
| a declared `respond` | Forces sync (you can't read a result you enqueued) |
| a map entry's `async:` | Overrides everything above, for that route only |

Precedence, most specific first: the entry's `async:` → an explicit endpoint `mode:` → a declared
`respond` → `:auto` adapter detection. Declaring both `mode: :async` and a custom `respond` raises at
registration.

### Per-route sync/async

A single fixed URL sometimes needs both disciplines — the interaction-platform pattern (Slack,
Discord, Telegram) multiplexes a synchronous body and ack-then-async on one Request URL. `async(…)`
and `sync(…)` build the entry for you:

```ruby
Axn::Webhooks.inbound :slack do
  verify :hmac, secret:         ENV.fetch("SLACK_SIGNING_SECRET"),
                signature:      header("X-Slack-Signature"),
                prefix:         "v0=",
                signing_string: ->(r) { "v0:#{r.header('X-Slack-Request-Timestamp')}:#{r.raw_body}" }
  dispatch on: ->(e) { e["type"] },
           to: {
             "view_submission" => "Actions::Slack::HandleViewSubmission",       # sync: returns a response_action body
             "block_actions"   => async("Actions::Slack::HandleBlockActions"),  # ack now, run async
           }
  respond { |result| json(result.response_action) }  # sync route renders JSON; async route auto-acks
end
```

`async("H")` is sugar for `{ call: "H", async: true }`, `sync("H")` for `{ call: "H", async: false }`;
both pass extra kwargs through.

## Challenge (GET-echo handshake)

Some vendors (Nylas, Meta) verify a new endpoint with a `GET` before sending real events. No extra
route is needed — `challenge` teaches the same mount to answer `GET`:

```ruby
Axn::Webhooks.inbound :nylas do
  verify { |req| … }
  challenge ->(req) { req.params["challenge"] }   # echoed verbatim, 200 text/plain
end

Axn::Webhooks.inbound :meta do
  challenge ->(req) { req.params["hub.challenge"] },
            if: ->(req) { req.params["hub.verify_token"] == ENV.fetch("META_VERIFY_TOKEN") }
end
```

An `if:` rejection is a **403**; a missing/nil challenge value is a **400**; a raise is reported and
mapped to **500**.

Slack's in-band `url_verification` handshake is **not** this — Slack sends it as a POST event, so
it's a normal `dispatch` entry.

## Nested endpoints

When several endpoints share a vendor's verification, declare it once and nest what differs:

```ruby
Axn::Webhooks.inbound :slack do
  verify :hmac, secret:         ENV.fetch("SLACK_SIGNING_SECRET"),
                signature:      header("X-Slack-Signature"),
                prefix:         "v0=",
                signing_string: ->(r) { "v0:#{r.header('X-Slack-Request-Timestamp')}:#{r.raw_body}" },
                replay:         { timestamp: header("X-Slack-Request-Timestamp"), within: 300 }

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

* **Each child registers as `:"#{parent}_#{child}"`.** The parent is **not** registered — it's a
  container. Declaring a top-level `dispatch` alongside `endpoint` blocks raises at boot.
* **Children inherit every parent declaration** (`verify`, `challenge`, `challenge_required`,
  `unauthorized_headers`, `respond`, `static_respond`) and override by re-declaring. Siblings are
  independent. `dispatch` is the one thing a parent can't declare, so each child brings its own.
* A child may swap renderer forms (`static_respond` over an inherited `respond`, or the reverse).
  There is no way to *un*-declare an inherited block — move the parent's `respond` down into the
  siblings that want it instead.
* **One level only.** An `endpoint` inside an `endpoint` raises.

Each child is validated exactly as a standalone endpoint, so a child with `dispatch` and no
inherited or declared `verify` still fails at boot.

Nesting is sugar: a shared options hash splatted with `**`, or a shared lambda passed to
`verify(&lambda)`, expresses the same thing and remains a fine choice.

## The request object

Verifiers, `parse:` and `challenge` blocks all receive an `Axn::Webhooks::Request` — a
Rails-agnostic view, so the same endpoint works behind a Rack mount, a controller, or a plain test
constructor.

| | |
|---|---|
| `raw_body` | the exact bytes the vendor signed (frozen; never re-encoded) |
| `header(name)` | case-insensitive header lookup |
| `params` | the request's **primary** param source (see below) |
| `url` | full URL including scheme, host, mount prefix, and query string |
| `http_method` | upcased (`"POST"`, `"GET"`, …) |

`params` is one source, never a query+form merge:

- **POST with a form body** — `application/x-www-form-urlencoded` (Twilio) or `multipart/form-data`
  (Dropbox Sign) → the form fields. A malformed multipart body yields `{}` rather than raising.
- **Everything else** — JSON POST, and any GET/HEAD → the query string.

`inspect`/`pp` redact `raw_body` and headers, since webhook payloads routinely carry bank account
numbers, credentials and addresses that must not reach logs or exception reports.

## Unparseable bodies

A verified request whose body doesn't parse is **terminal, not retryable** — a redelivery of the same
bytes will never parse either. So the parse step reports and then **acks**:

```ruby
Axn::Webhooks.configure { |c| c.unparseable_status = 400 }   # global; default 200

Axn::Webhooks.inbound :lob do
  verify :hmac, secret: ENV.fetch("LOB_WEBHOOK_SECRET"), signature: header("Lob-Signature")
  dispatch to: "Actions::Lob::HandleWebhook", unparseable_status: 200   # per-endpoint override
end
```

Whatever `parse:` raises is wrapped in `Axn::Webhooks::UnparseableBody` (the original stays reachable
as `cause`) and reported to `Axn.config.on_exception` exactly once. Because the whole step is wrapped
rather than a list of known JSON errors, a custom XML/form/protobuf `parse:` gets the same treatment.

The default is 200 rather than the tidier 400 because [2xx is the only answer every vendor reads as
"stop redelivering"](DESIGN-NOTES.md#why-unparseable-bodies-ack-with-200). A `parse:` proc that does I/O can opt back
into redelivery by raising [`retry_later!`](#asking-for-redelivery).

## Asking for redelivery

A handler can ask the sender to redeliver later without paging:

```ruby
class HandleWebhook
  include Axn::Webhooks::Handler

  def call
    Axn::Webhooks.retry_later!(after: 30) unless dependency_ready?   # => 503, Retry-After: 30
  end
end
```

Raising `Axn::Webhooks::RetryLater` (directly or via the helper) **always** maps to a **503** —
`after:` only controls whether the `Retry-After` header is present. It's rescued around the whole
synchronous dispatch, so the handler, a `parse:` proc, a `with:` extractor and an `otherwise:`
callable can all defer.

> **`include Axn::Webhooks::Handler`, not plain `include Axn`.** The concern includes `Axn` and
> declares `fails_on Axn::Webhooks::RetryLater`, so a deferral settles as a quiet failure. Without it
> you still get the 503, but you *also* page `Axn.config.on_exception` on every single deferral —
> the opposite of the promise.

Only synchronous dispatch can defer: a `retry_later!` raised inside an async worker is just a worker
exception, unrelated to the response already sent.

## Per-vendor observability

```ruby
Axn::Webhooks.configure { |c| c.vendor_facet = :dimension }  # or :tag; default false
```

When set, every `verify`/`dispatch`/`respond`/`challenge` call for a registered endpoint is stamped
with the endpoint's name as that Datadog/OTel facet — `:dimension` for a bounded, low-cardinality
grouping; `:tag` for the higher-cardinality path. Ships `false` so a standalone consumer opts in.

This governs the **vendor** facet only. The [`reason` dimension](#why-verification-failed) is always
stamped — it's a closed enum, so there's no cardinality decision to defer. Group by `reason`, filter
by `vendor`.

---

# Outbound

## Declaring events and subscribers

Declare once (e.g. a Rails initializer), then emit by symbol from wherever the triggering event
happens:

```ruby
Axn::Webhooks.outbound do
  sign :standard_webhooks, secret: -> { ENV.fetch("WEBHOOK_SIGNING_SECRET") }

  event :lead_signed,  to: ["https://partner.example/hooks/leads"]   # static list
  event :lead_closed                                                 # resolved via `subscribers`
  event :invoice_paid, type: "invoice.paid", to: ["https://partner.example/hooks/invoices"]

  subscribers ->(event) { Subscription.where(event:).map { |s| { url: s.url, id: s.id.to_s } } }
end
```

| Declaration | Default | Purpose |
| -- | -- | -- |
| `event :name, to:, type:, vendor:` | — | Declare an emittable event. `type:` overrides the wire type; `vendor:` overrides the facet. |
| `sign :strategy, **opts` / `sign { … }` | — | How to sign each delivery. See [Signing](#signing). |
| `subscribers ->(event) { … }` | `nil` | Default resolver for events with no `to:`. |
| `headers ->(subscriber) { … }` | `nil` | Per-destination extra headers, resolved per attempt. |
| `allowed_hosts %w[…]` | `nil` (any) | Host allowlist; exact match or a leading `*.` wildcard. |
| `allow_url ->(uri) { … }` | `nil` (any) | Arbitrary target predicate. |
| `max_attempts 8` | `8` | Attempts before giving up. |
| `backoff ->(attempt) { … }` | capped exponential | Seconds until the next attempt. |
| `transport MyTransport` | stdlib `net/http` | Injectable HTTP seam. |
| `timeouts open: 5, read: 10` | `5` / `10` | Built-in transport only. |
| `vendor :name` | `nil` | Block-level observability facet default. |
| `user_agent value_or_callable` | `nil` | Suffix: `axn-webhooks/<version> (<value>)`. Plain value or zero-arity callable, resolved per attempt. |

**Wire `type`** defaults to the symbol as a string (`:lead_signed` → `"lead_signed"`).
`emit(:unknown_event)` raises immediately, listing the known events — no silent no-op for a typo. A
statically declared `event :x, to: []` warns at boot. A second `outbound` block replaces the first
and logs a warning; only one is ever active.

### Subscriber rows

`to:` accepts a static Array or a lambda (`->(event) { … }`); `subscribers` is the shared default for
events with no `to:`. Either may resolve to:

- a bare URL **String** — no identity, and
- a **`{ url:, id: }` Hash** — an identity that `sign`'s `secret:`, the `headers` resolver, and
  `Deliver`'s observability can key off of.

An unknown Hash key (e.g. a stray `secret:`) is rejected rather than silently dropped, since it's
almost certainly a credential the caller thought they were setting.

Both resolvers run fresh on **every** `emit`, never memoized at boot, so a DB-backed lambda picks up
rows added or removed at runtime. Resolution runs inline in whatever process called `emit`, so a
store that raises (a database outage) raises out of `emit`.

### Per-subscriber secrets and headers

`sign`'s `secret:` and the `headers` resolver both accept a **one-arity** callable receiving the
resolved `Subscriber`, re-resolved per delivery attempt:

```ruby
Axn::Webhooks.outbound do
  subscribers ->(event) { Subscription.where(event:).map { |s| { url: s.url, id: s.id.to_s } } }

  sign :standard_webhooks, secret: ->(subscriber) { Subscription.find(subscriber.id).signing_secret }
  headers ->(subscriber) { { "authorization" => "Bearer #{Subscription.find(subscriber.id).token}" } }

  allowed_hosts %w[hooks.partner.example *.customer.example]

  event :lead_closed
end
```

> **`subscriber.id` is `nil` for a bare URL String row.** If an event mixes static `to:` URLs with
> `subscribers`-resolved rows, guard for it —
> `subscriber.id ? Subscription.find(subscriber.id).signing_secret : ENV.fetch("DEFAULT_SECRET")` —
> rather than letting `find(nil)` raise on the first static delivery.

Neither value ever enters the job payload; see
[Credentials never enter the queue](DESIGN-NOTES.md#credentials-never-enter-the-queue).

### Host policy

`allowed_hosts` matches case-insensitively; a `*.suffix` entry matches any subdomain of `suffix` but
**not** the bare suffix itself. `allow_url` is the general escape hatch — called with the parsed
`URI`, must return truthy. Both are nil by default (any http(s) URL passes); when both are declared, a
target must pass both.

> **A host policy, not a network one.** Neither resolves DNS, so neither is proof against DNS
> rebinding or a hostname that resolves to a private IP at request time. `uri.host` is a hostname,
> not necessarily an IP literal — an `allow_url` doing IP-range math must parse defensively:

```ruby
allow_url(lambda do |uri|
  ip = begin
    IPAddr.new(uri.host)
  rescue IPAddr::Error
    nil   # not a literal IP — nothing to range-check
  end
  ip.nil? || PRIVATE_IP_RANGES.none? { |r| r.include?(ip) }
end)
```

A static `to:` Array is validated at **boot** (an `ArgumentError` — a declaration mistake); a
resolver's rows are validated identically at **every** `emit`, but collected into
[`rejected`](#the-emit-result) rather than failing the fan-out.

## Signing

### `sign :standard_webhooks`

The default, and the symmetric counterpart to a receiver's
[`verify :standard_webhooks`](#verify-standard_webhooks). The body is the
[Standard Webhooks](https://www.standardwebhooks.com/) envelope; `id` and `timestamp` are mirrored
into the signed headers:

```
POST <subscriber-url>
webhook-id: msg_<uuid>
webhook-timestamp: 1721160000
webhook-signature: v1,<base64 hmac of "id.timestamp.body">
content-type: application/json
user-agent: axn-webhooks/<version>

{"id":"msg_<uuid>","timestamp":1721160000,"type":"lead_signed","data":{"lead_id":42}}
```

`secret:` is a **`whsec_<base64>`** value. A literal one is validated at boot; a callable's resolved
value is checked per attempt.

### `sign :hmac`

For a receiver that expects a plain signature header rather than an envelope:

```ruby
# minimal — one header, signature over the raw body
sign :hmac, secret: -> { ENV.fetch("PARTNER_SECRET") }, header: "X-Signature"

# …or a replay-protectable signature, Slack-style
sign :hmac,
     secret:           -> { ENV.fetch("PARTNER_SECRET") },
     header:           "X-Signature",
     timestamp_header: "X-Timestamp",
     signing_string:   "v0:{timestamp}:{body}",
     prefix:           "v0="
```

| Option | Default | Notes |
| -- | -- | -- |
| `secret:` | required | Plain value, or a 0-/1-arity callable re-resolved per attempt. |
| `header:` | required | There is no universal signature-header name. |
| `timestamp_header:` | `nil` | Required if `signing_string:` references `{timestamp}`. |
| `signing_string:` | `"{body}"` | A **template**. `{timestamp}` and `{body}` are the only placeholders. |
| `digest:` | `:sha256` | |
| `encoding:` | `:hex` | |
| `prefix:` | `nil` | |

`digest:`, `encoding:`, both header names and the template are validated at boot rather than inside
every delivery attempt. Header names must be valid HTTP field tokens, must differ from each other,
and may not collide with anything the pipeline sets after signing (`content-type`, `user-agent`,
`content-length`, `transfer-encoding`) — in every one of those cases the later value would replace
the signature and each delivery would ship unverifiable.

There is no id header here: a signature bound to a per-message id is what `:standard_webhooks` is for.

### Custom signer

```ruby
sign { |id:, timestamp:, body:| { "X-My-Sig" => my_signature(body) } }
```

Return the header Hash. The block may also declare `subscriber:` to receive the resolved Subscriber;
a block that doesn't declare it (or `**`) simply isn't passed one.

## Emitting

```ruby
result = Axn::Webhooks.emit(:lead_signed, data: { lead_id: 42 })
```

`emit` resolves the event's subscribers and enqueues one independent, self-retrying delivery per
target, so one slow or failing subscriber can't block another. Each delivery gets its own stable
`webhook-id`, generated once per (emission × target) and reused across every retry of that delivery,
so receivers can dedup.

### The emit result

| Field | Meaning |
| -- | -- |
| `webhook_ids` | One id per **enqueued** target |
| `target_count` | Rows actually enqueued |
| `deliveries` | One `{ webhook_id:, url:, subscriber_id: }` per target — the correlation to persist a delivery record without re-resolving and trusting ordering |
| `rejected` | `{ target:, reason: }` per row the host/shape policy refused |
| `rejected_count` | How many |
| `failed_count` | Deliveries that came back failed — **sync path only**, always `0` when enqueued async |

A rejected row is neither counted in `target_count` nor delivered to; the rejection is reported once
per `emit` (not once per bad row). `emit` still reports `ok` — the good rows really were enqueued,
and a subscriber being down is not an emit failure.

`failed_count` is about the *path*, not adapter presence: `emit(…, async: false)` runs inline and
counts failures even when an adapter is configured. `target_count - failed_count` is the sync-path
success count.

### Per-call overrides

```ruby
Axn::Webhooks.emit(:lead_signed, data: { lead_id: 42 },
                   to:    "https://one-off.example/hook",  # String or Array
                   async: false)
```

`to:` **replaces** the event's declared targets for that call — it never merges. The event must still
be declared (it supplies the wire `type` and `vendor`), and the URL goes through the same validation
as a declared target, raising rather than being silently rejected.

`async: true` **raises** when no adapter is configured rather than running inline; `async: false`
forces the inline path and suppresses the degraded-mode warning. See
[Async posture](DESIGN-NOTES.md#async-posture-auto-vs-explicit).

There is deliberately **no per-call `headers:`** — it would be serialized into the job payload. Use
the block-level `headers` resolver.

## Delivery, retries, and failure

Each attempt classifies the receiver's response:

| Receiver responds | Delivery does |
| -- | -- |
| **2xx** | success |
| **408, 425, 429, 5xx, timeout, connection error** | retryable → self-reschedule the next attempt |
| **other 4xx** (400, 401/403, 404, 410, 422) | permanent → quiet `fail!`, no retry. Not reported via `on_exception`; the failure message carries a truncated (500-byte) copy of the response body |
| **unexpected exception** (crash / OOM / network raise mid-flight) | propagates → the adapter retries the un-acked job (at-least-once safety net) |

**One self-managed retry engine, adapter-agnostic.** On a retryable response, `Deliver` computes its
own delay and re-enqueues itself via axn's delayed-enqueue seam rather than inheriting whatever
backoff the underlying adapter has — identical behavior across every adapter. `Retry-After` is
honored precisely: `delay = max(backoff(attempt), retry_after_seconds)`, including the HTTP-date
form. The default curve applies **equal jitter** (half fixed, half random, capped at 6h) so a fan-out
whose receiver is down doesn't have every target retry in lockstep.

After `max_attempts`, exhaustion is reported **once** via `Axn.config.on_exception` and delivery
stops. It never raises, so the adapter doesn't also retry an already-exhausted job. With no async
adapter configured at all, a retryable failure is treated the same as an exhausted budget.

Because every attempt reuses the same `webhook-id`, a double-delivery from the crash safety net is
idempotent on the receiver side.

### Transport

The HTTP call is an injectable seam:

```ruby
class MyFaradayTransport
  # Must return an Axn::Webhooks::Outbound::Transport::Response.
  def self.post(url:, body:, headers:)
    res = Faraday.post(url, body, headers)
    Axn::Webhooks::Outbound::Transport::Response.new(status: res.status, headers: res.headers, body: res.body)
  end
end
```

The default is stdlib `net/http` — no new runtime dependency. `timeouts open:`/`read:` reach only the
built-in transport; a custom one owns its own timeout configuration, since the documented seam is
`.post(url:, body:, headers:)` with no timeout kwargs guaranteed. `Response`'s `body:` is optional
(defaults to `nil`) — only `status` is read for the retry classification.

### Boot-time validation

An `outbound` block fails loudly at declaration — rather than as an unexpected exception mid-delivery,
which the async adapter would retry as if it were a network failure — for: a non-positive-Integer
`max_attempts`; a `backoff` that doesn't accept the attempt number; a `to:` that is neither an Array
nor a callable; a static `to:` entry that fails shape or host policy; a malformed `allowed_hosts`; an
`allow_url` or `headers` with the wrong arity; any invalid `sign :hmac` option; and a **literal**
`sign :standard_webhooks` secret that isn't a decodable `whsec_<base64>` value.

What can't be checked at boot is anything depending on runtime state: a callable `to:`'s/`subscribers`'
*return value* (validated at every `emit` instead), and a callable `secret:`'s *resolved value* — only
its **arity** is settled at declaration (0 ignores the subscriber, 1 receives it).

---

# Signature primitive

`Axn::Webhooks::Signature` is a standalone, Rails-agnostic HMAC verifier — usable directly, with no
endpoint involved:

```ruby
Axn::Webhooks::Signature.hmac(
  secret:    ENV["WEBHOOK_SECRET"],
  payload:   request.raw_body,                 # exact bytes the vendor signed
  signature: request.header("X-Signature"),
  digest:    :sha256,                          # :sha256 (default) | :sha1 | :md5
  encoding:  :hex,                             # :hex (default) | :base64 | :base64_urlsafe
  prefix:    nil,                              # e.g. "v0=" for Slack
  timestamp: request.header("X-Timestamp"),    # optional replay guard
  tolerance: 300,
)
```

Always constant-time, and it supports multi-signature (key-rotation) headers.

`hmac` answers *whether* a request verified; `hmac_check` answers *why* it didn't — same check,
returning a `Signature::Check` instead of a boolean (`hmac` is literally `hmac_check(...).ok?`, so
there is only ever one replay window and one comparison):

```ruby
check = Axn::Webhooks::Signature.hmac_check(secret:, payload:, signature:, timestamp:, tolerance: 300)
check.ok?            # => false
check.reason         # => :replay_window
check.skew           # => 10_000  (seconds, signed: positive = in the past)
check.suggested_unit # => nil     (a Symbol only when a pinned `unit:` is what missed the window)
```

## Replay protection

Pass `timestamp:` and `tolerance:` to guard against replayed requests — verification fails if the
timestamp is more than `tolerance` seconds from now in either direction. Epoch seconds, milliseconds
and microseconds are all handled without configuration:

```ruby
Axn::Webhooks::Signature.hmac(
  secret:, payload:, signature:,
  timestamp: request.header("X-Timestamp"),  # epoch s, ms or µs — inferred per timestamp
  tolerance: 300,
)
```

`unit:` defaults to `:auto`, reading the scale off each timestamp's magnitude. Pin it explicitly to
make a change in what a vendor sends fail loudly instead of being absorbed:

```ruby
Axn::Webhooks::Signature.hmac(
  secret:, payload:, signature:, timestamp:, tolerance: 300,
  unit: :ms,   # :auto (default) | :seconds | :ms | :milliseconds | :microseconds
)
```

`unit:` describes only the incoming timestamp's resolution — `tolerance:`/`within:` is always in
seconds. A `Time` timestamp ignores it. An unrecognized value raises `ArgumentError` immediately,
even when `timestamp:` is a `Time`.

The same option is available on `verify :hmac`'s `replay:` hash:

```ruby
Axn::Webhooks.inbound :lob do
  verify :hmac, secret: ENV.fetch("LOB_WEBHOOK_SECRET"), signature: header("X-Lob-Signature"),
                replay: { timestamp: header("X-Lob-Signature-Timestamp"), within: 300, unit: :auto }
end
```

`mismatched_unit` answers "would another scale have fit?" on its own — side-effect-free, so a caller
decides what to do with it:

```ruby
Axn::Webhooks::Signature.mismatched_unit(timestamp:, tolerance: 300, unit: :seconds)  # => :ms
```

---

# Testing

Both registries are process-global, so reset them between examples that declare their own:
`Axn::Webhooks::Inbound.reset!` clears registered vendors, `Axn::Webhooks::Outbound.reset!` clears
the declared `outbound` block.

To exercise an inbound endpoint without a Rack stack, build a `Request` directly:

```ruby
request = Axn::Webhooks::Request.new(
  raw_body:    JSON.dump({ "eventType" => "connection.updated" }),  # the exact bytes you sign
  headers:     { "Content-Type" => "application/json", "X-Signature" => signature },
  url:         "https://example.com/webhooks/codat",
  http_method: "POST",
  params:      {},   # form/query params; `raw_body` is the only required kwarg
)

Axn::Webhooks::Inbound[:codat].verify(request)       # => Axn::Result (just the signature check)
Axn::Webhooks::Inbound[:codat].handle(request)       # => Axn::Result (verify + dispatch)
Axn::Webhooks::Inbound[:codat].to_response(request)  # => Axn::Webhooks::Response (the full mapping)
```

`to_response` is the one to assert against when you care about the status a vendor actually sees —
it's the whole [status mapping](#http-status-reference), which `handle` stops short of. For the Rack
layer, `Request.from_rack(env)` and `Inbound[:codat].call(env)` take a Rack env instead.

On the outbound side, inject a recording double via `transport`:

```ruby
recorder = Class.new do
  def self.calls = (@calls ||= [])
  def self.post(url:, body:, headers:)
    calls << { url:, body:, headers: }
    Axn::Webhooks::Outbound::Transport::Response.new(status: 200, headers: {}, body: "")
  end
end

Axn::Webhooks.outbound do
  sign :hmac, secret: -> { "test-secret" }, header: "X-Signature"
  transport recorder
  event :lead_signed, to: ["https://example.com/hook"]
end

Axn::Webhooks.emit(:lead_signed, data: { lead_id: 42 }, async: false)
recorder.calls.first[:headers]["X-Signature"]  # => the signature the receiver will verify
```

Pass `async: false` so the delivery runs inline and the assertion sees it, rather than depending on
whether the test environment happens to have an async adapter configured.

---

# Development

- `bin/refresh` — pull latest and install dependencies (fails on a dirty working tree).
- `bundle exec rake` — the default task (Rails-free specs + rubocop).
- `bundle exec rake verify` — the full suite (library specs, Rails specs, rubocop).
