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

        # A control character can't be represented in an RFC 7230 quoted-string at all, and CR/LF
        # would split the response header outright. Rejected at declaration time (this runs inside
        # `Axn::Webhooks.inbound`, i.e. at boot) rather than silently scrubbed: a realm is developer
        # config, so a typo should fail the deploy, not ship a subtly malformed challenge.
        CONTROL_CHARS = /[\x00-\x1F\x7F]/

        def initialize(username:, password:, realm: DEFAULT_REALM)
          raise Axn::Webhooks::Error, "verify :basic_auth realm cannot contain control characters" if realm.to_s.match?(CONTROL_CHARS)

          @username = username
          @password = password
          @realm = realm.to_s
        end

        attr_reader :realm

        # A verifier holds credentials by definition, and Verify's per-call logging renders its
        # `verifier:` input — so the default Object#inspect would put the plaintext password in the
        # application log on every single request. Same treatment Request gets, and for the same
        # reason. The realm is safe (and useful) to show: it's already broadcast in the challenge.
        def inspect = "#<#{self.class.name} realm=#{realm.inspect} credentials=[REDACTED]>"

        # PP does not route through #inspect — Kernel#pretty_print walks instance variables
        # directly — so without this `pp verifier` leaks exactly what #inspect just redacted.
        def pretty_print(printer) = printer.text(inspect)

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
          # Absent/non-Basic credentials are reported apart from wrong ones. Under RFC 7617 a bare
          # first request is the handshake working, not a failure, so it's the highest-volume
          # rejection on a healthy endpoint — conflating it with a real credential problem would
          # bury the latter in expected traffic.
          return Signature::CREDENTIALS_MISSING unless username

          # `&` rather than `&&` so the comparison doesn't short-circuit on the username.
          matched = secure_compare(username, expected_username) & secure_compare(password, expected_password)
          matched ? Signature::OK : Signature::CREDENTIALS_MISMATCH
        end

        # The RFC 7617 challenge. Lower-cased key per Rack 3's response-header SPEC (Response
        # lower-cases keys anyway; spelled that way here so the two agree on sight).
        #
        # The realm is an RFC 7230 quoted-string, so `"` and `\` are escaped rather than stripped —
        # the realm a client displays should be the one that was configured. Stripping only quotes
        # would leave a trailing backslash escaping the closing quote (`realm="Partner\"`), which
        # is malformed enough that a client may reject the challenge and never retry — recreating
        # the exact silent-drop failure this strategy exists to prevent.
        def unauthorized_headers
          { "www-authenticate" => %(Basic realm="#{realm.gsub(/([\\"])/, '\\\\\1')}") }
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

        # Hash first, then compare the two fixed-width digests — so the comparison itself is
        # constant-time AND independent of credential length. The obvious alternative, the bytesize
        # precheck in Signature#secure_compare, is fine for signatures (fixed width by construction)
        # but would answer "is the password N characters long?" here, where both sides are
        # arbitrary user-chosen strings. Same construction as ActiveSupport::SecurityUtils.
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
