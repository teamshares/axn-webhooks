# frozen_string_literal: true

require "net/http"
require "uri"

module Axn
  module Webhooks
    module Outbound
      # The HTTP seam. Default is stdlib Net::HTTP (no runtime dependency); a consuming app may
      # inject its own object responding to `.post(url:, body:, headers:)` via Outbound config.
      module Transport
        Response = Data.define(:status, :headers)

        # Raised by a transport for a genuinely retryable network condition. Deliver treats these
        # (and 5xx/429/503) as retryable; anything else raised by a transport is an unexpected
        # exception that propagates (the adapter's at-least-once crash safety net).
        RETRYABLE_NETWORK_ERRORS = [
          Timeout::Error, Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH,
          Errno::ETIMEDOUT, SocketError, IOError
        ].freeze

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
          Response.new(status: response.code.to_i, headers: response.to_hash.transform_values(&:first))
        end
      end
    end
  end
end
