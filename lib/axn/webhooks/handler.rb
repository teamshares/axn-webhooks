# frozen_string_literal: true

module Axn
  module Webhooks
    # Include in a webhook handler to get `Axn` plus the retry_later! contract: a RetryLater
    # raised by the handler is treated as a FAILURE (not a reported exception), so asking the
    # sender to redeliver never pages. Dispatch still maps it to 503 (+ Retry-After).
    module Handler
      def self.included(base)
        base.include(Axn)
        base.fails_on(Axn::Webhooks::RetryLater)
      end
    end
  end
end
