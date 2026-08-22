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

        # Per-call overrides (both nil = declaration-time behavior). `to:` is a URL String or an
        # Array of them; `async:` is a tri-state — nil (:auto), true (demand async), false (force
        # sync). `allow_blank` on both: nil is the "not given" signal, and `false` is blank too.
        expects :to, allow_blank: true, default: nil
        # `type: :boolean` is the tri-state guard: without it a config-derived `async: "false"` is
        # truthy and demands async — the exact opposite of what the caller asked for (Codex review).
        expects :async, type: :boolean, allow_nil: true, default: nil

        # Kept for back-compat -- now derived from `deliveries` rather than being its own tally,
        # so ordering is documented rather than incidental (`webhook_ids == deliveries.map { |d|
        # d[:webhook_id] }`).
        exposes :webhook_ids, type: Array, allow_blank: true, default: []
        # Rows actually ENQUEUED, not rows resolved -- a malformed row is now caught by
        # `resolve_targets`/`TargetPolicy` before it ever reaches here (see `rejected_count` below),
        # where before it got a webhook_id and was counted despite `Deliver` immediately failing its
        # own `expects :url, type: String` validation.
        exposes :target_count, type: Integer, default: 0

        # Sync fallback only: how many of `target_count` deliveries came back failed. ALWAYS 0 on
        # the async path — nothing has failed at emit time there; failures happen later, and
        # `Deliver` reports them itself (exhaustion via on_exception, a permanent 4xx via its own
        # result). `nil`-when-async would be more honest AND would turn every
        # `result.failed_count > 0` into a NoMethodError, so the footgun costs more than the
        # precision buys.
        exposes :failed_count, type: Integer, default: 0

        # `{ webhook_id:, url:, subscriber_id: }` per enqueued target -- the correlation a DB-backed
        # sender wants to persist one delivery record per subscription, without re-resolving
        # `subscribers`/`to:` and trusting undocumented ordering.
        exposes :deliveries, type: Array, allow_blank: true, default: []
        # Rows `TargetPolicy` refused (a malformed row, or one the declared `allowed_hosts`/
        # `allow_url` policy rejects) -- collected rather than discarded, so a bad row never
        # silently disappears from what `target_count` used to (over)count. `emit` still reports
        # `ok?` (the good rows really were enqueued); a caller that cares checks `rejected_count`.
        exposes :rejected_count, type: Integer, default: 0
        exposes :rejected, type: Array, allow_blank: true, default: []

        # Bounded to the events a sending app declares — same shape as inbound's unconditional
        # `reason` dimension, not a per-request identity.
        dimension :event, -> { event.to_s }

        def call
          config = Axn::Webhooks::Outbound.config
          type = config.wire_type(event)
          use_async = async?
          # Only the :auto path is a DEGRADED mode worth warning about — an explicit `async: false`
          # is the caller getting exactly what they asked for.
          warn_sync_fallback(type) if async.nil? && !use_async

          resolution = resolve_targets(config)
          report_rejections(resolution.rejections) if resolution.rejections.any?

          deliveries = []
          failed = 0
          resolution.subscribers.each do |subscriber|
            id = Envelope.new_id
            body = Envelope.build(id:, type:, data:)
            delivered = enqueue(use_async, url: subscriber.url, webhook_id: id, body:, event: type, vendor:,
                                           subscriber_id: subscriber.id)
            failed += 1 if delivered && !delivered.ok?
            deliveries << { webhook_id: id, url: subscriber.url, subscriber_id: subscriber.id }
          end

          expose(webhook_ids: deliveries.map { |d| d[:webhook_id] }, target_count: deliveries.size, failed_count: failed,
                 deliveries:, rejected_count: resolution.rejections.size, rejected: resolution.rejections)
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
        # Returns Deliver's own result on the sync path, or nil when the delivery was ENQUEUED —
        # an enqueue can't know the eventual outcome, so there is no result to report and nothing
        # to count as failed (see the `failed_count` exposure above).
        def enqueue(use_async, **)
          if use_async
            Deliver.call_async(**)
            nil
          else
            Deliver.call(**)
          end
        end

        # A per-call `to:` REPLACES resolution entirely — the declared `to:`/`subscribers` is not
        # consulted and not appended to, the same no-silent-merge stance Config#resolve_subscribers
        # takes for a declared resolver that returns nil. Validated here rather than at boot (it
        # can't be known earlier) and as an Axn::Webhooks::Error, not the ArgumentError a declaration
        # mistake gets: this one is raised per call, on caller-supplied runtime data. Goes through
        # the SAME TargetPolicy (including the declared `allowed_hosts`/`allow_url`) as a declared
        # `to:`/`subscribers` resolver -- a one-off override is not a way around the host policy.
        # Any rejection here raises immediately rather than being collected: the caller supplied
        # exactly this URL, on purpose, this one call; a typo deserves an immediate raise; unlike a
        # DB-backed resolver returning many rows where one bad one shouldn't sink the rest.
        def resolve_targets(config)
          return config.resolve_subscribers(event) if to.nil?

          subscribers = Array(to).map do |target|
            TargetPolicy.check!(target, allowed_hosts: config.allowed_hosts, allow_url: config.allow_url)
          rescue Axn::Webhooks::InvalidTarget => e
            raise Axn::Webhooks::Error, "emit(#{event.inspect}, to:) #{e.message}"
          end
          Config::Resolution.new(subscribers:, rejections: [])
        end

        # Reported ONCE per emit (a single fact: "N rows were rejected"), not once per rejected row
        # -- the same once-per-emit discipline `warn_sync_fallback` already follows. Best-effort: a
        # broken reporter must not turn "some rows were bad" into a crash of an otherwise-successful
        # emit (the same reasoning Deliver's own `report_exhaustion` documents).
        def report_rejections(rejections)
          Axn::Extensions.best_effort("reporting rejected outbound targets", action: self) do
            Axn.config.on_exception(
              Axn::Webhooks::Error.new("#{rejections.size} outbound target(s) rejected for #{event}"),
              action: self,
              context: { event: event.to_s, rejections: },
            )
          end
        end

        # Tri-state. An explicit `true` with no adapter RAISES rather than degrading: a missing
        # adapter falls back to sync only under `:auto`, never under an explicit request (the same
        # rule inbound's Dispatch#dispatch_async enforces, for the same reason — something marked
        # async usually is so because running it inline would blow someone's time budget).
        def async?
          return async_configured? if async.nil?
          return false unless async

          unless async_configured?
            raise Axn::Webhooks::Error,
                  "emit(#{event.inspect}, async: true) requires an axn async adapter, but none is " \
                  "configured for #{Deliver} (add `async :sidekiq`/`async :active_job` to it, or set a global default)"
          end

          true
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
