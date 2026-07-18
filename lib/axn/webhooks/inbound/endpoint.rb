# frozen_string_literal: true

module Axn
  module Webhooks
    module Inbound
      # A registered inbound webhook endpoint. Phase 2 carries only the verifier;
      # later phases add dispatch/challenge/respond.
      class Endpoint
        def initialize(name:, verifier:, dispatch: nil)
          @name = name.to_sym
          @verifier = verifier
          @dispatch = dispatch
        end

        attr_reader :name

        # Verify the request's signature. Returns an Axn::Result: ok? when verified,
        # a failure on mismatch, an exception if the verifier raises.
        def verify(request)
          Verify.call(request:, verifier: @verifier)
        end

        # Full pipeline: verify, then (if a dispatch is declared and verification passed)
        # parse + route to the handler. Returns the final Axn::Result.
        def handle(request)
          verified = verify(request)
          return verified unless verified.ok? && @dispatch

          Dispatch.call(request:, router: @dispatch[:router], parse: @dispatch[:parse])
        end
      end
    end
  end
end
