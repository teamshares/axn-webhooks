# frozen_string_literal: true

require_relative "inbound/dsl"
require_relative "inbound/endpoint"
require_relative "inbound/router"

module Axn
  module Webhooks
    # Process-global registry of inbound webhook endpoints, populated by
    # `Axn::Webhooks.inbound(:vendor) { ... }` and looked up as `Inbound[:vendor]`.
    module Inbound
      @registry = {}

      class << self
        def register(name, endpoint) = @registry[name.to_sym] = endpoint
        def [](name) = @registry.fetch(name.to_sym) { raise KeyError, "no inbound webhook registered for #{name.inspect}" }
        def registered = @registry.keys
        def reset! = @registry.clear
      end
    end

    # Declare an inbound webhook endpoint. Evaluated at boot (e.g. a Rails initializer)
    # so registration is deterministic, in or out of Rails.
    def self.inbound(name, &block)
      raise ArgumentError, "Axn::Webhooks.inbound requires a block" unless block

      dsl = Inbound::DSL.new
      dsl.instance_exec(&block)
      Inbound.register(
        name,
        Inbound::Endpoint.new(
          name:,
          verifier: dsl.__verifier__,
          dispatch: dsl.__dispatch__,
          respond: dsl.__respond__,
          challenge: dsl.__challenge__,
        ),
      )
    end
  end
end
