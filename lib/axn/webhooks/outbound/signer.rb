# frozen_string_literal: true

module Axn
  module Webhooks
    module Outbound
      # Builds a signer callable (#call(id:, timestamp:, body:) -> header Hash) from a `sign`
      # declaration. The :standard_webhooks strategy is the outbound face of the inbound
      # verify :standard_webhooks — same scheme, so a receiver using that verifier accepts it.
      module Signer
        module_function

        def build(strategy:, opts:, block:)
          return CustomSigner.new(block) if block

          case strategy&.to_sym
          when :standard_webhooks then StandardWebhooksSigner.new(**opts)
          # A pure declaration mistake (decided once at boot, never at runtime) — ArgumentError, not
          # Axn::Webhooks::Error, matching Config's own misconfiguration-vs-runtime split.
          else raise ArgumentError, "unknown sign strategy #{strategy.inspect}"
          end
        end

        # Wraps a user block; called with the same kwargs as the built-in signers.
        class CustomSigner
          def initialize(block) = @block = block
          def call(id:, timestamp:, body:) = @block.call(id:, timestamp:, body:)
        end

        # Standard Webhooks: secret is `whsec_<base64>`; sign `id.timestamp.body` (sha256/base64);
        # emit `v1,<sig>` alongside the id/timestamp headers the inbound verifier reads.
        class StandardWebhooksSigner
          def initialize(secret:)
            # A pure declaration mistake, decided once at boot from the callable's own shape (not
            # from what it resolves to) — ArgumentError, matching Config's misconfiguration split.
            # `resolve_secret` below calls `@secret.call` with NO arguments; a callable requiring one
            # would otherwise boot successfully and raise ArgumentError on every real signing attempt
            # (Codex P2 finding).
            if secret.respond_to?(:call) && !CallableArity.accepts?(secret, 0)
              raise ArgumentError, "sign :standard_webhooks secret callable must accept zero arguments (resolved with no args per signing attempt)"
            end

            @secret = secret
          end

          def call(id:, timestamp:, body:)
            sig = Signature.compute(
              secret: decoded_secret,
              payload: "#{id}.#{timestamp}.#{body}",
              digest: :sha256,
              encoding: :base64,
            )
            {
              "webhook-id" => id.to_s,
              "webhook-timestamp" => timestamp.to_s,
              "webhook-signature" => "v1,#{sig}",
            }
          end

          private

          # A callable secret (the norm for every other webhook secret in this gem — see
          # Resolvers.resolve) resolves per call rather than being frozen at `sign` time; a plain
          # value is used as-is. Arity-free: unlike a subscriber resolver, a signing secret has no
          # natural argument to pass.
          def resolve_secret
            @secret.respond_to?(:call) ? @secret.call : @secret
          end

          def decoded_secret
            secret = resolve_secret
            raise invalid_secret_error(secret) unless secret.is_a?(String) && secret.start_with?("whsec_")

            decoded = Verifiers::StandardWebhooks.decode_secret(secret)
            raise invalid_secret_error(secret) if decoded.empty?

            decoded
          rescue ArgumentError
            raise invalid_secret_error(secret)
          end

          # A blank secret, or one missing the `whsec_` prefix, would otherwise decode "successfully"
          # (an empty or unprefixed value is still valid base64) and sign every delivery with an empty
          # or wrong key — silently, since the receiver's 401 is indistinguishable from any other
          # misconfiguration (Codex P1 finding).
          def invalid_secret_error(secret)
            Axn::Webhooks::Error.new("sign :standard_webhooks secret must be a whsec_<base64> value (got #{describe_secret(secret)})")
          end

          # Never interpolates the secret's actual bytes into the message: this error can be raised
          # on every delivery attempt (a callable secret is re-resolved per call, and may transiently
          # resolve to something malformed), and would otherwise flow the live signing credential
          # straight into whatever logs/exception reporter Axn.config.on_exception is wired to
          # (Codex P1 finding).
          def describe_secret(secret)
            return secret.class.name unless secret.is_a?(String)
            return "a #{secret.length}-char String not prefixed with whsec_" unless secret.start_with?("whsec_")

            "a whsec_-prefixed String that failed to decode"
          end
        end
      end
    end
  end
end
