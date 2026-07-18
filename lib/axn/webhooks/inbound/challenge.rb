# frozen_string_literal: true

module Axn
  module Webhooks
    module Inbound
      # The GET-echo handshake (spec: "### 3. Challenge"). Computes the exact Response: 200 echo,
      # 403 when a guard (e.g. Meta hub.verify_token) rejects, 400 when there's no challenge value
      # — all quiet (no page). A resolver or guard that RAISES is a loud exception (reported, mapped
      # to 500 by Endpoint#challenge_response) — never an unhandled crash. Exposes a typed Response.
      class Challenge
        include Axn
        include Axn::Webhooks::VendorFacet

        expects :request, type: Axn::Webhooks::Request
        expects :resolver
        expects :guard, allow_blank: true, default: nil
        exposes :response, type: Axn::Webhooks::Response
        error "Webhook challenge failed"

        def call
          expose response: build_response
        end

        private

        def build_response
          return Response.new(status: 403) if guard && !guard.call(request) # e.g. Meta hub.verify_token mismatch

          value = resolver.call(request)
          return Response.new(status: 400) if value.nil?

          Response.text(value.to_s)
        end
      end
    end
  end
end
