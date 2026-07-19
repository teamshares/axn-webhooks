# frozen_string_literal: true

module Axn
  module Webhooks
    # Routes a verified request to its handler Axn. Built as an Axn so every loud failure
    # (missing handler, unmatched key, parse error, handler crash, or an async enqueue with no
    # adapter configured) lands in axn's exception bucket — reported once via on_exception,
    # returned as a formatted result — and a handler business `fail!` stays a quiet failure.
    class Dispatch
      include Axn
      include Axn::Webhooks::VendorFacet

      expects :request, type: Axn::Webhooks::Request
      expects :router
      expects :parse
      expects :mode, default: :auto
      expects :respond_declared, type: :boolean, default: false
      exposes :handler_result, allow_nil: true
      exposes :retry_after, allow_nil: true
      error "Webhook dispatch failed"

      def call
        event = parse.call(request)
        resolution = router.resolve(event)
        return done!("acknowledged") if resolution == :ack

        handler_class, args = resolution
        return dispatch_async(handler_class, args) if async?(handler_class)

        expose handler_result: nil
        begin
          expose handler_result: handler_class.call!(**args)
        rescue Axn::Webhooks::RetryLater => e
          expose retry_after: e.retry_after
        end
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
      # A handler's own explicit setting always wins over the global default — mirrors axn's own
      # call_async semantics, where _async_adapter only falls back to the global default when nil;
      # an explicit `false` (opted out) is sticky and never falls back. So an explicitly-disabled
      # handler (_async_adapter == false) is correctly treated as "not configured" even when a
      # truthy global default is set, not silently overridden by it.
      def async_adapter_configured?(handler_class)
        if handler_class.respond_to?(:_async_adapter) && !handler_class._async_adapter.nil?
          return !!handler_class._async_adapter # explicit per-handler setting (incl. `async false`) always wins
        end

        !!Axn.config._default_async_adapter
      end

      # Delegates entirely to axn's own async interface; no handler_result (nothing ran
      # synchronously). Guarded so an unconfigured OR explicitly-disabled handler never reaches
      # call_async, which would raise a ScriptError (NotImplementedError) that escapes the Dispatch
      # axn boundary entirely (the boundary only rescues StandardError). Raising our own StandardError
      # here instead keeps the failure inside the boundary as a clean, reported exception outcome.
      #
      # Only handlers that expose _async_adapter (real Axn handlers) are second-guessed here — that's
      # the only case where axn's own call_async can raise the escaping NotImplementedError. A handler
      # class that doesn't respond to _async_adapter isn't going through axn's async machinery at all
      # (e.g. a plain object providing its own call_async), so there's nothing to guard against.
      def dispatch_async(handler_class, args)
        if handler_class.respond_to?(:_async_adapter) && !async_adapter_configured?(handler_class)
          raise Axn::Webhooks::Error,
                "dispatch mode: :async requires an axn async adapter, but none is configured for " \
                "#{handler_class} (add `async :sidekiq`/`async :active_job` to the handler, or set a global default)"
        end

        handler_class.call_async(**args)
        done!("enqueued")
      end
    end
  end
end
