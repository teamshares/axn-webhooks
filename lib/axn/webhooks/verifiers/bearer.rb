# frozen_string_literal: true

require "delegate"

module Axn
  module Webhooks
    module Verifiers
      # `verify :bearer, keys: { "partner" => -> { ENV.fetch("PARTNER_TOKEN") } }` — a static API key,
      # for a sender that authenticates with a token rather than a signature. The strategy is axn core's
      # `Axn::Extensions::Auth::Bearer` (shared with axn-openapi): it resolves deferred keys per request,
      # compares every candidate in constant time, and answers a 401 with the `www-authenticate: Bearer`
      # challenge via its own `#unauthorized_headers`. Pass `header: "X-API-Key"` for a raw custom header.
      #
      # Keys are Strings or Procs (or Arrays of them) — core's shapes, not this gem's `header(…)` /
      # Symbol resolvers, which name a request value rather than a secret.
      class Bearer < SimpleDelegator
        # This gem's misconfiguration split: a blank literal key is a declaration mistake (core raises
        # its ArgumentError at construction, unchanged); a deferred key that resolves blank only goes bad
        # at request time, which this gem reports as Axn::Webhooks::Error.
        def call(request)
          __getobj__.call(request)
        rescue Axn::Extensions::Auth::ConfigurationError => e
          raise Axn::Webhooks::Error, e.message
        end

        def inspect = __getobj__.inspect
        def pretty_print(printer) = printer.text(inspect)
      end

      register(:bearer) do |keys:, header: Axn::Extensions::Auth::Bearer::AUTHORIZATION|
        Bearer.new(Axn::Extensions::Auth::Bearer.new(keys:, header:))
      end
    end
  end
end
