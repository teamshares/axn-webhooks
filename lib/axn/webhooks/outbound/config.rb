# frozen_string_literal: true

module Axn
  module Webhooks
    module Outbound
      # The resolved, immutable outbound declaration. One per process (a single `outbound` block).
      class Config
        DEFAULT_MAX_ATTEMPTS = 8
        DEFAULT_BACKOFF = ->(attempt) { [30 * (3**(attempt - 1)), 6 * 3600].min }

        def initialize(signer:, events:, default_subscribers:, max_attempts:, backoff:, transport:)
          @signer = signer
          @events = events # { Symbol => { to:, type: } }
          @default_subscribers = default_subscribers
          @max_attempts = max_attempts || DEFAULT_MAX_ATTEMPTS
          @backoff = backoff || DEFAULT_BACKOFF
          @transport = transport || Transport
        end

        attr_reader :signer, :max_attempts, :backoff, :transport

        def events = @events.keys

        def wire_type(event)
          fetch(event)[:type] || event.to_s
        end

        # Per-event `to:` wins — a static Array as-is, or a lambda `->(event){…}` invoked
        # (arity-aware, matching Resolvers.resolve); else the block-level `subscribers` resolver
        # (also invoked arity-aware); else [].
        def targets_for(event)
          spec = fetch(event)
          raw = spec[:to]
          raw = call_resolver(raw, event) if raw.respond_to?(:call)
          list = raw || call_resolver(@default_subscribers, event) || []
          Array(list)
        end

        private

        def fetch(event)
          @events.fetch(event.to_sym) do
            raise Axn::Webhooks::Error,
                  "unknown outbound event #{event.inspect} (known: #{events.map(&:inspect).join(', ')})"
          end
        end

        def call_resolver(callable, event)
          return nil if callable.nil?

          callable.arity.zero? ? callable.call : callable.call(event)
        end
      end
    end
  end
end
