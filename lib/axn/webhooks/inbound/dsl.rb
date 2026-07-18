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

        # challenge ->(req){ req.params["challenge"] }                          — Nylas
        # challenge ->(req){ req.params["hub.challenge"] }, if: ->(req){ ... }  — Meta
        def challenge(resolver, if: nil)
          # `if:` shadows Ruby's `if` keyword inside this method body — must read it back via
          # binding.local_variable_get, not a bare `if` reference (that's a syntax trap, not a var).
          guard = binding.local_variable_get(:if)
          @challenge_spec = { resolver:, guard: }
        end

        def header(name) = Resolvers.header(name)
        def raw_body     = Resolvers.raw_body
        def params       = Resolvers.params
        def url          = Resolvers.url

        # Internal: build the verifier callable from the captured declaration.
        # For challenge-only endpoints (no dispatch, no verify declared), return a no-op verifier
        # that always succeeds — a challenge-only endpoint just handshakes the GET and 200-acks any
        # POST, so there's no unverified processing to guard against.
        # `verify` is REQUIRED whenever `dispatch` is declared — dispatching an unverified webhook
        # would run the handler on an unauthenticated request.
        def __verifier__
          unless @verify_spec
            # Nothing declared at all: bare endpoint, always an error.
            raise Axn::Webhooks::Error, "inbound endpoint declared no `verify`" if @dispatch_spec.nil? && @challenge_spec.nil?

            # `dispatch` without `verify` is unsafe regardless of whether `challenge` is also present.
            if @dispatch_spec
              raise Axn::Webhooks::Error,
                    "inbound endpoint with `dispatch` must declare `verify` — dispatching an unverified webhook is unsafe"
            end

            # Challenge-only endpoint (no dispatch): return a no-op verifier.
            return ->(_request) { true }
          end

          raise Axn::Webhooks::Error, "inbound endpoint `verify` needs a strategy or a block" if @verify_spec[:strategy].nil? && @verify_spec[:block].nil?

          Verifiers.build(**@verify_spec)
        end

        # Internal: build the { router:, parse:, mode: } dispatch config, or nil if none declared.
        def __dispatch__
          return nil unless @dispatch_spec

          spec = @dispatch_spec
          unless %i[auto sync async].include?(spec[:mode])
            raise Axn::Webhooks::Error, "dispatch mode: must be :sync, :async, or :auto (got #{spec[:mode].inspect})"
          end

          router = Router.new(to: spec[:to], on: spec[:on], otherwise: spec[:otherwise], via: spec[:via])
          { router:, parse: Parsers.build(spec[:parse]), mode: spec[:mode] }
        end

        # Internal: the captured respond block, or nil if none declared.
        def __respond__ = @respond_block

        # Internal: the captured { resolver:, guard: } challenge declaration, or nil if none.
        def __challenge__ = @challenge_spec
      end
    end
  end
end
