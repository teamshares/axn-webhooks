# frozen_string_literal: true

module Axn
  module Webhooks
    # The verify stage, as an Axn. A signature mismatch is a quiet failure (`fail!` →
    # 401 later, no on_exception page); a verifier that raises is a loud exception
    # (reported to Axn.config.on_exception). The first two rows of the staged-outcome model.
    class Verify
      include Axn
      include Axn::Webhooks::VendorFacet

      expects :request, type: Axn::Webhooks::Request
      expects :verifier
      error "Webhook signature verification failed"

      def call
        fail!("signature mismatch") unless verifier.call(request)
      end
    end
  end
end
