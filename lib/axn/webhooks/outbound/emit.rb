# frozen_string_literal: true

module Axn
  module Webhooks
    module Outbound
      # Resolves an event's subscribers and enqueues one Deliver per target. Built as an Axn so an
      # unknown event (a typo) is a loud, reported failure instead of today's silent no-op.
      class Emit
        include Axn
        include Axn::Webhooks::VendorFacet

        expects :event
        expects :data, type: Hash, allow_blank: true, default: {}

        def call
          config = Axn::Webhooks::Outbound.config
          type = config.wire_type(event)

          config.targets_for(event).each do |url|
            id = Envelope.new_id
            body = Envelope.build(id:, type:, data:)
            enqueue(url:, webhook_id: id, body:, event: type)
          end
        end

        private

        # Async when an adapter is configured for Deliver, else a warned best-effort sync fallback
        # (no cross-process retries). Presence check only — never branches on adapter type.
        def enqueue(**kwargs)
          if async_configured?
            Deliver.call_async(**kwargs)
          else
            Axn.config.logger.warn(
              "[axn-webhooks] delivering #{kwargs[:event]} synchronously (no async adapter configured) — " \
              "best-effort, no cross-process retries",
            )
            Deliver.call(**kwargs)
          end
        end

        def async_configured?
          return !!Deliver._async_adapter if Deliver.respond_to?(:_async_adapter) && !Deliver._async_adapter.nil?

          !!Axn.config._default_async_adapter
        end
      end
    end
  end
end
