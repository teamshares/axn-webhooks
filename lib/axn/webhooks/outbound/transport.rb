# frozen_string_literal: true

require "net/http"
require "uri"

module Axn
  module Webhooks
    module Outbound
      # The HTTP seam. Default is stdlib Net::HTTP (no runtime dependency); a consuming app may
      # inject its own object responding to `.post(url:, body:, headers:)` via Outbound config.
      module Transport
        # `body:` defaults to nil (via the custom `initialize`) so a custom transport built against
        # the pre-existing two-field shape keeps working unmodified.
        Response = Data.define(:status, :headers, :body) do
          def initialize(status:, headers:, body: nil)
            super
          end
        end

        # Raised by a transport for a genuinely retryable network condition. Deliver treats these
        # (and 5xx/429/503) as retryable; anything else raised by a transport is an unexpected
        # exception that propagates (the adapter's at-least-once crash safety net).
        RETRYABLE_NETWORK_ERRORS = [
          Timeout::Error, Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH,
          Errno::ETIMEDOUT, SocketError, IOError
        ].freeze

        # Headers this transport owns regardless of what a caller sets. Net::HTTP rewrites both
        # inside `send_request_with_body`, AFTER the caller's headers have been applied:
        # Content-Length is regenerated from the body, Transfer-Encoding is deleted outright. A
        # signature emitted under either name never leaves the process.
        #
        # This is the complete set for the built-in transport, established by observation rather
        # than by reading the stdlib: `spec/.../transport_reserved_headers_spec.rb` drives a real
        # socket and asserts exactly these two are clobbered while others (Host, Connection,
        # Accept-Encoding, custom names) survive. The transport_spec stubs `Net::HTTP#request`, so
        # it cannot see this — the rewriting happens inside the call it replaces.
        RESERVED_HEADERS = %w[content-length transfer-encoding].freeze

        module_function

        def post(url:, body:, headers:, open_timeout: 5, read_timeout: 10)
          uri = URI.parse(url)
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = (uri.scheme == "https")
          http.open_timeout = open_timeout
          http.read_timeout = read_timeout

          request = Net::HTTP::Post.new(uri.request_uri)
          request.body = body
          headers.each { |key, value| request[key] = value }

          response = http.request(request)
          Response.new(status: response.code.to_i, headers: response.to_hash.transform_values(&:first), body: response.body)
        end
      end
    end
  end
end
