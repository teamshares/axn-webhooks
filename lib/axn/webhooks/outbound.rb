# frozen_string_literal: true

require_relative "outbound/callable_arity"
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
    #
    # `vendor:` is deliberately NOT resolved here: `Config#vendor_for` raises the same unknown-event
    # error that `Emit` itself already raises internally (via `config.wire_type`), but resolving it
    # ahead of `call!` would raise before axn's executor ever runs -- bypassing `on_exception`
    # reporting for what should be a loud, REPORTED failure (Codex P2 finding). `Emit` resolves its
    # own vendor once it's running inside that boundary.
    def self.emit(event, data: {})
      Outbound::Emit.call!(event:, data:)
    end
  end
end
