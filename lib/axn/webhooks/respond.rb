# frozen_string_literal: true

module Axn
  module Webhooks
    # The respond stage as an Axn: runs the endpoint's custom `respond` block against the handler's
    # result to build a Response. Built as an Axn so a raise inside the (user-supplied) respond block
    # — e.g. reading an exposure the handler forgot to set — is reported once via on_exception and
    # mapped to a 500 by Endpoint#to_response, never an unhandled exception escaping the HTTP mapper.
    class Respond
      include Axn

      expects :handler_result
      expects :responder
      # Type-constrained: a respond block that returns a non-Response (e.g. a raw String instead
      # of `text("…")`) fails outbound validation here → mapped to a 500, preserving the
      # `to_response -> Response` contract rather than leaking a bad object to the Rack renderer.
      exposes :response, type: Axn::Webhooks::Response
      error "Webhook respond failed"

      def call
        expose response: Inbound::RespondContext.new.instance_exec(handler_result, &responder)
      end
    end
  end
end
