# frozen_string_literal: true

module Axn
  module Webhooks
    module Outbound
      # Receiver for the `Axn::Webhooks.outbound do … end` block.
      class DSL
        def initialize
          @events = {}
          @sign_spec = nil
          @default_subscribers = nil
          @max_attempts = nil
          @backoff = nil
          @transport = nil
        end

        def sign(strategy = nil, **opts, &block)
          @sign_spec = { strategy:, opts:, block: }
        end

        def subscribers(resolver = nil, &block)
          @default_subscribers = resolver || block
        end

        def max_attempts(value) = @max_attempts = value
        def backoff(callable = nil, &block) = @backoff = callable || block
        def transport(obj) = @transport = obj

        # rubocop:disable Naming/MethodParameterName
        def event(name, to: nil, type: nil)
          @events[name.to_sym] = { to:, type: }
        end
        # rubocop:enable Naming/MethodParameterName

        # Internal: build the resolved Config, validating declarations.
        def __config__
          raise Axn::Webhooks::Error, "outbound block must declare `sign`" if @sign_spec.nil?

          @events.each do |name, spec|
            next unless spec[:to].is_a?(Array) && spec[:to].empty?

            Axn.config.logger.warn("[axn-webhooks] outbound event #{name.inspect} declares an empty `to:` — it will deliver nowhere")
          end

          Config.new(
            signer: Signer.build(**@sign_spec),
            events: @events,
            default_subscribers: @default_subscribers,
            max_attempts: @max_attempts,
            backoff: @backoff,
            transport: @transport,
          )
        end
      end
    end
  end
end
