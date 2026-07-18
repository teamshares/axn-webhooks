# frozen_string_literal: true

require_relative "outbound/signer"
require_relative "outbound/envelope"
require_relative "outbound/transport"
require_relative "outbound/config"
require_relative "outbound/dsl"
require_relative "outbound/deliver"

module Axn
  module Webhooks
    # Process-global registration for outbound webhook emission (a single `outbound` block).
    module Outbound
      @config = nil

      class << self
        def install(config) = @config = config
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

    # Local stand-in for the future promoted axn-core soft-error helper (see the outbound spec's
    # Dependencies): logs a swallowed exception, but raises in development when configured.
    def self.swallow_soft_error(desc, exception:)
      raise exception if Axn.config.raise_piping_errors_in_dev && Axn.config.env.development?

      Axn.config.logger.warn("[axn-webhooks] ignoring error while #{desc}: #{exception.class}: #{exception.message}")
      nil
    end
  end
end
