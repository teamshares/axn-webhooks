# frozen_string_literal: true

module Axn
  module Webhooks
    module Verifiers
      # `verify :bearer, keys: { "partner" => -> { ENV.fetch("PARTNER_TOKEN") } }` — a static API key,
      # for a sender that authenticates with a token rather than a signature. The strategy is axn core's
      # `Axn::Extensions::Auth::Bearer` (shared with axn-openapi): it resolves deferred keys per request,
      # compares every candidate in constant time, and answers a 401 with the `www-authenticate: Bearer`
      # challenge via its own `#unauthorized_headers`. Pass `header: "X-API-Key"` for a raw custom header.
      register(:bearer) do |keys:, header: Axn::Extensions::Auth::Bearer::AUTHORIZATION|
        Axn::Extensions::Auth::Bearer.new(keys:, header:)
      end
    end
  end
end
