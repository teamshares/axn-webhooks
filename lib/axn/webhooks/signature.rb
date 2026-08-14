# frozen_string_literal: true

require "openssl"
require "base64"

module Axn
  module Webhooks
    # The shared HMAC primitive. Pure functions over bytes — no Request, no Rack, no axn.
    # Both inbound `verify` and (future) outbound `sign` build on this. ALWAYS constant-time.
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

      module_function

      # Verify a candidate signature header against the HMAC of `payload`.
      # `signature` may hold several whitespace/comma-separated candidates (key rotation);
      # returns true if ANY matches. Never raises on hostile input.
      def hmac(secret:, payload:, signature:, digest: :sha256, encoding: :hex, prefix: nil,
               timestamp: nil, tolerance: nil, now: nil, unit: AUTO)
        # Validate unit: unconditionally — a misconfigured unit: is a config error independent of
        # whether replay protection is active or the request happens to carry a signature.
        validate_unit!(unit)
        return false if tolerance && !within_tolerance?(timestamp:, tolerance:, now: now || Time.now, unit:)
        return false if signature.nil? || signature.to_s.empty?

        expected = compute(secret:, payload:, digest:, encoding:)
        candidates(signature, prefix:).any? { |candidate| secure_compare(candidate, expected) }
      end

      # The encoded expected signature for `payload`. Reused by future outbound signing.
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
        epoch = coerce_epoch(timestamp, unit)
        return false if epoch.nil?

        ((now || Time.now).to_i - epoch).abs <= tolerance.to_i
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
