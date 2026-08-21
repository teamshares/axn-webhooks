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
      # Guards install/reset! only. `config` READS stay unsynchronized: what's published is a
      # frozen Config, so a reader either sees the old one or the new one and never a half-built
      # object — and `config` is read on every delivery attempt, where a lock would be real
      # overhead protecting nothing.
      @mutex = Mutex.new

      class << self
        def install(config)
          @mutex.synchronize do
            unless @config.nil?
              Axn.config.logger.warn(
                "[axn-webhooks] a second `Axn::Webhooks.outbound` block replaces the first — only one outbound declaration is active at a time",
              )
            end

            @config = config
          end
        end

        def reset! = @mutex.synchronize { @config = nil }

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
    #
    # `to:` and `async:` are per-call overrides. `to:` REPLACES the event's declared targets for
    # this call only (never merges) — the event must still be declared, since it supplies the wire
    # `type` and `vendor`. `async: true` requires a configured adapter and raises without one;
    # `async: false` forces the inline path. Omitted means today's `:auto`.
    # rubocop:disable Naming/MethodParameterName
    def self.emit(event, data: {}, to: nil, async: nil)
      Outbound::Emit.call!(event:, data:, to:, async:)
    end
    # rubocop:enable Naming/MethodParameterName
  end
end
