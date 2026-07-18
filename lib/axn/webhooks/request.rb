# frozen_string_literal: true

module Axn
  module Webhooks
    # A Rails-agnostic view of an inbound webhook request. Verifiers and dispatchers read
    # only from this object, so the same pipeline works behind a Rack mount, a controller,
    # or a plain test constructor. Header lookup is case-insensitive.
    class Request
      def initialize(raw_body:, headers: {}, params: {}, url: nil, http_method: "POST")
        @raw_body = raw_body.frozen? ? raw_body : raw_body.dup.freeze
        @headers = (headers || {}).each_with_object({}) { |(k, v), h| h[k.to_s.downcase] = v }
        @params = (params || {}).dup.freeze
        @url = url
        @http_method = http_method.to_s.upcase
      end

      attr_reader :raw_body, :params, :url, :http_method

      def header(name)
        @headers[name.to_s.downcase]
      end
    end
  end
end
