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
