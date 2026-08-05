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

    def self.retry_later!(after: nil)
      raise RetryLater.new(retry_after: after)
    end
  end
end
