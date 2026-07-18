# frozen_string_literal: true

module Axn
  module Webhooks
    # Routes a verified request to its handler Axn. Built as an Axn so every loud failure
    # (missing handler, unmatched key, parse error, handler crash) lands in axn's exception
    # bucket — reported once via on_exception, returned as a formatted result — and a handler
    # business `fail!` stays a quiet failure. Handler is invoked with `call!` so its outcome
    # propagates: fail! → this failure (prefixed), raise → this exception (reported once).
    class Dispatch
      include Axn

      expects :request, type: Axn::Webhooks::Request
      expects :router
      expects :parse
      exposes :handler_result, allow_nil: true
      error "Webhook dispatch failed"

      def call
        event = parse.call(request)
        resolution = router.resolve(event)
        return done!("acknowledged") if resolution == :ack

        handler_class, args = resolution
        expose handler_result: handler_class.call!(**args)
      end
    end
  end
end
