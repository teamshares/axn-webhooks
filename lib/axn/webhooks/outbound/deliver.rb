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

        # The headers Deliver adds AFTER the signer's, and therefore the ones a signer must not
        # emit: Ruby Hash keys are case-sensitive so a differently-cased duplicate survives the
        # merge below, but Net::HTTP is case-INSENSITIVE and the later assignment wins — silently
        # replacing the signature. Signer::HmacSigner rejects these at declaration time.
        MANAGED_HEADERS = %w[content-type user-agent].freeze

        expects :url, type: String
        expects :webhook_id, type: String
        expects :body, type: String
        expects :event, type: String
        expects :attempt, type: Integer, default: 1
        # A DB-backed subscriber's own identity (its String id, not a secret/token) -- nil for
        # today's declared-Array `to:` (no row to identify). Threaded through so a per-attempt
        # secret/header resolver and the exhaustion report can name which subscription this was.
        expects :subscriber_id, type: String, allow_blank: true, default: nil

        # Bounded to the events a sending app declares — same shape as inbound's unconditional
        # `reason` dimension, not a per-request identity.
        dimension :event, -> { event }
        # UNBOUNDED (a subscriber id off a DB table, unlike `event`) -- axn's `dimension` is the
        # metrics facet and must stay bounded; `tag` is the high-cardinality log/trace facet with no
        # metrics-billing cost (see Axn.config.logger.debug config comment near vendor_facet, and
        # `Axn::Webhooks::VendorFacet`'s own dimension/tag split). Getting this backwards would
        # quietly blow up a metrics backend's cardinality limits the first time a real subscriber
        # table is wired up.
        tag :subscriber_id, -> { subscriber_id }

        # Only reports when `@exhaustion_error` was set by `retry_or_exhaust!`'s exhaustion branch
        # (see `report_exhaustion_if_needed`) -- a permanent-4xx `fail!` (in `#call`) also fires
        # `on_failure` (axn dispatches it for ANY `fail!`), but must NOT page: it never sets that
        # ivar, so the guard holds. Registering here (rather than reporting inline before `fail!`)
        # means the report runs once axn has already finalized `action.result` as a failure (see
        # `with_exception_handling` in axn's executor.rb: `@context.__record_exception` runs before
        # the `:failure` callback dispatch) -- so a reporter reading `action.result` observes the
        # settled failure it exists to describe (Codex P2 finding).
        on_failure :report_exhaustion_if_needed

        def call
          # Scoped deliberately to ONLY `post` (not the whole method): a network error talking to
          # the receiver is a retryable delivery failure, but if `retry_or_exhaust!`'s own
          # `call_async` raises while ENQUEUING the follow-up job (e.g. a Redis/Sidekiq outage),
          # that must propagate as a loud exception — not get caught here and misinterpreted as
          # another delivery network error, which would re-run retry_or_exhaust! a second time in
          # the same attempt (a duplicate enqueue). Letting it propagate means the current job goes
          # un-acked and the async adapter's own retry path handles the outage (at-least-once).
          response = nil
          begin
            response = post
          rescue *Transport::RETRYABLE_NETWORK_ERRORS => e
            return retry_or_exhaust!(network_error: e)
          end

          return if success?(response.status) # 2xx -> done
          return retry_or_exhaust!(retry_after: header_value(response.headers, "retry-after")) if retryable?(response.status)

          fail!(permanent_failure_message(response))
        end

        private

        def config = Axn::Webhooks::Outbound.config

        def post
          config.transport.post(**post_args)
        end

        # Timeouts are only forwarded to the built-in Transport — a custom injected transport
        # (e.g. Faraday-backed) owns its own timeout configuration, and the documented seam is
        # `.post(url:, body:, headers:)`; passing it kwargs it never declared would raise.
        def post_args
          args = { url:, body:, headers: signed_headers }
          args.merge!(open_timeout: config.open_timeout, read_timeout: config.read_timeout) if config.transport == Transport
          args
        end

        # Sign per attempt with a FRESH timestamp (so the receiver's replay window accepts a retry),
        # reusing the stable webhook_id for idempotent dedup. Merge order is deliberate: custom
        # (PRO-3214's per-destination `headers`) -> signer -> Deliver-managed, so the signer and
        # Deliver always win a same-position `.merge`. That alone isn't the whole defense (Net::HTTP
        # is case-insensitive, Hash keys are not, so a DIFFERENTLY-cased duplicate survives the merge
        # and Net::HTTP still picks the later one) -- `custom_headers` below additionally drops any
        # subscriber-supplied name that collides, case-insensitively, with either bucket.
        def signed_headers
          subscriber = Subscriber.new(url:, id: subscriber_id)
          signer_headers = config.signer.call(id: webhook_id, timestamp: Time.now.to_i, body:, subscriber:)

          custom_headers(subscriber, signer_headers)
            .merge(signer_headers)
            .merge("content-type" => "application/json", "user-agent" => user_agent) # MANAGED_HEADERS
        end

        # Per-destination extra headers (PRO-3214) -- a malformed or colliding entry is DROPPED with
        # a warning, not raised: a bad row from a `headers` resolver shouldn't crash an otherwise-
        # deliverable attempt (a `headers` callable that itself raises is a different matter and
        # propagates unchanged -- see `resolve_custom_headers`).
        def custom_headers(subscriber, signer_headers)
          raw = resolve_custom_headers(subscriber)
          return {} if raw.nil?

          reserved = MANAGED_HEADERS + signer_headers.keys
          raw.each_with_object({}) { |(key, value), out| add_custom_header(out, key, value, reserved) }
        end

        def resolve_custom_headers(subscriber)
          callable = config.headers
          return nil if callable.nil?

          CallableArity.accepts?(callable, 1) ? callable.call(subscriber) : callable.call
        end

        # Net::HTTP requires String keys/values; a non-String pair would otherwise raise mid-flight,
        # a boot-clean declaration turned into a per-attempt crash. A key colliding, CASE-
        # INSENSITIVELY, with a Deliver-managed header or one the signer just emitted this attempt is
        # dropped for the reason `signed_headers`' comment gives: Hash keys don't collide there, but
        # Net::HTTP's header line does, silently, and it is always the LATER assignment that survives
        # -- which a subscriber-controlled row must never be allowed to be for webhook-signature.
        def add_custom_header(out, key, value, reserved)
          unless key.is_a?(String) && value.is_a?(String)
            Axn.config.logger.warn("[axn-webhooks] dropping custom header with a non-String key or value: #{key.inspect} => #{value.inspect}")
            return
          end

          if reserved.any? { |r| r.casecmp?(key) }
            Axn.config.logger.warn(
              "[axn-webhooks] dropping custom header #{key.inspect} -- collides with a header Deliver or the active signer already sets",
            )
            return
          end

          out[key] = value
        end

        def user_agent
          suffix = resolve_user_agent_suffix
          return "axn-webhooks/#{Axn::Webhooks::VERSION}" if suffix.nil?

          "axn-webhooks/#{Axn::Webhooks::VERSION} (#{suffix})"
        end

        def resolve_user_agent_suffix
          configured = config.user_agent
          return nil if configured.nil?

          configured.respond_to?(:call) ? configured.call : configured
        end

        def success?(status) = (200..299).cover?(status)

        # 5xx, plus the "come back later" 4xx codes.
        def retryable?(status) = status >= 500 || [408, 425, 429].include?(status)

        # The receiver-supplied body is the one piece of detail a permanent 4xx can offer beyond
        # its status code — truncated so a verbose error page never blows up a log line or an
        # exception report.
        def permanent_failure_message(response)
          "permanent delivery failure (HTTP #{response.status}) for #{event} to #{url}#{truncated_body(response.body)}"
        end

        # net/http labels every response body ASCII-8BIT regardless of actual content, so `body` may
        # hold arbitrary bytes (invalid UTF-8, or valid multibyte UTF-8 mislabeled as binary). Slice
        # BYTES first (encoding-agnostic, so the cut itself never raises), then force UTF-8 and
        # `scrub` — which also repairs a multibyte character split at the 500-byte boundary — before
        # appending the UTF-8 ellipsis, so the two `+` operands are always compatible.
        def truncated_body(body)
          return "" if body.nil? || body.empty?

          bytes = body.b
          truncated = bytes.bytesize > 500
          snippet = bytes.byteslice(0, 500).force_encoding(Encoding::UTF_8).scrub("�")
          snippet += "…" if truncated
          ": #{snippet}"
        end

        # Only reschedule when BOTH attempts remain AND an async adapter is actually configured for
        # Deliver to reschedule itself onto — otherwise `call_async` would raise a ScriptError
        # (NotImplementedError) that escapes axn's StandardError-only exception boundary entirely,
        # crashing the caller (e.g. Emit's synchronous best-effort fallback fan-out loop). No
        # adapter configured is therefore treated the same as an exhausted retry budget: report
        # once, fail! quietly (no crash, no cross-process retries — matches the documented
        # best-effort promise of the sync fallback path).
        def retry_or_exhaust!(retry_after: nil, network_error: nil)
          if attempt >= config.max_attempts || !async_configured?
            @exhaustion_error = network_error || Axn::Webhooks::Error.new("outbound delivery exhausted for #{event} to #{url}")
            return fail!(terminal_message)
          end

          delay = [config.backoff.call(attempt), parse_retry_after(retry_after)].compact.max
          self.class.call_async(url:, webhook_id:, body:, event:, vendor:, subscriber_id:, attempt: attempt + 1,
                                _async: { wait: delay })
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

          Axn.config.default_async?
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

        # Gated `on_failure` handler (registered above, at class-body level): fires on EVERY
        # `fail!` (including the permanent-4xx branch in `#call`), but only reports when
        # `retry_or_exhaust!`'s exhaustion branch actually set `@exhaustion_error` — a permanent-4xx
        # `fail!` never sets it, so this is a no-op there.
        def report_exhaustion_if_needed
          return unless @exhaustion_error

          report_exhaustion(@exhaustion_error)
        end

        # Report ONCE at exhaustion via axn's configured reporter (Honeybadger at Teamshares),
        # WITHOUT raising — raising would trigger the adapter to retry the already-exhausted job.
        # `action:` must be the running INSTANCE (`self`), not the class — axn's own internal
        # callers always pass the instance (see executor.rb), and `on_exception` relies on
        # instance-only state (e.g. `action.result`) to enrich the report; the configured reporter
        # itself may also expect a real action instance. `report_exhaustion` is itself an instance
        # method, so `self` here already IS that instance. Called from `report_exhaustion_if_needed`
        # (an `on_failure` callback), which runs AFTER axn has finalized `action.result` as a
        # failure — see the `on_failure` doc comment above `retry_or_exhaust!` for why that ordering
        # matters.
        def report_exhaustion(error)
          # The reporter itself may throw; guard it best-effort (logs+swallows in prod/test, re-raises
          # in dev only when Axn.config.best_effort_raises_in_dev) so a broken reporter never turns
          # exhaustion into a raise the async adapter would retry. `action: self` routes the warn to
          # the running instance, matching axn's own internal best_effort callers.
          Axn::Extensions.best_effort("reporting outbound delivery exhaustion", action: self) do
            Axn.config.on_exception(error, action: self, context: { event:, url:, webhook_id:, attempt:, subscriber_id: })
          end
        end
      end
    end
  end
end
