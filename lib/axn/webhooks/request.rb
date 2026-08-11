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

      # `raw_body` and `headers` are attacker-controlled webhook payloads of unknown sensitivity
      # (bank account numbers, API credentials, mailing addresses have all shown up in the wild) —
      # never render them. This is the one place that matters: axn's auto-logging, exception
      # reports, and any other caller that inspects a Request all go through #inspect.
      def inspect
        "#<#{self.class.name} #{http_method} #{url} raw_body=[REDACTED] (#{raw_body.bytesize}b) headers=[REDACTED]>"
      end

      # `pp`/PP does not call #inspect by default (Kernel#pretty_print walks instance variables
      # directly), so without this override `pp request` would leak the same fields #inspect redacts.
      def pretty_print(printer)
        printer.text(inspect)
      end

      # Build a Request from a Rack env, capturing the exact pristine body bytes — this (not a
      # controller's already-parsed params) is why the spec chose a Rack mount over a controller
      # concern (see "## Packaging" in the design spec).
      #
      # rack.input is OPTIONAL under Rack 3 (it was mandatory in Rack 2), so a bodyless request may
      # omit the key entirely — Rack::MockRequest.env_for does exactly that, which is what a Rails
      # integration/request spec builds. Treat a missing input as an empty body rather than a
      # malformed env: the GET challenge handshake (Nylas, Meta) is bodyless by definition, so
      # fetching here would 500 the very handshake `challenge` exists to serve.
      #
      # We rewind BEFORE reading, not only after. Under Rack 3, `Rack::Request#POST` no longer
      # rewinds rack.input after parsing a form-urlencoded body — and Rails' default middleware
      # stack runs `Rack::MethodOverride` (which calls `#POST` looking for `_method`) ahead of the
      # router. So by the time a mounted endpoint runs, the input of every form-encoded POST is
      # already at EOF and reads as "". That silently empties raw_body AND params for exactly the
      # vendors that post forms (Twilio, Slack), breaking dispatch and signature verification alike.
      def self.from_rack(env)
        input = env["rack.input"]
        rewind(input)
        raw_body = input&.read || ""
        rewind(input) # courtesy for anything downstream of us

        content_type = env["CONTENT_TYPE"]
        new(
          raw_body:,
          headers: extract_headers(env),
          params: extract_params(env, raw_body, content_type),
          url: extract_url(env),
          http_method: env["REQUEST_METHOD"],
        )
      end

      # Best-effort: a non-rewindable/non-seekable stream (pipe/socket, or a bare Rack::Builder mount
      # with no Rack::RewindableInput::Middleware in front) is tolerated rather than raising
      # mid-request. Nothing upstream can have consumed such a stream either, so a single forward
      # read still yields the pristine body.
      def self.rewind(input)
        input&.rewind
      rescue StandardError
        nil
      end
      private_class_method :rewind

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
      # - multipart/form-data body -> same, parsed by Rack (Dropbox Sign posts the whole event as a
      #   single `json` field, and its verifier reads that field twice: Content-MD5 over it, then
      #   JSON.parse of it).
      # - everything else (GET/HEAD query, JSON POST, etc.) -> params = query string (e.g. the
      #   Nylas/Meta GET challenge, read via `req.params["challenge"]`). GET/HEAD never carry a
      #   body, so even a form-urlencoded default Content-Type header on a GET (common on
      #   challenge requests) must not shadow the query string with an empty-body parse.
      def self.extract_params(env, raw_body, content_type)
        return Rack::Utils.parse_nested_query(env["QUERY_STRING"]) if %w[GET HEAD].include?(env["REQUEST_METHOD"])

        if content_type&.start_with?("application/x-www-form-urlencoded")
          # Parsed from raw_body rather than via Rack, so this branch stays independent of Rack's
          # form-hash caching (and of whatever position upstream middleware left rack.input in).
          Rack::Utils.parse_nested_query(raw_body)
        elsif content_type&.start_with?("multipart/form-data")
          parse_multipart(env)
        else
          Rack::Utils.parse_nested_query(env["QUERY_STRING"])
        end
      end
      private_class_method :extract_params

      # Rack owns multipart parsing (boundary handling differs across Rack 3 minors), so delegate.
      #
      # `#POST` reads rack.input, hence the rewind afterwards — `from_rack` already rewound before
      # its own `raw_body` read, so input is at 0 when we get here, but it would be left at EOF for
      # anything downstream of the mount.
      #
      # A malformed body must yield `{}`, not raise: this runs on an UNVERIFIED request, so any
      # parse error Rack raises (Rack::Multipart::EmptyContentError and friends) would let a hostile
      # sender crash the pipeline before `verify` ever gets to reject them.
      def self.parse_multipart(env)
        Rack::Request.new(env).POST
      rescue StandardError
        {}
      ensure
        rewind(env["rack.input"])
      end
      private_class_method :parse_multipart

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
