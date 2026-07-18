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
event as `event:`, or scalar args via a `with:` extractor.

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
Handlers run **synchronously** for now; async dispatch arrives in a later phase.

**Note on block scoping**: The `inbound do … end` block is evaluated with `instance_exec` against an internal DSL, so `self` inside the block is NOT the surrounding object. You can reference `ENV`, constants, and local variables, but don't call surrounding-object helper methods or access its instance variables from within the block.

## Development

- `bin/refresh` — pull latest and install dependencies (fails on a dirty working tree).
- `bundle exec rake` — run the default task (specs + rubocop) before pushing.
