# frozen_string_literal: true

require "openssl"
require "base64"

module Axn
  module Webhooks
    # The shared HMAC primitive. Pure functions over bytes — no Request, no Rack, no axn.
    # Both inbound `verify` and (future) outbound `sign` build on this. ALWAYS constant-time.
    module Signature
      DIGESTS = { sha256: "SHA256", sha1: "SHA1", md5: "MD5" }.freeze

      module_function

      # Verify a candidate signature header against the HMAC of `payload`.
      # `signature` may hold several whitespace/comma-separated candidates (key rotation);
      # returns true if ANY matches. Never raises on hostile input.
      def hmac(secret:, payload:, signature:, digest: :sha256, encoding: :hex, prefix: nil)
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
    end
  end
end
