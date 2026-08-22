# frozen_string_literal: true

module Axn
  module Webhooks
    # Rooted in core's public-error boundary (PRO-2997). `Axn::Error` is a marker MODULE, not a base
    # class — `rescue` matches it by `is_a?` — so the tag costs this hierarchy no ancestry: `Error`
    # stays a plain `StandardError`, and a consuming app's `rescue Axn::Error` catches webhook errors
    # alongside core's. The tag is inherited, so `RetryLater` below is covered automatically.
    class Error < StandardError
      include Axn::Error
    end

    # Raised by a handler (via Axn::Webhooks.retry_later!) to ask the sender to redeliver later —
    # mapped to 503 + Retry-After by the inbound endpoint. Distinct from a crash (a reported 500):
    # a deliberate, un-paged "come back later".
    class RetryLater < Error
      attr_reader :retry_after

      def initialize(message = "retry later", retry_after: nil)
        @retry_after = retry_after
        super(message)
      end
    end

    # Raised by `Dispatch` when the parse step can't turn a verified request's body into an event —
    # wrapping whatever the parser raised (the original stays reachable as `cause`), or raised directly
    # by a custom `parse:` proc that knows its own format is malformed. Terminal by construction: a
    # redelivery of the same bytes will never parse either, so `Inbound::Endpoint` maps it to the
    # configured `unparseable_status` (a 2xx by default) instead of a retry-inviting 500 (PRO-3143).
    # Deliberately NOT in any `fails_on` — it stays an axn exception outcome, so `on_exception` still
    # reports that a vendor is sending garbage. Report, then ack.
    class UnparseableBody < Error; end

    # Raised by Outbound::TargetPolicy when a resolved subscriber row (a static `to:` entry OR a
    # runtime `subscribers`/`to:` lambda's return value) fails shape/host validation — a non-String
    # URL, a non-http(s) scheme, a missing host, an unknown Hash key, or a host the declared
    # `allowed_hosts`/`allow_url` policy rejects. A RUNTIME condition (a DB-backed store can produce
    # a bad row at any time, not just at boot), so it's `Axn::Webhooks::Error`-rooted rather than the
    # plain `ArgumentError` a pure `outbound` block declaration mistake raises — see the error-class
    # split documented above `Outbound::Config#validate_event!`. `Config#resolve_targets` rescues
    # this per-row so one malformed subscriber can't discard the rest of a fan-out.
    class InvalidTarget < Error; end

    def self.retry_later!(after: nil)
      raise RetryLater.new(retry_after: after)
    end
  end
end
