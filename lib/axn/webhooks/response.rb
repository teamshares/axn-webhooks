# frozen_string_literal: true

module Axn
  module Webhooks
    # A Rails-agnostic HTTP response value: status + body + headers. Produced by
    # `Endpoint#to_response`/`#challenge_response` from the pipeline's Axn::Result. `#to_rack`
    # renders it as the [status, headers, body] triple Endpoint#call(env) returns.
    class Response
      attr_reader :status, :body, :headers

      def initialize(status: 200, body: "", headers: {})
        @status = status
        # deep_freeze (not `.freeze`) so a caller-owned String body isn't frozen in place —
        # `String#to_s` returns self, so `.freeze` would mutate the handler's own string.
        @body = deep_freeze(body.to_s)
        # Keys are lower-cased (Rack 3's SPEC forbids uppercase in response header keys, and
        # Rack::Lint rejects them). Keys AND values are frozen deeply (Array multi-value headers
        # freeze their elements too) so a caller's mutable value can't mutate this rendered-later value.
        @headers = headers.each_with_object({}) do |(key, value), frozen|
          frozen[key.to_s.downcase.freeze] = deep_freeze(value)
        end.freeze
        freeze
      end

      def self.ack(status: 200, headers: {}) = new(status:, headers:)

      def self.text(body, status: 200, headers: {})
        new(status:, body:, headers: { "content-type" => "text/plain" }.merge(headers))
      end

      def self.xml(body, status: 200, headers: {})
        new(status:, body:, headers: { "content-type" => "application/xml" }.merge(headers))
      end

      def ==(other)
        other.is_a?(self.class) && status == other.status && body == other.body && headers == other.headers
      end

      # [status, headers, body] — the Rack app return contract. Headers are already lower-cased
      # (see #initialize); body is wrapped in an Array, Rack's documented minimal body contract.
      # Return a mutable copy of headers so Rails middleware can add headers (e.g., ETag).
      # Normalize Array header values (multi-value headers like Set-Cookie) to newline-joined
      # Strings, valid in both Rack 2.2 and Rack 3, and required by Rack 2.2's Lint.
      def to_rack
        rack_headers = headers.transform_values { |value| value.is_a?(Array) ? value.join("\n") : value }
        [status, rack_headers, [body]]
      end

      private

      # Freeze a header value so it can't be mutated after construction. Handles the two Rack
      # header-value shapes: a String, and an Array of Strings (multi-value headers) whose
      # elements are frozen too.
      def deep_freeze(value)
        return value.map { |element| deep_freeze(element) }.freeze if value.is_a?(Array)

        value.frozen? ? value : value.dup.freeze
      end
    end
  end
end
