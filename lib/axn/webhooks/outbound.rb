# frozen_string_literal: true

require_relative "outbound/signer"
require_relative "outbound/envelope"
require_relative "outbound/transport"
require_relative "outbound/config"
require_relative "outbound/dsl"
require_relative "outbound/deliver"
require_relative "outbound/emit"

module Axn
  module Webhooks
    # Process-global registration for outbound webhook emission (a single `outbound` block).
    module Outbound
      @config = nil

      class << self
        def install(config)
          unless @config.nil?
            Axn.config.logger.warn(
              "[axn-webhooks] a second `Axn::Webhooks.outbound` block replaces the first — only one outbound declaration is active at a time",
            )
          end

          @config = config
        end

        def reset! = @config = nil

        def config
          @config || raise(Axn::Webhooks::Error, "no `outbound` block declared — call Axn::Webhooks.outbound { … } at boot")
        end
      end
    end

    # Declare outbound emission. Evaluated at boot (e.g. a Rails initializer).
    def self.outbound(&block)
      raise ArgumentError, "Axn::Webhooks.outbound requires a block" unless block

      dsl = Outbound::DSL.new
      dsl.instance_exec(&block)
      Outbound.install(dsl.__config__)
    end

    # Emit an outbound webhook event. Fans out one signed, self-retrying delivery per subscriber.
    # Raises loudly (Axn::Webhooks::Error) on an unknown event.
    def self.emit(event, data: {})
      Outbound::Emit.call!(event:, data:, vendor: Outbound.config.vendor_for(event))
    end
  end
end
