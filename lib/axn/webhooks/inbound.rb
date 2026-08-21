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
      # declaration name => the registry keys it owns. Once one `inbound :slack` can produce N
      # endpoints, re-declaring it has to be able to REMOVE keys, not just overwrite them.
      @declared = {}

      class << self
        def register(name, endpoint) = @registry[name.to_sym] = endpoint
        def [](name) = @registry.fetch(name.to_sym) { raise KeyError, "no inbound webhook registered for #{name.inspect}" }
        def registered = @registry.keys

        # Publish everything one `inbound <name>` declaration defines, dropping whatever that same
        # declaration registered last time. Covers every transition — fewer children, more children,
        # nested becoming plain, plain becoming nested — each of which previously left a route
        # mounted with its old verifier and handler (Codex review).
        #
        # Ownership is per declaration name, so two declarations whose names collide (`inbound
        # :slack` with `endpoint(:events)` vs. a plain `inbound :slack_events`) still race for the
        # shared key, last writer winning. That predates nesting and needs a real naming decision,
        # not bookkeeping.
        def replace_declaration(name, endpoints)
          key = name.to_sym
          (@declared[key] || []).each { |registered_name| @registry.delete(registered_name) }
          endpoints.each { |endpoint_name, endpoint| @registry[endpoint_name] = endpoint }
          @declared[key] = endpoints.keys
        end

        def reset!
          @registry.clear
          @declared.clear
        end
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
      return Inbound.replace_declaration(name, { name.to_sym => build_endpoint(name, dsl) }) if children.empty?

      # A parent with children is a container, not an endpoint. A top-level `dispatch` is what
      # would make it look like one, and registering both it and the children would leave an extra
      # endpoint nobody mounted, silently — so that combination is a declaration mistake, caught at
      # boot. A parent `respond`/`static_respond` is NOT: it renders nothing on its own, and
      # sharing one renderer across a vendor's endpoints is precisely what nesting is for, so it
      # inherits like every other declaration (Codex review).
      if dsl.__dispatch_declared?
        raise ArgumentError,
              "inbound #{name.inspect} declares `endpoint` blocks AND its own `dispatch` — a parent " \
              "with endpoints registers nothing itself; move the dispatch into an endpoint"
      end

      # Build and validate EVERY child before publishing any: the registry is process-global, so
      # registering as we go left earlier children live when a later one raised — a rescued
      # declaration failure or a reload would mix endpoints from different declarations
      # (Codex review).
      built = children.map { |child, child_block| [:"#{name}_#{child}", build_endpoint(:"#{name}_#{child}", dsl.__child_dsl__(child_block))] }
      Inbound.replace_declaration(name, built.to_h)
    end

    # Each child is a complete, independently valid endpoint by the time it gets here, so the
    # existing per-endpoint validation (__verifier__'s "declared no `verify`" check, Endpoint's
    # respond/static_respond exclusivity) runs per child, unchanged.
    def self.build_endpoint(name, dsl)
      Inbound::Endpoint.new(
        name:,
        verifier: dsl.__verifier__,
        dispatch: dsl.__dispatch__,
        respond: dsl.__respond__,
        static_respond: dsl.__static_respond__,
        challenge: dsl.__challenge__,
        unauthorized_headers: dsl.__unauthorized_headers__,
        challenge_required: dsl.__challenge_required__,
      )
    end
    private_class_method :build_endpoint
  end
end
