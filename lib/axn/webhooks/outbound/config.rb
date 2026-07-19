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

        # A DECLARED per-event `to:` always wins, even when it resolves to zero targets — a static
        # Array as-is (including `[]`), or a lambda `->(event){…}` invoked (arity-aware, matching
        # Resolvers.resolve) and its result wrapped in Array (nil -> []). The block-level
        # `subscribers` resolver is ONLY consulted when the event declared no `to:` at all
        # (spec[:to].nil?) — never as a fallback for a declared resolver returning nil.
        def targets_for(event)
          spec = fetch(event)
          return Array(resolve_to(spec[:to], event)) unless spec[:to].nil?

          Array(call_resolver(@default_subscribers, event))
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

        # `to:` is "declared" whenever spec[:to] is non-nil — a static value (Array, including
        # `[]`) is returned as-is; a callable is invoked (arity-aware, via call_resolver).
        def resolve_to(raw, event)
          raw.respond_to?(:call) ? call_resolver(raw, event) : raw
        end
      end
    end
  end
end
