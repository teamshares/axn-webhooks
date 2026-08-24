# frozen_string_literal: true

require "json"

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
        # Values carrying CR/LF (or any other byte RFC 7230 forbids) are DROPPED, not rendered:
        # a `respond`/`static_respond`/`unauthorized_headers` declaration that echoes request data
        # into a header would otherwise let a sender inject headers or split the response. Dropped
        # rather than raised so a rendering mistake degrades to a missing header instead of a 500,
        # matching what the outbound half already does with a subscriber's custom headers.
        @headers = headers.each_with_object({}) do |(key, value), frozen|
          safe = sanitize_header(key, value)
          next if safe.nil?

          frozen[key.to_s.downcase.freeze] = deep_freeze(safe)
        end.freeze
        freeze
      end

      # An Array multi-value header (Set-Cookie, per Rack 3) is filtered element-wise so one bad
      # cookie doesn't discard the good ones; nil means "drop this header entirely".
      def sanitize_header(key, value)
        if value.is_a?(Array)
          kept = value.select { |element| HeaderValue.safe?(element) }
          warn_dropped(key) if kept.size != value.size
          return kept.empty? ? nil : kept
        end

        return value if HeaderValue.safe?(value)

        warn_dropped(key)
        nil
      end
      private :sanitize_header

      # Never logs the value itself — it is attacker-influenced by construction here, and echoing it
      # into the log is a smaller version of the same injection problem.
      def warn_dropped(key)
        Axn.config.logger.warn(
          "[axn-webhooks] dropping response header #{key.to_s.downcase.inspect} — value contains a " \
          "forbidden control character (or has an invalid encoding)",
        )
      end
      private :warn_dropped

      def self.ack(status: 200, headers: {}) = new(status:, headers:)

      def self.text(body, status: 200, headers: {})
        new(status:, body:, headers: { "content-type" => "text/plain" }.merge(headers))
      end

      def self.xml(body, status: 200, headers: {})
        new(status:, body:, headers: { "content-type" => "application/xml" }.merge(headers))
      end

      # A Hash/Array body is JSON-encoded; a String is assumed pre-serialized and passed through.
      def self.json(body, status: 200, headers: {})
        body = JSON.generate(body) unless body.is_a?(String)
        new(status:, body:, headers: { "content-type" => "application/json" }.merge(headers))
      end

      # A plausible HTTP status: an Integer inside the range HTTP defines. Shared by the
      # `unparseable_status` config setting and the per-endpoint `dispatch unparseable_status:`, so
      # both reject the same values against the same bound.
      def self.valid_status?(value) = value.is_a?(Integer) && (200..599).cover?(value)

      def self.service_unavailable(retry_after: nil)
        headers = retry_after ? { "retry-after" => retry_after.to_s } : {}
        new(status: 503, headers:)
      end

      # The same body and headers under a different status. The unparseable-body mapping needs it: a
      # declared `static_respond` block picked its status for the success path, but the gem owns the
      # outcome->status mapping, so the body a vendor keys on survives and only the status is restamped.
      def with_status(status) = self.class.new(status:, body:, headers:)

      def ==(other)
        other.is_a?(self.class) && status == other.status && body == other.body && headers == other.headers
      end

      # [status, headers, body] — the Rack app return contract. Headers are already lower-cased
      # (see #initialize); body is wrapped in an Array, Rack's documented minimal body contract.
      # Return a mutable copy of headers so Rails middleware can add headers (e.g., ETag).
      # Array header values (multi-value headers like Set-Cookie) are duped to be mutable so
      # middleware like Rack::Utils.set_cookie_header! can append; String values pass through.
      # Rack 3 requires Array headers, not newline-joined Strings.
      def to_rack = [status, headers.transform_values { |value| value.is_a?(Array) ? value.dup : value }, [body]]

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
