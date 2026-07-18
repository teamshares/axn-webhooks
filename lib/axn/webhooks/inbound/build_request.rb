# frozen_string_literal: true

module Axn
  module Webhooks
    module Inbound
      # Wraps Request.from_rack in an Axn boundary so a malformed/adversarial env (missing
      # rack.input, etc.) is reported via Axn.config.on_exception and mapped to a clean 500 by
      # Endpoint#call, never an unhandled exception escaping the Rack app.
      class BuildRequest
        include Axn
        include Axn::Webhooks::VendorFacet

        expects :env
        exposes :request, type: Axn::Webhooks::Request
        error "Webhook Rack request parsing failed"

        def call
          expose request: Axn::Webhooks::Request.from_rack(env)
        end
      end
    end
  end
end
