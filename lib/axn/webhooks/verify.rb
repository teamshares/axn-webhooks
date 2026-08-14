# frozen_string_literal: true

module Axn
  module Webhooks
    # The verify stage, as an Axn. A signature mismatch is a quiet failure (`fail!` →
    # 401 later, no on_exception page); a verifier that raises is a loud exception
    # (reported to Axn.config.on_exception). The first two rows of the staged-outcome model.
    class Verify
      include Axn
      include Axn::Webhooks::VendorFacet

      # Why the request was rejected, keyed by Signature::REASONS. The HTTP response is a bare
      # 401 in every case — this exists so the two causes are separable in logs and metrics
      # (PRO-3141: a replay-window miss and an HMAC mismatch were byte-identical in the logs,
      # and the replay case reported "signature mismatch" for a request whose signature was valid).
      MESSAGES = {
        replay_window: ->(check) { "replay window exceeded (timestamp skew #{check.skew}s)" },
        replay_timestamp_invalid: ->(_check) { "replay timestamp missing or unparseable" },
        signature_missing: ->(_check) { "signature missing" },
        signature_mismatch: ->(_check) { "signature mismatch" },
        # Not an anomaly: a client that doesn't authenticate preemptively is *supposed* to arrive
        # bare and wait to be challenged, so this fires once per successful Basic-auth webhook.
        # Worded so a dashboard full of them doesn't read as an outage — which is exactly what the
        # same traffic looked like, mislabelled, when it took buyout's Twilio endpoints down for
        # 27h (PRO-3146).
        credentials_missing: ->(_check) { "no Basic credentials offered (expected: client awaits the 401 challenge)" },
        credentials_mismatch: ->(_check) { "Basic credentials rejected" },
      }.freeze

      expects :request, type: Axn::Webhooks::Request, sensitive: true
      # A verifier closes over or holds the vendor's secret — that's its whole job — so it must
      # never be rendered into the per-call log line. The built-in strategies redact themselves
      # too (see Verifiers::BasicAuth#inspect), but this is the boundary that has to hold: a
      # custom `verify` block or a future strategy can't be relied on to have thought about it.
      expects :verifier, sensitive: true
      exposes :reason, allow_blank: true, default: nil
      exposes :skew, allow_blank: true, default: nil
      exposes :suggested_unit, allow_blank: true, default: nil
      error "Webhook signature verification failed"

      # A bounded enum (4 values), so unlike :vendor it's stamped unconditionally rather than
      # gated behind Axn::Webhooks.config.vendor_facet — separating the causes is the reason
      # this facet exists, and a default install needs it as much as a configured one.
      # `from: :result` because the reason isn't known until the body has run.
      dimension :reason, -> { @reason }, from: :result

      # Also bounded (3 scales + absent), and set only when a pinned `unit:` — not a real replay —
      # is what pushed the timestamp out of the window. Its presence alone splits the misconfigured
      # half of :replay_window from the genuine half; its value names the fix (PRO-3142).
      dimension :suggested_unit, -> { @suggested_unit }, from: :result

      def call
        check = verifier.call(request)
        return if verified?(check)

        # Set before fail! so the result-phase dimension resolvers can read them.
        rejection = check.is_a?(Signature::Check) ? check : Signature::MISMATCH
        @reason = rejection.reason
        @skew = rejection.skew
        @suggested_unit = rejection.suggested_unit
        fail!(message_for(rejection), reason: @reason, skew: @skew, suggested_unit: @suggested_unit)
      end

      private

      # The reason's own message, plus the suggested unit when one applies — "would fit as
      # unit: :ms" alongside a 56-year skew names a misconfiguration outright, where the skew
      # alone still reads as a possible replay. A timestamp is not a secret and the HTTP
      # response is a bare 401 either way, so this discloses nothing to the sender.
      def message_for(rejection)
        message = MESSAGES.fetch(rejection.reason).call(rejection)
        return message unless rejection.suggested_unit

        "#{message} — would fit as unit: #{rejection.suggested_unit.inspect}"
      end

      # A Check reports its own verdict; anything else (a custom verifier block, per the
      # documented `->(request) { Boolean }` contract) is read for truthiness. Checked in this
      # order because a rejecting Check is still a truthy Ruby object.
      def verified?(check) = check.is_a?(Signature::Check) ? check.ok? : !!check
    end
  end
end
