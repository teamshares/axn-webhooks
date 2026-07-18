# frozen_string_literal: true

module Axn
  module Webhooks
    # Routes a verified request to its handler Axn. Built as an Axn so every loud failure
    # (missing handler, unmatched key, parse error, handler crash, or an async enqueue with no
    # adapter configured) lands in axn's exception bucket — reported once via on_exception,
    # returned as a formatted result — and a handler business `fail!` stays a quiet failure.
    class Dispatch
      include Axn

      expects :request, type: Axn::Webhooks::Request
      expects :router
      expects :parse
      expects :mode, default: :auto
      expects :respond_declared, type: :boolean, default: false
      exposes :handler_result, allow_nil: true
      error "Webhook dispatch failed"

      def call
        event = parse.call(request)
        resolution = router.resolve(event)
        return done!("acknowledged") if resolution == :ack

        handler_class, args = resolution
        return dispatch_async(handler_class, args) if async?(handler_class)

        expose handler_result: handler_class.call!(**args)
      end

      private

      # Resolve sync vs async (Decision D): explicit mode wins; a custom respond forces sync;
      # otherwise async when an adapter is configured for THIS handler, else sync.
      def async?(handler_class)
        return true if mode == :async
        return false if mode == :sync
        return false if respond_declared # mode == :auto, result-returning hook

        async_adapter_configured?(handler_class)
      end

      # Presence check ONLY — decides async-vs-sync, never asks which adapter.
      def async_adapter_configured?(handler_class)
        return true if Axn.config._default_async_adapter
        handler_class.respond_to?(:_async_adapter) && !handler_class._async_adapter.nil?
      end

      # Delegates entirely to axn's own async interface; no handler_result (nothing ran
      # synchronously). A call_async with no adapter raises NotImplementedError → loud exception.
      def dispatch_async(handler_class, args)
        handler_class.call_async(**args)
        done!("enqueued")
      end
    end
  end
end
