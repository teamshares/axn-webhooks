# frozen_string_literal: true

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
          return retry_or_exhaust!(retry_after: response.headers["retry-after"]) if retryable?(response.status)

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

        def retry_or_exhaust!(retry_after: nil, network_error: nil)
          if attempt >= config.max_attempts
            report_exhaustion(network_error)
            return fail!("delivery exhausted after #{attempt} attempts for #{event} to #{url}")
          end

          delay = [config.backoff.call(attempt), parse_retry_after(retry_after)].compact.max
          self.class.call_async(url:, webhook_id:, body:, event:, attempt: attempt + 1, _async: { wait: delay })
        end

        def parse_retry_after(value)
          return nil if value.nil? || value.to_s.empty?

          Integer(value, 10) if value.to_s.match?(/\A\d+\z/)
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
