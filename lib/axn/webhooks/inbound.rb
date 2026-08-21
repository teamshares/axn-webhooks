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
    #
    # With one or more nested `endpoint` blocks, this registers one endpoint per child, named
    # :"#{name}_#{child}", and does NOT register `name` itself — see Inbound::DSL#endpoint.
    def self.inbound(name, &block)
      raise ArgumentError, "Axn::Webhooks.inbound requires a block" unless block

      dsl = Inbound::DSL.new
      dsl.instance_exec(&block)
      children = dsl.__children__
      return register_endpoint(name, dsl) if children.empty?

      # A parent with children is a container, not an endpoint. Registering it too would leave a
      # third endpoint nobody mounted, silently — so a top-level dispatch/respond alongside
      # `endpoint` blocks is a declaration mistake, caught at boot.
      if dsl.__dispatch_declared? || dsl.__respond__ || dsl.__static_respond__
        raise ArgumentError,
              "inbound #{name.inspect} declares `endpoint` blocks AND its own dispatch/respond — a parent " \
              "with endpoints registers nothing itself; move those declarations into an endpoint"
      end

      children.each { |child, child_block| register_endpoint(:"#{name}_#{child}", dsl.__child_dsl__(child_block)) }
    end

    # Each child is a complete, independently valid endpoint by the time it gets here, so the
    # existing per-endpoint validation (__verifier__'s "declared no `verify`" check, Endpoint's
    # respond/static_respond exclusivity) runs per child, unchanged.
    def self.register_endpoint(name, dsl)
      Inbound.register(
        name,
        Inbound::Endpoint.new(
          name:,
          verifier: dsl.__verifier__,
          dispatch: dsl.__dispatch__,
          respond: dsl.__respond__,
          static_respond: dsl.__static_respond__,
          challenge: dsl.__challenge__,
          unauthorized_headers: dsl.__unauthorized_headers__,
          challenge_required: dsl.__challenge_required__,
        ),
      )
    end
    private_class_method :register_endpoint
  end
end
