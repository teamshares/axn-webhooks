# frozen_string_literal: true

module Axn
  module Webhooks
    module Verifiers
      # Parametric HMAC strategy. Resolves each option against the request at verify time
      # and delegates to the constant-time Signature primitive.
      register(:hmac) do |secret:, signature:, signing_string: :raw_body, digest: :sha256,
                          encoding: :hex, prefix: nil, replay: nil|
        lambda do |request|
          timestamp = replay && Resolvers.resolve(replay.fetch(:timestamp), request)
          Signature.hmac(
            secret: Resolvers.resolve(secret, request),
            payload: Resolvers.resolve(signing_string, request),
            signature: Resolvers.resolve(signature, request),
            digest:,
            encoding:,
            prefix:,
            timestamp:,
            tolerance: replay&.fetch(:within),
          )
        end
      end
    end
  end
end
