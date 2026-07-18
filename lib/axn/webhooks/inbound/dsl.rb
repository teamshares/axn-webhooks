# frozen_string_literal: true

module Axn
  module Webhooks
    module Inbound
      # Receiver for an `inbound` block: captures declarations (Phase 2: `verify`) and
      # exposes request resolvers. Later phases add dispatch/challenge/respond here.
      class DSL
        # verify :hmac, **opts | verify :standard_webhooks, **opts | verify { |req| ... }
        def verify(strategy = nil, **opts, &block)
          @verify_spec = { strategy:, opts:, block: }
        end

        # dispatch to: "Handler" | dispatch on: ->(e){…}, to: {map}, otherwise:, via: | parse: | mode:
        # rubocop:disable Naming/MethodParameterName
        def dispatch(to: nil, on: nil, otherwise: nil, via: nil, parse: :json, mode: :auto)
          @dispatch_spec = { to:, on:, otherwise:, via:, parse:, mode: }
        end
        # rubocop:enable Naming/MethodParameterName

        # respond { |handler_result| text("...") } — maps a genuine handler success to a
        # Response. Every other outcome (ack, business fail!, verify failure/exception, or a
        # no-dispatch endpoint) always gets the default bare ack, regardless of this declaration
        # — see Endpoint#to_response.
        def respond(&block)
          @respond_block = block
        end

        def header(name) = Resolvers.header(name)
        def raw_body     = Resolvers.raw_body
        def params       = Resolvers.params
        def url          = Resolvers.url

        # Internal: build the verifier callable from the captured declaration.
        def __verifier__
          raise Axn::Webhooks::Error, "inbound endpoint declared no `verify`" unless @verify_spec
          raise Axn::Webhooks::Error, "inbound endpoint `verify` needs a strategy or a block" if @verify_spec[:strategy].nil? && @verify_spec[:block].nil?

          Verifiers.build(**@verify_spec)
        end

        # Internal: build the { router:, parse:, mode: } dispatch config, or nil if none declared.
        def __dispatch__
          return nil unless @dispatch_spec

          spec = @dispatch_spec
          raise Axn::Webhooks::Error, "dispatch mode: must be :sync or :async (got #{spec[:mode].inspect})" unless %i[auto sync async].include?(spec[:mode])

          router = Router.new(to: spec[:to], on: spec[:on], otherwise: spec[:otherwise], via: spec[:via])
          { router:, parse: Parsers.build(spec[:parse]), mode: spec[:mode] }
        end

        # Internal: the captured respond block, or nil if none declared.
        def __respond__ = @respond_block
      end
    end
  end
end
