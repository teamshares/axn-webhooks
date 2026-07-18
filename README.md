# axn-webhooks

Inbound webhook handling for [axn](https://github.com/teamshares/axn): verify a vendor's signature, dispatch the event to a handler action, and acknowledge — declared per vendor, and runnable in or out of Rails. The name is a deliberate umbrella: this is the **inbound** half; outbound webhook *signing* is a reserved future sibling built on the same signature primitive.

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
```

Verify a request (dispatch/respond and HTTP mounting land in later phases):

```ruby
result = Axn::Webhooks::Inbound[:codat].verify(request)  # => Axn::Result
result.ok?  # signature valid?
```

### Dispatch to a handler

Add `dispatch` to route the (verified, parsed) event to a handler Axn. The body is parsed as
JSON by default (string keys) — pass `parse:` for other bodies. Handlers receive the whole
event as `event:`, or scalar args via a `with:` extractor. Handler targets are class-name
strings (resolved at request time), not constants.

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
`respond` only for the two real cases that need it: a literal string body, or an
instruction body the handler computed (e.g. TwiML). The block receives the handler's own
`Axn::Result` and runs with `ack`/`text`/`xml` available as bare calls:

```ruby
# DropboxSign requires this exact literal string:
Axn::Webhooks.inbound :dropbox_sign do
  verify { |req| … }
  dispatch to: "Actions::DropboxSign::HandleWebhook"
  respond { |_result| text("Hello API Event Received") }
end

# Twilio call-control: the handler computes TwiML; respond renders it.
Axn::Webhooks.inbound :twilio do
  verify { |req| Twilio::Security::RequestValidator.new(ENV.fetch("TWILIO_AUTH_TOKEN"))
                   .validate(req.url, req.params, req.header("X-Twilio-Signature")) }
  dispatch to: "Actions::Twilio::HandleCall", parse: ->(req) { req.params }
  respond { |result| xml(result.twiml) }   # handler exposes :twiml
end

response = Axn::Webhooks::Inbound[:dropbox_sign].to_response(request)  # => Axn::Webhooks::Response
response.status   # => 200
response.body     # => "Hello API Event Received"
```

`respond` only runs for a genuine handler success — an unmatched event acked via
`otherwise: :ack`, a handler's own business `fail!`, and a verify failure or crash all get
their own fixed status (see below) regardless of any declared `respond`.

### The staged HTTP outcome mapping

`Axn::Webhooks::Inbound[:vendor].to_response(request)` runs the whole pipeline and maps the
outcome to an HTTP status:

| Stage | Outcome | Status |
| -- | -- | -- |
| Verify | signature mismatch, or the verifier itself crashes | 401 |
| Dispatch | missing/unresolvable handler, unmatched event with no `otherwise:`, a parse error, or a handler crash | 500 (reported to `Axn.config.on_exception`) |
| Dispatch | unknown-but-expected event (`otherwise: :ack`) | 2xx ack |
| Handle | the handler's own business `fail!` ("we don't care") | 2xx ack (logged) |
| Handle | success | the declared `respond` body, or a bare 2xx ack |

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

**Note on block scoping**: The `inbound do … end` block is evaluated with `instance_exec` against an internal DSL, so `self` inside the block is NOT the surrounding object. You can reference `ENV`, constants, and local variables, but don't call surrounding-object helper methods or access its instance variables from within the block.

### Mounting

An `Inbound[:vendor]` endpoint is a Rack app — mount it directly, no controller needed:

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
A missing/rejected challenge is a quiet 400; a `challenge`/`if:` proc that raises is reported and
mapped to 500. (Slack's in-band `url_verification` handshake is NOT this — it's a normal `dispatch`
entry, since Slack sends it as a POST event, not a GET.)

### Per-vendor observability (`vendor_facet`)

```ruby
Axn::Webhooks.configure { |c| c.vendor_facet = :dimension }  # or :tag; default false
```

When set, every `verify`/`dispatch`/`respond`/`challenge` call for a registered endpoint is stamped
with the endpoint's registered name as that Datadog/OTel facet — `:dimension` for a bounded,
low-cardinality grouping (Teamshares' choice); `:tag` for the higher-cardinality path. Ships `false`
(no stamping) so a standalone consumer opts in explicitly.

## Development

- `bin/refresh` — pull latest and install dependencies (fails on a dirty working tree).
- `bundle exec rake` — run the default task (specs + rubocop) before pushing.
