# frozen_string_literal: true

module Axn
  module Webhooks
    # Builds a verifier callable (->(request){ Boolean }) from a `verify` declaration.
    # A custom block is used verbatim; a strategy symbol is looked up in STRATEGIES
    # (populated by verifiers/*.rb).
    module Verifiers
      STRATEGIES = {} # rubocop:disable Style/MutableConstant

      module_function

      def register(name, &builder) = STRATEGIES[name.to_sym] = builder

      # THE shared secret guard. Every strategy in this gem routes its secret/credential through
      # here, in both directions, so a new strategy cannot quietly reintroduce the bug this exists
      # for — which has now recurred four times, each fix having been applied only where it was
      # noticed (literal whsec_, resolved whsec_, `verify :hmac`, `verify :basic_auth`).
      #
      # The bug: a blank or absent secret is not a failure, it is a WEAK KEY. `""` is a perfectly
      # legal HMAC key, so an empty secret makes the expected signature a value any stranger can
      # compute — an authentication bypass, not a mismatch. `nil` happens to fail closed only by
      # accident (OpenSSL raises TypeError on it), which is precisely why checking nil alone gives
      # false confidence.
      #
      # Raises rather than returning false: a 401 meaning "we are misconfigured" is indistinguishable
      # from one meaning "you are not the vendor", and would otherwise present as an unexplained
      # outage. Names the value's TYPE or emptiness only — never its bytes, since this can fire on
      # every request and would otherwise flow the live credential into logs and error trackers.
      # `error:` follows this gem's misconfiguration split: ArgumentError for a DECLARATION mistake
      # caught at boot, Axn::Webhooks::Error for a value that only goes bad at request time.
      def require_secret!(declaration, value, label: "secret", error: Axn::Webhooks::Error)
        return value if value.is_a?(String) && !value.empty?

        raise error,
              "#{declaration} #{label} must be a non-empty String " \
              "(got #{value.is_a?(String) ? 'an empty String' : value.class})"
      end

      def build(strategy:, opts:, block:)
        return block if block

        builder = STRATEGIES.fetch(strategy&.to_sym) do
          raise Axn::Webhooks::Error, "unknown verify strategy #{strategy.inspect}"
        end
        builder.call(**opts)
      end
    end
  end
end
