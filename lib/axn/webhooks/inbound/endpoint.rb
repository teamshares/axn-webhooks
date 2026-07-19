# frozen_string_literal: true

module Axn
  module Webhooks
    module Inbound
      # A registered inbound webhook endpoint. Verifies a request's signature, dispatches
      # the (verified, parsed) event to a handler Axn, and maps the pipeline's outcome to an
      # HTTP Response. Challenge (GET) and Rack mount arrive in a later phase.
      class Endpoint
        def initialize(name:, verifier:, dispatch: nil, respond: nil, challenge: nil)
          if dispatch && dispatch[:mode] == :async && respond
            raise Axn::Webhooks::Error,
                  "inbound endpoint `#{name}` declares a custom `respond` but explicit `dispatch mode: :async` " \
                  "can't produce a handler_result for it to read — use `mode: :sync` (or omit mode) or drop the respond block"
          end

          @name = name.to_sym
          @verifier = verifier
          @dispatch = dispatch
          @respond = respond
          @challenge = challenge
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

        # The GET branch (spec: the mount owns the whole path, every verb). Testable without a Rack
        # env, mirroring #verify/#handle/#to_response.
        def challenge_response(request)
          return Response.new(status: 405) unless @challenge

          # The Challenge axn computes the exact Response (200 echo / 403 guard-fail / 400 nil).
          # Only a raising resolver/guard makes it not-ok -> a reported 500.
          result = Challenge.call(request:, resolver: @challenge[:resolver], guard: @challenge[:guard], vendor: @name)
          result.ok? ? result.response : Response.new(status: 500)
        end

        # The Rack app entry point (spec: mount-first packaging). `Inbound[:vendor]` (this object)
        # is directly `mount`-able in Rails routes.rb or `run`-able in a bare Rack::Builder — the
        # mount owns the whole path and every verb: POST -> #to_response, GET -> #challenge_response,
        # anything else -> 405. Named `call`, deliberately reserved since Phase 3 (see #handle).
        def call(env)
          built = BuildRequest.call(env:, vendor: @name)
          return Response.new(status: 500).to_rack unless built.ok?

          request = built.request
          response =
            case request.http_method
            when "POST" then to_response(request)
            when "GET" then challenge_response(request)
            else Response.new(status: 405)
            end
          response.to_rack
        end

        private

        def response_for(dispatched)
          return Response.service_unavailable(retry_after: dispatched.retry_after) if dispatched.retry_later
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
