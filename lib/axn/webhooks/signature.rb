# frozen_string_literal: true

require "openssl"
require "base64"

module Axn
  module Webhooks
    # The shared HMAC primitive. Pure functions over bytes — no Request, no Rack, no axn.
    # Both inbound `verify` and outbound `sign` build on this. ALWAYS constant-time.
    module Signature
      DIGESTS = { sha256: "SHA256", sha1: "SHA1", md5: "MD5" }.freeze
      UNITS = { seconds: 1, ms: 1_000, milliseconds: 1_000, microseconds: 1_000_000 }.freeze

      # Infer the unit from the timestamp's magnitude, per-timestamp. The default, because a vendor
      # can send more than one unit -- Lob delivers epoch-seconds via Svix and epoch-ms from its
      # dashboard, and no static unit: is correct for both (PRO-3142).
      AUTO = :auto

      # The bands :auto reads magnitude against. The three scales sit 1000x apart and their
      # plausible-date ranges don't overlap, so every timestamp a vendor could legitimately send
      # falls in exactly one band:
      #
      #   value >= 1e11 can't be seconds -- that's the year 5138; as ms it's 1973.
      #   value >= 1e14 can't be ms      -- that's the year 5138; as microseconds it's 1973.
      #
      # A misread is therefore impossible in the 1973..5138 range, and outside it a misread can only
      # produce a ~56-year skew, which the tolerance window rejects. Inference never widens what is
      # accepted: no wrong-scale reading of a stale timestamp lands inside a tolerance of any
      # realistic size.
      AUTO_MS_FLOOR = 100_000_000_000
      AUTO_US_FLOOR = 100_000_000_000_000

      # The distinct scales, for diagnostics. Excludes the :milliseconds alias (same divisor as :ms)
      # so a mismatch is never reported as the caller's own unit under a different name.
      CANONICAL_UNITS = %i[seconds ms microseconds].freeze

      # The outcome of a signature check, with the CAUSE of a rejection named. Deliberately not
      # called Result — `Axn::Result` already owns that word in this codebase's vocabulary.
      #
      # `reason` is one of REASONS (nil when ok). `skew` is set only for :replay_window, in seconds,
      # signed (positive = the timestamp is in the past). `suggested_unit` is set only when a
      # *pinned* `unit:` is what pushed the timestamp out of the window (see .mismatched_unit,
      # PRO-3142) — nil for a genuine replay, which is what separates the Lob outage (os-app#5128)
      # from a real stale delivery. Under the default `unit: AUTO` it is nil essentially always.
      Check = Data.define(:ok, :reason, :skew, :suggested_unit) do
        def ok? = ok
      end

      # The last two belong to `verify :basic_auth`, which rejects for reasons that have nothing to
      # do with a signature. Keeping them out would stamp every Basic-auth rejection
      # `:signature_mismatch` — the exact misdirection PRO-3141 added `reason` to end, on endpoints
      # where no signature exists.
      REASONS = %i[
        replay_window replay_timestamp_invalid signature_missing signature_mismatch
        credentials_missing credentials_mismatch
      ].freeze

      OK = Check.new(ok: true, reason: nil, skew: nil, suggested_unit: nil).freeze

      # The verdict a bare falsey return from a custom `verify` block is read as — it rejected the
      # signature without saying more, which is exactly :signature_mismatch.
      MISMATCH = Check.new(ok: false, reason: :signature_mismatch, skew: nil, suggested_unit: nil).freeze

      # "The request carried no signature at all", for a custom `verify` block to return in place of
      # MISMATCH. Exported because that distinction is only available to a verifier that reads the
      # header itself: a bare falsey return collapses to :signature_mismatch, which on a guessable
      # public path buries the alertable case (a rotated secret, or a URL we rebuild wrong) under
      # ordinary unsigned scanner traffic. `:hmac` reports it via hmac_check below.
      SIGNATURE_MISSING = Check.new(ok: false, reason: :signature_missing, skew: nil, suggested_unit: nil).freeze

      # `verify :basic_auth`'s two verdicts. CREDENTIALS_MISSING covers both "no Authorization at
      # all" and "an Authorization that isn't Basic", but only the second reaches Verify over HTTP:
      # the first is the bare handshake leg, which Endpoint answers with the challenge before
      # verifying (PRO-3148, and see BasicAuth#challenge_required?).
      CREDENTIALS_MISSING = Check.new(ok: false, reason: :credentials_missing, skew: nil, suggested_unit: nil).freeze
      CREDENTIALS_MISMATCH = Check.new(ok: false, reason: :credentials_mismatch, skew: nil, suggested_unit: nil).freeze

      module_function

      # Verify a candidate signature header against the HMAC of `payload`.
      # `signature` may hold several whitespace/comma-separated candidates (key rotation);
      # returns true if ANY matches. Never raises on hostile input.
      # rubocop:disable Naming/PredicateMethod -- it IS a predicate, but `hmac` is the documented
      # public entry point (README, every direct caller); renaming it to `hmac?` is a breaking change.
      def hmac(secret:, payload:, signature:, digest: :sha256, encoding: :hex, prefix: nil,
               timestamp: nil, tolerance: nil, now: nil, unit: AUTO)
        hmac_check(secret:, payload:, signature:, digest:, encoding:, prefix:, timestamp:, tolerance:, now:, unit:).ok?
      end
      # rubocop:enable Naming/PredicateMethod

      # Same check as `hmac`, but returns a Check naming WHY a rejection happened rather than a
      # bare false. `hmac` is this method's `.ok?`, so the replay window lives in exactly one
      # place and every caller (both built-in verifiers, and `Signature.hmac` itself) agrees.
      def hmac_check(secret:, payload:, signature:, digest: :sha256, encoding: :hex, prefix: nil,
                     timestamp: nil, tolerance: nil, now: nil, unit: AUTO)
        # Validate unit: unconditionally — a misconfigured unit: is a config error independent of
        # whether replay protection is active or the request happens to carry a signature.
        validate_unit!(unit)

        if tolerance
          now ||= Time.now
          drift = skew(timestamp:, now:, unit:)
          return rejected(:replay_timestamp_invalid) if drift.nil?

          if drift.abs > tolerance.to_i
            # Only asked on the rejection path — it re-runs the window against each other scale.
            return rejected(:replay_window, skew: drift,
                                            suggested_unit: mismatched_unit(timestamp:, tolerance:, now:, unit:))
          end
        end

        return SIGNATURE_MISSING if signature.nil? || signature.to_s.empty?

        expected = compute(secret:, payload:, digest:, encoding:)
        return OK if candidates(signature, prefix:).any? { |candidate| secure_compare(candidate, expected) }

        rejected(:signature_mismatch)
      end

      # The encoded expected signature for `payload`. Reused by outbound's Signer::StandardWebhooksSigner.
      def compute(secret:, payload:, digest: :sha256, encoding: :hex)
        raw = OpenSSL::HMAC.digest(openssl_digest(digest), secret, payload.to_s)
        encode(raw, encoding)
      end

      # Constant-time comparison. False (never raises) on nil or length mismatch.
      def secure_compare(candidate, expected)
        return false if candidate.nil? || expected.nil?
        return false unless candidate.bytesize == expected.bytesize

        OpenSSL.fixed_length_secure_compare(candidate, expected)
      end

      # True when `timestamp` is present, parseable, and within ±tolerance seconds of `now`.
      def within_tolerance?(timestamp:, tolerance:, now: nil, unit: AUTO)
        drift = skew(timestamp:, now:, unit:)
        !drift.nil? && drift.abs <= tolerance.to_i
      end

      # Seconds between `now` and `timestamp`, signed (positive = `timestamp` is in the past).
      # nil when the timestamp is absent or unparseable — a distinct condition from "far away",
      # which is why the two get separate rejection reasons. Goes through coerce_epoch, so `unit:`
      # (including AUTO's per-timestamp inference) applies here exactly as it does to the window.
      def skew(timestamp:, now: nil, unit: AUTO)
        epoch = coerce_epoch(timestamp, unit)
        return nil if epoch.nil?

        (now || Time.now).to_i - epoch
      end

      # Diagnostic: the unit that WOULD have put `timestamp` inside the window, when `unit` didn't.
      # nil when `unit` already fits, when the timestamp is missing/unparseable, or when no scale
      # rescues it -- i.e. nil for a genuine replay, a symbol for a misconfigured `unit:`. Pure;
      # logging and failure-reason classification belong to the caller.
      def mismatched_unit(timestamp:, tolerance:, now: nil, unit: AUTO)
        validate_unit!(unit)
        return nil if within_tolerance?(timestamp:, tolerance:, now:, unit:)

        CANONICAL_UNITS.find do |candidate|
          candidate != unit && within_tolerance?(timestamp:, tolerance:, now:, unit: candidate)
        end
      end

      def rejected(reason, skew: nil, suggested_unit: nil) = Check.new(ok: false, reason:, skew:, suggested_unit:)
      private_class_method :rejected

      def openssl_digest(digest)
        DIGESTS.fetch(digest) { raise ArgumentError, "unsupported digest: #{digest.inspect}" }
      end
      private_class_method :openssl_digest

      def encode(raw, encoding)
        case encoding
        when :hex            then raw.unpack1("H*")
        when :base64         then Base64.strict_encode64(raw)
        when :base64_urlsafe then Base64.urlsafe_encode64(raw)
        else raise ArgumentError, "unsupported encoding: #{encoding.inspect}"
        end
      end
      private_class_method :encode

      # Splits a signature header on whitespace and commas. Phase 2's :standard_webhooks preset
      # sends v1,<sig> version-tagged candidates; callers must deliberately strip the v1, tag
      # before this splitter to avoid splitting v1,<sig> into two tokens.
      def candidates(signature, prefix:)
        signature.to_s.split(/[\s,]+/).reject(&:empty?).map do |token|
          if prefix
            token.start_with?(prefix) ? token.delete_prefix(prefix) : nil
          else
            token
          end
        end.compact
      end
      private_class_method :candidates

      def coerce_epoch(timestamp, unit)
        validate_unit!(unit)

        case timestamp
        when Time    then timestamp.to_i
        when Integer then timestamp / divisor_for(timestamp, unit)
        when String  then (coerce_epoch(Integer(timestamp, 10), unit) if timestamp.match?(/\A-?\d+\z/))
        end
      end
      private_class_method :coerce_epoch

      # A fixed unit's divisor is a constant; :auto's depends on the value being converted, so this
      # takes the value rather than resolving off the unit alone.
      def divisor_for(value, unit)
        return UNITS.fetch(unit) unless unit == AUTO

        case value.abs
        when 0...AUTO_MS_FLOOR then 1
        when AUTO_MS_FLOOR...AUTO_US_FLOOR then 1_000
        else 1_000_000
        end
      end
      private_class_method :divisor_for

      # Raises on an unrecognized unit. Called eagerly by `hmac` (independent of whether replay
      # protection is active or the request carries a signature), so a misconfigured `unit:` is a
      # loud config error rather than a silent 401.
      def validate_unit!(unit)
        return if unit == AUTO || UNITS.key?(unit)

        raise ArgumentError, "unsupported unit: #{unit.inspect}"
      end
      private_class_method :validate_unit!
    end
  end
end
