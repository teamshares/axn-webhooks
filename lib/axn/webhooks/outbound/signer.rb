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
          else raise Axn::Webhooks::Error, "unknown sign strategy #{strategy.inspect}"
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
            Verifiers::StandardWebhooks.decode_secret(secret)
          rescue ArgumentError
            raise Axn::Webhooks::Error,
                  "sign :standard_webhooks secret must be a whsec_<base64> value (got #{secret.inspect})"
          end
        end
      end
    end
  end
end
