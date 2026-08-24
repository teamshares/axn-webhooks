# frozen_string_literal: true

module Axn
  module Webhooks
    module Verifiers
      # Parametric HMAC strategy. Resolves each option against the request at verify time
      # and delegates to the constant-time Signature primitive.
      register(:hmac) do |secret:, signature:, signing_string: :raw_body, digest: :sha256,
                          encoding: :hex, prefix: nil, replay: nil|
        if replay
          # Compare stringified keys so a HashWithIndifferentAccess (string keys) isn't
          # misclassified as entirely unsupported.
          allowed = %w[timestamp within unit]
          unknown = replay.keys.reject { |key| allowed.include?(key.to_s) }
          raise ArgumentError, "unsupported replay: key(s): #{unknown.map(&:inspect).join(', ')}" if unknown.any?
        end

        # A literal secret is knowable now; a callable/Resolver is checked per request below.
        literal_secret = !(secret.respond_to?(:call) || secret.is_a?(Symbol))
        Verifiers.require_secret!("verify :hmac", secret, error: ArgumentError) if literal_secret

        lambda do |request|
          timestamp = replay && Resolvers.resolve(replay.fetch(:timestamp), request)
          # hmac_check (not hmac): Verify reads the returned Signature::Check to report WHY the
          # request was rejected, so a replay-window miss is separable from an HMAC mismatch.
          Signature.hmac_check(
            # Resolve THEN guard, on every request: a resolver can miss (an unset env var, an
            # absent header, a tenant lookup the ATTACKER names) long after boot, and "" is a legal
            # HMAC key rather than a failure.
            secret: Verifiers.require_secret!("verify :hmac", Resolvers.resolve(secret, request)),
            payload: Resolvers.resolve(signing_string, request),
            signature: Resolvers.resolve(signature, request),
            digest:,
            encoding:,
            prefix:,
            timestamp:,
            tolerance: replay&.fetch(:within),
            # Default only when `unit:` is absent — an explicit `unit: nil`/`false` (e.g. an
            # unset env var) must still hit Signature's ArgumentError, not silently become :auto.
            unit: replay&.key?(:unit) ? replay[:unit] : Signature::AUTO,
          )
        end
      end
    end
  end
end
