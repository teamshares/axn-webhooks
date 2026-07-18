# axn-webhooks

An [axn](https://github.com/teamshares/axn)-consuming gem.

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

Declare each vendor webhook in one place (e.g. a Rails initializer), grouped by vendor:

```ruby
Axn::Webhooks.inbound :merge do
  verify :hmac,
    secret:    ENV.fetch("MERGE_WEBHOOK_SIGNATURE_KEY"),
    signature: header("X-Merge-Webhook-Signature"),
    encoding:  :base64_urlsafe
end

Axn::Webhooks.inbound :codat do
  verify :standard_webhooks, secret: ENV.fetch("CODAT_WEBHOOK_SECRET")
end

Axn::Webhooks.inbound :twilio do
  verify { |req| Twilio::Security::RequestValidator.new(ENV.fetch("TWILIO_AUTH_TOKEN"))
                   .validate(req.url, req.params, req.header("X-Twilio-Signature")) }
end
```

Verify a request (dispatch/respond and HTTP mounting land in later phases):

```ruby
result = Axn::Webhooks::Inbound[:merge].verify(request)  # => Axn::Result
result.ok?  # signature valid?
```

## Development

- `bin/refresh` — pull latest and install dependencies (fails on a dirty working tree).
- `bundle exec rake` — run the default task (specs + rubocop) before pushing.
