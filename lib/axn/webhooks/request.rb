# frozen_string_literal: true

require "rack"
require "rack/utils"

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

      # Build a Request from a Rack env. Reads rack.input ONCE, capturing the exact pristine bytes,
      # before rewinding — this (not a controller's already-parsed params) is why the spec chose a
      # Rack mount over a controller concern (see "## Packaging" in the design spec). The rewind is
      # best-effort courtesy for anything downstream: our own pipeline only ever needs raw_body, so
      # a non-rewindable rack.input (e.g. a bare Rack::Builder mount on a streaming server, with no
      # Rack::RewindableInput::Middleware in front) is tolerated rather than raising mid-request.
      def self.from_rack(env)
        input = env.fetch("rack.input")
        raw_body = input.read || ""
        begin
          input.rewind
        rescue StandardError
          nil # rewind is a courtesy; a non-rewindable/non-seekable stream (pipe/socket) is fine — raw_body is already captured
        end

        content_type = env["CONTENT_TYPE"]
        new(
          raw_body:,
          headers: extract_headers(env),
          params: extract_params(env, raw_body, content_type),
          url: extract_url(env),
          http_method: env["REQUEST_METHOD"],
        )
      end

      # HTTP_* env keys -> header names ("HTTP_X_SIG" -> "X-Sig"-ish; case doesn't matter, #header
      # looks up case-insensitively). CONTENT_TYPE/CONTENT_LENGTH are Rack's two documented
      # exceptions to the HTTP_* convention (never prefixed), so they're mapped explicitly.
      def self.extract_headers(env)
        headers = env.each_with_object({}) do |(key, value), acc|
          next unless key.start_with?("HTTP_")

          acc[key.delete_prefix("HTTP_").tr("_", "-")] = value
        end
        headers["Content-Type"] = env["CONTENT_TYPE"] if env["CONTENT_TYPE"]
        headers["Content-Length"] = env["CONTENT_LENGTH"] if env["CONTENT_LENGTH"]
        headers
      end
      private_class_method :extract_headers

      # `params` reflects the request's PRIMARY param source — never a query+form merge, because
      # `url` (below) already carries the query string. Merging both would double-count query
      # params for URL-signing verifiers (e.g. Twilio's RequestValidator does
      # `validate(req.url, req.params, signature)`, which HMACs the query string once via the url
      # and would HMAC it a second time via params if it were also merged in).
      #
      # - form-urlencoded body on a request that carries one (Twilio's SMS/voice POST) -> params =
      #   form fields only; the query (if any) is still reachable via `url`.
      # - everything else (GET/HEAD query, JSON POST, etc.) -> params = query string (e.g. the
      #   Nylas/Meta GET challenge, read via `req.params["challenge"]`). GET/HEAD never carry a
      #   body, so even a form-urlencoded default Content-Type header on a GET (common on
      #   challenge requests) must not shadow the query string with an empty-body parse.
      def self.extract_params(env, raw_body, content_type)
        method = env["REQUEST_METHOD"]
        form_body = content_type&.start_with?("application/x-www-form-urlencoded") && !%w[GET HEAD].include?(method)
        Rack::Utils.parse_nested_query(form_body ? raw_body : env["QUERY_STRING"])
      end
      private_class_method :extract_params

      # Delegates to Rack's own URL builder, which correctly assembles scheme + host +
      # SCRIPT_NAME (mount prefix) + PATH_INFO + query. A hand-rolled version that used
      # PATH_INFO alone would drop the mount prefix for endpoints mounted via
      # `mount Inbound[:vendor], at: "/webhooks/codat"` (Rails) or Rack::Builder#map, since
      # Rack puts that prefix in SCRIPT_NAME and leaves only the remainder in PATH_INFO —
      # breaking URL-based verifiers (e.g. Twilio's RequestValidator, which HMACs req.url).
      def self.extract_url(env)
        Rack::Request.new(env).url
      end
      private_class_method :extract_url
    end
  end
end
