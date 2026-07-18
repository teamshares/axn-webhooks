# frozen_string_literal: true

module Axn
  module Webhooks
    module Inbound
      # A registered inbound webhook endpoint. Verifies a request's signature, dispatches
      # the (verified, parsed) event to a handler Axn, and maps the pipeline's outcome to an
      # HTTP Response. Challenge (GET) and Rack mount arrive in a later phase.
      class Endpoint
        def initialize(name:, verifier:, dispatch: nil, respond: nil)
          if dispatch && dispatch[:mode] == :async && respond
            raise Axn::Webhooks::Error,
                  "inbound endpoint `#{name}` declares a custom `respond` but explicit `dispatch mode: :async` " \
                  "can't produce a handler_result for it to read — use `mode: :sync` (or omit mode) or drop the respond block"
          end

          @name = name.to_sym
          @verifier = verifier
          @dispatch = dispatch
          @respond = respond
        end

        attr_reader :name

        # Verify the request's signature. Returns an Axn::Result: ok? when verified,
        # a failure on mismatch, an exception if the verifier raises.
        def verify(request)
          Verify.call(request:, verifier: @verifier, vendor: @name)
        end

        # Full pipeline: verify, then (if a dispatch is declared and verification passed)
        # parse + route to the handler. Returns the final Axn::Result.
        def handle(request)
          verified = verify(request)
          return verified unless verified.ok? && @dispatch

          Dispatch.call(request:, router: @dispatch[:router], parse: @dispatch[:parse],
                        mode: @dispatch[:mode], respond_declared: !@respond.nil?, vendor: @name)
        end

        # The staged HTTP outcome mapping (spec: "Respond + staged outcome model"). Verify and
        # dispatch are mapped in separate branches — deliberately NOT a single outcome->status
        # rule, because a verify failure (401) and a handler business fail! (2xx) are both
        # `outcome.failure?` but mean opposite things at the HTTP layer.
        def to_response(request)
          verified = verify(request)
          return Response.new(status: 401) unless verified.ok?
          return Response.ack unless @dispatch

          dispatched = Dispatch.call(request:, router: @dispatch[:router], parse: @dispatch[:parse],
                                     mode: @dispatch[:mode], respond_declared: !@respond.nil?, vendor: @name)
          response_for(dispatched)
        end

        private

        def response_for(dispatched)
          return Response.new(status: 500) if dispatched.outcome.exception?
          return Response.ack if dispatched.outcome.failure?    # handler fail! -> quiet 2xx, already logged
          return Response.ack if dispatched.handler_result.nil? # otherwise: :ack -> bare ack, nothing to render
          return Response.ack unless @respond

          # Run the user's respond block inside the Respond axn so a raise in it (e.g. reading a
          # missing exposure) becomes a reported 500, not an exception escaping the HTTP mapper.
          responded = Respond.call(handler_result: dispatched.handler_result, responder: @respond, vendor: @name)
          responded.ok? ? responded.response : Response.new(status: 500)
        end
      end
    end
  end
end
