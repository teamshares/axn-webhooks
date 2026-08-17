# frozen_string_literal: true

module Axn
  module Webhooks
    module Inbound
      # The challenge-required precondition, as an Axn — for the same reason the verifier, the
      # `parse:` step and the GET challenge resolver each have one: it is request-dependent code the
      # gem does not own, reading adversarial input. It runs FIRST on the POST path, ahead of every
      # other boundary, so a raise here would otherwise leave Endpoint#call as an unhandled Rack
      # exception rather than a reported one and a controlled response.
      #
      # A crash settles not-ok, which Endpoint reads as "can't tell" and answers by verifying
      # normally — the behaviour from before the precondition existed. Safe by construction: Verify
      # still decides, so a broken predicate can neither dispatch an unauthenticated request nor drop
      # an authenticated one. It costs the telemetry saving until it's fixed, and says so once via
      # on_exception rather than failing silently.
      class ChallengeRequired
        include Axn
        include Axn::Webhooks::VendorFacet

        expects :request, type: Axn::Webhooks::Request, sensitive: true
        # The verifier's bound `#challenge_required?` method, or a declared block. Sensitive for the
        # same reason Verify's `verifier:` is: a bound method renders its receiver, which for
        # `verify :basic_auth` is the object holding the vendor's credentials.
        expects :predicate, sensitive: true
        exposes :required, allow_blank: true, default: false
        error "Webhook challenge-required check failed"

        def call
          expose required: !!predicate.call(request)
        end
      end
    end
  end
end
