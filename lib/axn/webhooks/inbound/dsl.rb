# frozen_string_literal: true

module Axn
  module Webhooks
    module Inbound
      # Receiver for an `inbound` block: captures declarations (Phase 2: `verify`) and
      # exposes request resolvers. Later phases add dispatch/challenge/respond here.
      class DSL
        # verify :hmac, **opts | verify :standard_webhooks, **opts | verify { |req| ... }
        def verify(strategy = nil, **opts, &block)
          @verify_spec = { strategy:, opts:, block: }
        end

        def header(name) = Resolvers.header(name)
        def raw_body     = Resolvers.raw_body
        def params       = Resolvers.params
        def url          = Resolvers.url

        # Internal: build the verifier callable from the captured declaration.
        def __verifier__
          raise Axn::Webhooks::Error, "inbound endpoint declared no `verify`" unless @verify_spec
          raise Axn::Webhooks::Error, "inbound endpoint `verify` needs a strategy or a block" if @verify_spec[:strategy].nil? && @verify_spec[:block].nil?

          Verifiers.build(**@verify_spec)
        end
      end
    end
  end
end
