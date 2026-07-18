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

        def decode_secret(secret) = Base64.decode64(secret.to_s.delete_prefix("whsec_"))

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
        lambda do |request|
          ts = Resolvers.resolve(timestamp, request)
          payload = "#{Resolvers.resolve(id, request)}.#{ts}.#{request.raw_body}"
          candidates = StandardWebhooks.extract_v1(Resolvers.resolve(signature, request))

          Signature.hmac(
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
