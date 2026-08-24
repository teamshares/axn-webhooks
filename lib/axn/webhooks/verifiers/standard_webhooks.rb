# frozen_string_literal: true

require "base64"

module Axn
  module Webhooks
    module Verifiers
      # Standard Webhooks (Svix) scheme. Secret is `whsec_<base64>`; the signed string is
      # `id.timestamp.body`; the signature header holds space-separated `v1,<base64sig>`
      # candidates; a ±tolerance replay window applies.
      module StandardWebhooks
        module_function

        def decode_secret(secret) = Base64.strict_decode64(secret.to_s.delete_prefix("whsec_"))

        # The raw HMAC key behind a `whsec_<base64>` secret, or nil if the value isn't one.
        # The single source of truth for "is this a usable Standard Webhooks secret", shared by
        # inbound's declaration-time check and outbound's (Outbound::Signer), so the two can't drift.
        #
        # The `whsec_` prefix check is what carries this: an unprefixed secret is very often still
        # VALID Base64 — a 32-char hex secret is, and that's a common shape — so it would decode
        # silently to the wrong key rather than raising. The rescue is scoped to the decode alone;
        # a caller that RESOLVES a secret (from a callable or a secret store) must do so outside
        # this method, or its own ArgumentError would be swallowed and rewritten.
        def secret_key(secret)
          return nil unless secret.is_a?(String) && secret.start_with?("whsec_")

          key = decode_secret(secret)
          key.empty? ? nil : key
        rescue ArgumentError
          nil
        end

        # Describes a rejected secret's SHAPE for an error message, never its bytes: this can be
        # raised per delivery attempt on the outbound side, and would otherwise flow the live
        # signing credential into whatever Axn.config.on_exception is wired to.
        def describe_secret(secret)
          return secret.class.name unless secret.is_a?(String)
          return "a #{secret.length}-char String not prefixed with whsec_" unless secret.start_with?("whsec_")

          "a whsec_-prefixed String that failed to decode"
        end

        def invalid_secret_message(declaration, secret)
          "#{declaration} secret must be a whsec_<base64> value (got #{describe_secret(secret)})"
        end

        # Keep only `v1,<sig>` candidates, stripped to the bare base64 signature.
        # Done here (not via Signature's generic splitter) because that splitter treats
        # the comma as a separator and would break `v1,<sig>` into two tokens.
        def extract_v1(header)
          header.to_s.split(/\s+/).select { |t| t.start_with?("v1,") }.map { |t| t.delete_prefix("v1,") }
        end
      end

      register(:standard_webhooks) do |secret:, tolerance: 300,
                                       id: Resolvers.header("webhook-id"),
                                       timestamp: Resolvers.header("webhook-timestamp"),
                                       signature: Resolvers.header("webhook-signature")|
        # A LITERAL secret is fully knowable now, so the whsec_ format is checked once here (this
        # block runs at `inbound` declaration) instead of failing every request forever. Symmetric
        # with outbound `sign :standard_webhooks`, and ArgumentError for the same reason: a
        # declaration mistake, not a runtime condition.
        #
        # Worth the eager check because BOTH request-time failure modes are near-undiagnosable: a
        # non-Base64 raw secret raises (reported as a verifier crash, no `reason` on the result),
        # and a raw secret that IS valid Base64 decodes silently to the wrong key — a quiet
        # :signature_mismatch, nothing reported anywhere, indistinguishable from a rotated key.
        #
        # Exempt CALLABLES (a lambda, or a Resolver like `header("X-Secret")`) — deliberately not
        # resolved here, since they may read a secret store or an env var set after boot, so their
        # value stays a per-request concern. Everything ELSE is validated now.
        #
        # Keyed on respond_to?(:call), NOT on is_a?(String) (Codex round-3 finding): a `nil` secret
        # — an unset ENV var being the obvious way to get one — is neither a String nor a callable,
        # so a String-keyed check waved it through to request time, where `decode_secret` coerced it
        # with #to_s and Base64-decoded "" into an EMPTY HMAC key. That is an authentication bypass,
        # not a mismatch: anyone who knows the secret is unset can compute a signature with the empty
        # key and be verified. Same fail-closed-on-blank stance verify :basic_auth already takes.
        unless secret.respond_to?(:call) || StandardWebhooks.secret_key(secret)
          raise ArgumentError, StandardWebhooks.invalid_secret_message("verify :standard_webhooks", secret)
        end

        lambda do |request|
          ts = Resolvers.resolve(timestamp, request)
          payload = "#{Resolvers.resolve(id, request)}.#{ts}.#{request.raw_body}"
          candidates = StandardWebhooks.extract_v1(Resolvers.resolve(signature, request))

          # hmac_check (not hmac): returns a Signature::Check so Verify can name the cause.
          Signature.hmac_check(
            secret: StandardWebhooks.decode_secret(Resolvers.resolve(secret, request)),
            payload:,
            signature: candidates.join(" "),
            digest: :sha256,
            encoding: :base64,
            timestamp: ts,
            tolerance:,
          )
        end
      end
    end
  end
end
