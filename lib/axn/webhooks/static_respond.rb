# frozen_string_literal: true

module Axn
  module Webhooks
    # The static_respond stage as an Axn: runs the endpoint's static_respond block — which reads
    # no handler result, unlike Respond — to build a Response. Built as an Axn so a raise inside
    # the (user-supplied) block is reported once via on_exception and mapped to a 500 by
    # Endpoint#default_ack, never an unhandled exception escaping the HTTP mapper.
    class StaticRespond
      include Axn
      include Axn::Webhooks::VendorFacet

      expects :responder
      exposes :response, type: Axn::Webhooks::Response
      error "Webhook static_respond failed"

      def call
        expose response: Inbound::RespondContext.new.instance_exec(&responder)
      end
    end
  end
end
