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

        exposes :webhook_ids, type: Array, allow_blank: true, default: []
        exposes :target_count, type: Integer, default: 0

        # Bounded to the events a sending app declares — same shape as inbound's unconditional
        # `reason` dimension, not a per-request identity.
        dimension :event, -> { event.to_s }

        def call
          config = Axn::Webhooks::Outbound.config
          type = config.wire_type(event)
          warn_sync_fallback(type) unless async_configured?

          ids = config.targets_for(event).map do |url|
            id = Envelope.new_id
            body = Envelope.build(id:, type:, data:)
            enqueue(url:, webhook_id: id, body:, event: type, vendor:)
            id
          end
          expose(webhook_ids: ids, target_count: ids.size)
        end

        private

        # Overrides the plain `expects :vendor` reader VendorFacet declared above. Computed FRESH on
        # every call (not memoized into an ivar set inside `#call`): axn resolves `dimension`/`tag`
        # facets input-phase, i.e. eagerly BEFORE the body runs, so a value only set inside `#call`
        # would still read as unset there — Emit's own `:vendor` dimension/tag would stamp nil even
        # though the identical lookup, threaded down to `Deliver`, stamps correctly (Codex P2
        # finding). Reading `config.vendor_for(event)` here still keeps `fetch`'s unknown-event raise
        # inside axn's executor (whichever facet-resolution or body call reaches it first is already
        # running under axn's own exception-reporting boundary) — the ordering `Axn::Webhooks.emit`'s
        # comment cares about is never resolving this ahead of `Emit.call!` itself.
        def vendor = Axn::Webhooks::Outbound.config.vendor_for(event)

        # Async when an adapter is configured for Deliver, else a warned best-effort sync fallback
        # (no cross-process retries). Presence check only — never branches on adapter type.
        def enqueue(**)
          if async_configured?
            Deliver.call_async(**)
          else
            Deliver.call(**)
          end
        end

        # Warned ONCE per emit (not once per target) — a high-fan-out event would otherwise spam
        # one line per subscriber for what is a single configuration fact.
        def warn_sync_fallback(type)
          Axn.config.logger.warn(
            "[axn-webhooks] delivering #{type} synchronously (no async adapter configured) — " \
            "best-effort, no cross-process retries",
          )
        end

        def async_configured?
          return !!Deliver._async_adapter if Deliver.respond_to?(:_async_adapter) && !Deliver._async_adapter.nil?

          Axn.config.default_async?
        end
      end
    end
  end
end
