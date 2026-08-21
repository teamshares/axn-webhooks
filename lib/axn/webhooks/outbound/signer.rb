# frozen_string_literal: true

module Axn
  module Webhooks
    module Outbound
      # Builds a signer callable (#call(id:, timestamp:, body:) -> header Hash) from a `sign`
      # declaration. The :standard_webhooks strategy is the outbound face of the inbound
      # verify :standard_webhooks — same scheme, so a receiver using that verifier accepts it.
      module Signer
        module_function

        # RFC 7230 field-name token. Net::HTTP stores whatever key it is handed and serializes it
        # straight into the header line, so a space yields a malformed request and a newline
        # appends attacker-shaped wire headers — neither caught until delivery (Codex review).
        # Module-level (not nested under HmacSigner) so `Deliver`'s per-destination `headers`
        # merge (PRO-3214) can hold a subscriber-supplied header name to the SAME grammar, rather
        # than duplicating it — the identical injection risk, just from runtime data instead of a
        # `sign :hmac` declaration (Codex P1 finding).
        HEADER_NAME = /\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/

        def build(strategy:, opts:, block:)
          return CustomSigner.new(block) if block

          case strategy&.to_sym
          when :hmac then HmacSigner.new(**opts)
          when :standard_webhooks then StandardWebhooksSigner.new(**opts)
          # A pure declaration mistake (decided once at boot, never at runtime) — ArgumentError, not
          # Axn::Webhooks::Error, matching Config's own misconfiguration-vs-runtime split.
          else raise ArgumentError, "unknown sign strategy #{strategy.inspect}"
          end
        end

        # Wraps a user block; called with the same kwargs as the built-in signers, PLUS `subscriber:`
        # (PRO-3214, a `Subscriber` or nil) -- filtered down to whatever the block actually declares
        # (via CallableArity.accepted_keywords), so a block written against the original
        # `(id:, timestamp:, body:)` contract keeps working byte-for-byte rather than raising an
        # unexpected-keyword ArgumentError the moment a widened caller starts also offering
        # `subscriber:`. A block declaring `**` receives everything unfiltered.
        class CustomSigner
          REQUIRED_KEYWORDS = %i[id timestamp body].freeze

          def initialize(block)
            @block = block
            @accepted = CallableArity.accepted_keywords(block)
            validate_required_keywords!
          end

          def call(id:, timestamp:, body:, subscriber: nil)
            @block.call(**filtered({ id:, timestamp:, body:, subscriber: }))
          end

          private

          def filtered(kwargs)
            return kwargs if @accepted == :all

            kwargs.slice(*@accepted)
          end

          # A block incompatible with the original 3-kwarg contract would otherwise boot fine and
          # raise ArgumentError on the very first real delivery attempt -- the same class of Codex
          # finding the rest of this file guards against for `secret`/`backoff`/`user_agent`.
          def validate_required_keywords!
            return if @accepted == :all

            missing = REQUIRED_KEYWORDS - @accepted
            return if missing.empty?

            raise ArgumentError,
                  "sign block must accept #{REQUIRED_KEYWORDS.map { |k| "#{k}:" }.join(', ')} " \
                  "(missing #{missing.map { |k| "#{k}:" }.join(', ')})"
          end
        end

        # Parametric HMAC, the outbound face of `verify :hmac`. Emits ONE signature header plus an
        # optional timestamp header. `header:` is required: unlike Standard Webhooks there is no
        # universal header name, which is exactly why the inbound verifier requires `signature:`.
        class HmacSigner
          PLACEHOLDERS = %w[timestamp body].freeze
          DEFAULT_SIGNING_STRING = "{body}"

          def initialize(secret:, header:, digest: :sha256, encoding: :hex, prefix: nil,
                         signing_string: DEFAULT_SIGNING_STRING, timestamp_header: nil)
            validate_header_name!(:header, header)
            unless timestamp_header.nil?
              validate_header_name!(:timestamp_header, timestamp_header)
              # The timestamp assignment in `call` lands SECOND and would overwrite the signature,
              # shipping every delivery unverifiable — silently. HTTP header names are
              # case-insensitive, so compare that way (Codex review).
              if header.casecmp?(timestamp_header)
                raise ArgumentError,
                      "sign :hmac `header:` and `timestamp_header:` are the same header name " \
                      "(#{header.inspect}) — the timestamp would overwrite the signature"
              end
            end

            # Same reasoning as :standard_webhooks — `resolved_secret` calls with NO arguments, or
            # with the PRO-3214 `Subscriber` for a 1-arity per-subscriber secret. A callable needing
            # MORE than that boots fine and raises on every real signing attempt.
            if secret.respond_to?(:call) && !(CallableArity.accepts?(secret, 0) || CallableArity.accepts?(secret, 1))
              raise ArgumentError,
                    "sign :hmac secret callable must accept zero or one arguments (resolved with no " \
                    "args, or the Subscriber, per signing attempt)"
            end

            # Both are finite sets in Signature; an unvalidated typo boots fine and then raises
            # inside EVERY delivery attempt — on the async path, after the job is enqueued, so it
            # retries the same broken config (Codex review).
            raise ArgumentError, "sign :hmac unsupported digest: #{digest.inspect}" unless Signature::DIGESTS.key?(digest)
            raise ArgumentError, "sign :hmac unsupported encoding: #{encoding.inspect}" unless Signature::ENCODINGS.include?(encoding)

            validate_template!(signing_string, timestamp_header)

            # Copy every String we validated or emit. Validation runs ONCE, here; retaining the
            # caller's mutable object lets an app change what ships afterwards —
            # `header.replace("Content-Type")` walks straight past both the field-name grammar and
            # the MANAGED_HEADERS collision rule, and Deliver then overwrites the signature (Codex
            # review). Same validate-then-alias shape as Config's static `to:` array.
            @secret = secret # NOT copied: may be a callable, and a String secret is re-read per call anyway
            @header = dup_frozen(header)
            @digest = digest
            @encoding = encoding
            @prefix = dup_frozen(prefix)
            @signing_string = dup_frozen(signing_string)
            @timestamp_header = dup_frozen(timestamp_header)
          end

          # `id:` is part of the signer contract but unused here — an id-bearing signature is what
          # :standard_webhooks is for, and this preset emits no id header for a receiver to read one
          # back from. Absorbed by `**` rather than named, so it isn't an unused argument.
          def call(timestamp:, body:, subscriber: nil, **)
            sig = Signature.compute(
              secret: resolved_secret(subscriber),
              payload: render(timestamp:, body:),
              digest: @digest,
              encoding: @encoding,
            )

            headers = { @header => "#{@prefix}#{sig}" }
            headers[@timestamp_header] = timestamp.to_s if @timestamp_header
            headers
          end

          private

          def dup_frozen(value) = value.is_a?(String) ? value.dup.freeze : value

          # A `to_s`-based blank check is not enough: `false.to_s` is "false" and `123.to_s` is
          # "123", so both pass it and publish a signer that emits `{ false => "<sig>" }` for the
          # transport to choke on mid-delivery — a boot-time declaration mistake turned into a
          # repeatedly-retried delivery exception. For `timestamp_header:` a `false` is worse than
          # useless: it satisfies the {timestamp}-needs-a-header rule below while `call`'s
          # `if @timestamp_header` skips emitting it, leaving the receiver a timestamp-bound
          # signature it cannot reconstruct (Codex review).
          def validate_header_name!(option, value)
            unless value.is_a?(String) && !value.strip.empty?
              raise ArgumentError,
                    "sign :hmac `#{option}:` must be a non-empty String header name (got #{value.inspect})"
            end
            unless value.match?(HEADER_NAME)
              raise ArgumentError,
                    "sign :hmac `#{option}:` must be a valid HTTP header name (got #{value.inspect}) — " \
                    "letters, digits and !#$%&'*+-.^_`|~ only, with no spaces, colons or newlines"
            end

            # Everything set AFTER the signer runs: Deliver merges its own content-type/user-agent,
            # and the transport regenerates content-length from the body at send time. Any of them
            # emitted as the signature or timestamp header is silently replaced downstream.
            # Resolved here rather than at load time — signer.rb is required before deliver.rb.
            reserved = Deliver::MANAGED_HEADERS + Transport::RESERVED_HEADERS
            return unless reserved.any? { |managed| managed.casecmp?(value) }

            raise ArgumentError,
                  "sign :hmac `#{option}:` is #{value.inspect}, a header the delivery pipeline controls " \
                  "(#{reserved.join(', ')}) — it is set after signing and would replace this one"
          end

          def render(timestamp:, body:)
            @signing_string.gsub(/\{(\w+)\}/) { Regexp.last_match(1) == "timestamp" ? timestamp.to_s : body }
          end

          # A template (not a callable) so an unknown placeholder is caught HERE, at declaration
          # time — impossible with a lambda. Anyone needing real logic has the custom `sign { … }`
          # block already; a callable option would be a worse-ergonomics duplicate of it.
          def validate_template!(template, timestamp_header)
            raise ArgumentError, "sign :hmac `signing_string:` must be a String template (got #{template.class})" unless template.is_a?(String)

            # Strip the KNOWN placeholders, then treat any brace left behind as an error. Scanning
            # for `\{(\w+)\}` alone only ever saw well-formed braces, so `{time-stamp}` (hyphen) and
            # `{timestamp` (unmatched) matched nothing, passed validation, and got signed as literal
            # text — a signature the receiver cannot reconstruct, from the very option whose selling
            # point is declaration-time validation (Codex review). A literal brace in a signing
            # string is therefore not supported; it is far likelier to be a typo.
            leftover = template.gsub(/\{(?:#{PLACEHOLDERS.join('|')})\}/, "")
            if leftover.match?(/[{}]/)
              bad = leftover.scan(/\{[^{}]*\}|[{}]/).uniq
              raise ArgumentError,
                    "sign :hmac `signing_string:` has unknown or malformed placeholder(s) " \
                    "#{bad.map(&:inspect).join(', ')} (known: {timestamp}, {body})"
            end

            found = template.scan(/\{(\w+)\}/).flatten.uniq

            return unless found.include?("timestamp") && timestamp_header.nil?

            raise ArgumentError,
                  "sign :hmac `signing_string:` references {timestamp} but no `timestamp_header:` is " \
                  "declared — the receiver would have no way to reconstruct the signed string"
          end

          # A blank or non-String secret would otherwise sign every delivery with an empty/garbage
          # key, and the receiver's 401 is indistinguishable from any other misconfiguration. The
          # message NEVER carries the secret's bytes: a callable secret is re-resolved per attempt,
          # so this can raise on every delivery and would flow the live credential into whatever
          # Axn.config.on_exception is wired to.
          # Arity-aware, mirroring StandardWebhooksSigner's `resolve_secret`: a 1-arity secret
          # callable gets the Subscriber (PRO-3214, a per-subscriber secret); a 0-arity one (or a
          # plain value) resolves exactly as it did before subscriber-awareness existed.
          def resolved_secret(subscriber)
            secret = if @secret.respond_to?(:call)
                       # Prefer a ZERO-arg call whenever the callable can accept one: a PRE-EXISTING
                       # secret resolver with an unrelated optional arg (e.g. `->(app =
                       # Rails.application) { ... }`) must keep using ITS OWN default, not silently
                       # start receiving the Subscriber just because it COULD accept one arg. Only a
                       # callable that genuinely cannot be invoked with zero args (a REQUIRED single
                       # positional) gets the subscriber -- and that shape was rejected at boot
                       # entirely before subscriber-awareness existed, so there is no prior behavior
                       # to preserve for it (Codex P1 finding).
                       CallableArity.accepts?(@secret, 0) ? @secret.call : @secret.call(subscriber)
                     else
                       @secret
                     end
            return secret if secret.is_a?(String) && !secret.empty?

            raise Axn::Webhooks::Error,
                  "sign :hmac secret must be a non-empty String (got #{secret.is_a?(String) ? 'an empty String' : secret.class})"
          end
        end

        # Standard Webhooks: secret is `whsec_<base64>`; sign `id.timestamp.body` (sha256/base64);
        # emit `v1,<sig>` alongside the id/timestamp headers the inbound verifier reads.
        class StandardWebhooksSigner
          def initialize(secret:)
            # A pure declaration mistake, decided once at boot from the callable's own shape (not
            # from what it resolves to) — ArgumentError, matching Config's misconfiguration split.
            # `resolve_secret` below calls `@secret.call` with NO arguments, or with the PRO-3214
            # `Subscriber` for a 1-arity per-subscriber secret; a callable needing MORE than that
            # would otherwise boot successfully and raise ArgumentError on every real signing attempt
            # (Codex P2 finding, widened for the subscriber-aware case).
            if secret.respond_to?(:call) && !(CallableArity.accepts?(secret, 0) || CallableArity.accepts?(secret, 1))
              raise ArgumentError,
                    "sign :standard_webhooks secret callable must accept zero or one arguments " \
                    "(resolved with no args, or the Subscriber, per signing attempt)"
            end

            @secret = secret
          end

          def call(id:, timestamp:, body:, subscriber: nil)
            sig = Signature.compute(
              secret: decoded_secret(subscriber),
              payload: "#{id}.#{timestamp}.#{body}",
              digest: :sha256,
              encoding: :base64,
            )
            {
              "webhook-id" => id.to_s,
              "webhook-timestamp" => timestamp.to_s,
              "webhook-signature" => "v1,#{sig}",
            }
          end

          private

          # A callable secret (the norm for every other webhook secret in this gem — see
          # Resolvers.resolve) resolves per call rather than being frozen at `sign` time; a plain
          # value is used as-is. Arity-aware (PRO-3214): a 1-arity callable gets the Subscriber (a
          # per-subscriber secret); a 0-arity one resolves exactly as it did before subscriber-
          # awareness existed.
          def resolve_secret(subscriber)
            return @secret unless @secret.respond_to?(:call)

            # See the identical precedence rationale on HmacSigner#resolved_secret above (Codex P1
            # finding): prefer zero-arg, so an optional-arg secret keeps its own default.
            CallableArity.accepts?(@secret, 0) ? @secret.call : @secret.call(subscriber)
          end

          def decoded_secret(subscriber)
            secret = resolve_secret(subscriber)
            raise invalid_secret_error(secret) unless secret.is_a?(String) && secret.start_with?("whsec_")

            decoded = decode_or_reject(secret)
            raise invalid_secret_error(secret) if decoded.empty?

            decoded
          end

          # Scoped to ONLY the Base64 decode: a callable secret's own resolver can raise its own
          # ArgumentError for a completely different reason (e.g. a secret-store wrapper rejecting a
          # malformed response) — wrapping `resolve_secret` in this rescue would silently rewrite
          # that operational failure as a generic invalid-secret message, discarding the resolver's
          # actual diagnostic before it ever reaches Axn's exception reporter (Codex P2 finding).
          def decode_or_reject(secret)
            Verifiers::StandardWebhooks.decode_secret(secret)
          rescue ArgumentError
            raise invalid_secret_error(secret)
          end

          # A blank secret, or one missing the `whsec_` prefix, would otherwise decode "successfully"
          # (an empty or unprefixed value is still valid base64) and sign every delivery with an empty
          # or wrong key — silently, since the receiver's 401 is indistinguishable from any other
          # misconfiguration (Codex P1 finding).
          def invalid_secret_error(secret)
            Axn::Webhooks::Error.new("sign :standard_webhooks secret must be a whsec_<base64> value (got #{describe_secret(secret)})")
          end

          # Never interpolates the secret's actual bytes into the message: this error can be raised
          # on every delivery attempt (a callable secret is re-resolved per call, and may transiently
          # resolve to something malformed), and would otherwise flow the live signing credential
          # straight into whatever logs/exception reporter Axn.config.on_exception is wired to
          # (Codex P1 finding).
          def describe_secret(secret)
            return secret.class.name unless secret.is_a?(String)
            return "a #{secret.length}-char String not prefixed with whsec_" unless secret.start_with?("whsec_")

            "a whsec_-prefixed String that failed to decode"
          end
        end
      end
    end
  end
end
