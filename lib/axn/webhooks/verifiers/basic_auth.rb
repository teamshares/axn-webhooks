# frozen_string_literal: true

require "base64"

module Axn
  module Webhooks
    module Verifiers
      # HTTP Basic auth (RFC 7617) as a verify strategy.
      #
      # Unlike the signature strategies, Basic auth is a two-legged protocol: a client that does
      # NOT authenticate preemptively sends its first request with no `Authorization` header,
      # expects a 401 carrying `WWW-Authenticate: Basic realm="…"`, and only then repeats the
      # request with credentials. Twilio documents exactly this behaviour for webhook URLs, and it
      # is why this strategy is a class rather than a bare lambda: `#unauthorized_headers` is what
      # Endpoint#to_response attaches to the 401, and without it the second leg never happens and
      # every webhook is silently dropped.
      class BasicAuth
        DEFAULT_REALM = "Webhook"

        def initialize(username:, password:, realm: DEFAULT_REALM)
          @username = username
          @password = password
          @realm = realm
        end

        attr_reader :realm

        def call(request)
          expected_username = Resolvers.resolve(@username, request).to_s
          expected_password = Resolvers.resolve(@password, request).to_s

          # Fail closed on a misconfigured deploy rather than comparing against "": an unset
          # credential pair would otherwise authenticate `Authorization: Basic Og==` for anyone.
          # Blank-but-present counts as missing — CI and secret managers can both set an empty
          # string. Raising (not returning false) makes it a reported exception, since a 401 that
          # means "we are misconfigured" is indistinguishable from one that means "you are not
          # Twilio" and would otherwise present as an unexplained outage.
          if expected_username.empty? || expected_password.empty?
            raise Axn::Webhooks::Error, "verify :basic_auth is missing a username or password (blank counts as missing)"
          end

          username, password = credentials(request)
          return false unless username

          # `&` rather than `&&` so the comparison doesn't short-circuit on the username.
          secure_compare(username, expected_username) & secure_compare(password, expected_password)
        end

        # The RFC 7617 challenge. Lower-cased key per Rack 3's response-header SPEC (Response
        # lower-cases keys anyway; spelled that way here so the two agree on sight).
        def unauthorized_headers
          { "www-authenticate" => %(Basic realm="#{realm.to_s.tr('"', '')}") }
        end

        private

        # [username, password], or nil when the header is absent or not a Basic credential —
        # which is the normal, expected shape of a reactive client's first request.
        def credentials(request)
          scheme, encoded = request.header("Authorization").to_s.split(" ", 2)
          return nil unless scheme&.casecmp?("Basic")

          # split(":", 2) — a password may legitimately contain colons; a username may not.
          username, password = Base64.decode64(encoded.to_s).split(":", 2)
          [username.to_s, password.to_s]
        end

        # Hash first, then compare fixed-length digests. Signature#secure_compare returns false on
        # a length mismatch instead, which is fine for signatures (fixed width by construction) but
        # would leak credential length here, where both sides are arbitrary user-chosen strings.
        def secure_compare(candidate, expected)
          OpenSSL.fixed_length_secure_compare(
            OpenSSL::Digest::SHA256.digest(candidate),
            OpenSSL::Digest::SHA256.digest(expected),
          )
        end
      end

      register(:basic_auth) do |username:, password:, realm: BasicAuth::DEFAULT_REALM|
        BasicAuth.new(username:, password:, realm:)
      end
    end
  end
end
