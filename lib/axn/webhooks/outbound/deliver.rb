# frozen_string_literal: true

require "time"

module Axn
  module Webhooks
    module Outbound
      # A single delivery attempt + the self-managed retry engine. Built as an Axn: metrics/OTel/
      # structured logs per attempt come free. Retryable responses reschedule via axn's
      # adapter-agnostic call_async(_async: { wait: }) seam (never branching on adapter type);
      # unexpected exceptions propagate so the async adapter retries the un-acked job (at-least-once).
      class Deliver
        include Axn
        include Axn::Webhooks::VendorFacet

        expects :url, type: String
        expects :webhook_id, type: String
        expects :body, type: String
        expects :event, type: String
        expects :attempt, type: Integer, default: 1

        def call
          response = post
          return if success?(response.status) # 2xx -> done
          return retry_or_exhaust!(retry_after: header_value(response.headers, "retry-after")) if retryable?(response.status)

          fail!("permanent delivery failure (HTTP #{response.status}) for #{event} to #{url}")
        rescue *Transport::RETRYABLE_NETWORK_ERRORS => e
          retry_or_exhaust!(network_error: e)
        end

        private

        def config = Axn::Webhooks::Outbound.config

        def post
          config.transport.post(url:, body:, headers: signed_headers)
        end

        # Sign per attempt with a FRESH timestamp (so the receiver's replay window accepts a retry),
        # reusing the stable webhook_id for idempotent dedup.
        def signed_headers
          config.signer.call(id: webhook_id, timestamp: Time.now.to_i, body:)
                .merge("content-type" => "application/json", "user-agent" => user_agent)
        end

        def user_agent = "axn-webhooks/#{Axn::Webhooks::VERSION}"

        def success?(status) = (200..299).cover?(status)

        # 5xx, plus the "come back later" 4xx codes.
        def retryable?(status) = status >= 500 || [429].include?(status)

        # Only reschedule when BOTH attempts remain AND an async adapter is actually configured for
        # Deliver to reschedule itself onto — otherwise `call_async` would raise a ScriptError
        # (NotImplementedError) that escapes axn's StandardError-only exception boundary entirely,
        # crashing the caller (e.g. Emit's synchronous best-effort fallback fan-out loop). No
        # adapter configured is therefore treated the same as an exhausted retry budget: report
        # once, fail! quietly (no crash, no cross-process retries — matches the documented
        # best-effort promise of the sync fallback path).
        def retry_or_exhaust!(retry_after: nil, network_error: nil)
          if attempt >= config.max_attempts || !async_configured?
            report_exhaustion(network_error)
            return fail!(terminal_message)
          end

          delay = [config.backoff.call(attempt), parse_retry_after(retry_after)].compact.max
          self.class.call_async(url:, webhook_id:, body:, event:, attempt: attempt + 1, _async: { wait: delay })
        end

        def terminal_message
          return "delivery exhausted after #{attempt} attempts for #{event} to #{url}" if attempt >= config.max_attempts

          "delivery failed for #{event} to #{url} (no async adapter configured to retry attempt #{attempt + 1})"
        end

        # Presence check ONLY (never branches on adapter type) — mirrors Dispatch's own
        # `async_adapter_configured?` exactly, but against `self.class` since Deliver reschedules
        # ITSELF. An explicit per-class setting (including `false`) always wins over the global
        # default.
        def async_configured?
          return !!self.class._async_adapter unless self.class._async_adapter.nil?

          !!Axn.config._default_async_adapter
        end

        # HTTP header names are case-insensitive, but `Transport` is a public injectable seam — a
        # custom transport (e.g. Faraday-backed) may return a plain Hash with "Retry-After" or
        # "RETRY-AFTER" rather than the lowercased keys net/http's `to_hash` produces. Look up by
        # name case-insensitively instead of assuming lowercase.
        def header_value(headers, name)
          headers.each { |k, v| return v if k.to_s.casecmp?(name) }
          nil
        end

        # Retry-After per RFC 7231: either delay-seconds (integer) or an HTTP-date. For the
        # HTTP-date form, compute the remaining seconds until that instant, clamped to >= 0 (a
        # past/now date means "no extra delay beyond backoff", not "retry immediately forever").
        def parse_retry_after(value)
          return nil if value.nil? || value.to_s.empty?

          return Integer(value, 10) if value.to_s.match?(/\A\d+\z/)

          begin
            [(Time.httpdate(value) - Time.now).to_i, 0].max
          rescue ArgumentError
            nil
          end
        end

        # Report ONCE at exhaustion via axn's configured reporter (Honeybadger at Teamshares),
        # WITHOUT raising — raising would trigger the adapter to retry the already-exhausted job.
        def report_exhaustion(network_error)
          error = network_error || Axn::Webhooks::Error.new("outbound delivery exhausted for #{event} to #{url}")
          Axn.config.on_exception(error, action: self.class, context: { event:, url:, webhook_id:, attempt: })
        rescue StandardError => e
          Axn::Webhooks.swallow_soft_error("reporting outbound delivery exhaustion", exception: e)
        end
      end
    end
  end
end
