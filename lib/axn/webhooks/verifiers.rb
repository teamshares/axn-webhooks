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

      # THE shared secret guard — axn core's `Axn::Extensions::Auth.require_secret!`, which owns the
      # reasoning (a blank secret is a WEAK KEY, not a failure; raise rather than 401; name the TYPE,
      # never the bytes). Every strategy in this gem still routes through here so a new one cannot
      # skip it. `error:` follows this gem's misconfiguration split: ArgumentError for a DECLARATION
      # mistake caught at boot, Axn::Webhooks::Error for a value that only goes bad at request time.
      def require_secret!(declaration, value, label: "secret", error: Axn::Webhooks::Error)
        Axn::Extensions::Auth.require_secret!(declaration, value, label:, error:)
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
