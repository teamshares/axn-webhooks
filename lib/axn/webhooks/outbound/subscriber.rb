# frozen_string_literal: true

module Axn
  module Webhooks
    module Outbound
      # A resolved fan-out target: a URL plus an optional subscriber identity. `id` is what survives
      # the round trip through `Deliver`'s `call_async` re-enqueue (see `deliver.rb`'s
      # `subscriber_id` expects) — it is NEVER a secret/token, which would otherwise sit plaintext in
      # the queue backend for the life of a retry chain. Credentials are resolved per attempt from
      # this identity instead (see Signer's `subscriber:` kwarg).
      Subscriber = Data.define(:url, :id) do
        def initialize(url:, id: nil)
          super
        end

        class << self
          # Normalizes whatever a static `to:` Array entry or a `subscribers`/`to:` lambda returned:
          # already a Subscriber -> passed through; a bare String -> today's shape, `id: nil`; a Hash
          # (Symbol or String keys) -> must include `:url`, may include `:id` (stringified so a
          # caller can hand back an ActiveRecord id directly). Anything else -- including an unknown
          # Hash key, e.g. `{ url:, secret: }` -- raises loudly rather than silently dropping a
          # field the caller thought they were setting (Codex-style finding this design heads off).
          def coerce(raw)
            case raw
            when Subscriber then coerce_subscriber(raw)
            when String then new(url: raw, id: nil)
            when Hash then coerce_hash(raw)
            else
              raise Axn::Webhooks::InvalidTarget,
                    "must be a String URL or a Hash (got #{raw.class})"
            end
          end

          private

          # A resolver may construct a Subscriber directly (`Subscriber.new(url:, id: some_record.id)`)
          # rather than going through the Hash path -- and unlike `coerce_hash`'s `&.to_s`, a
          # bare `Subscriber.new` applies no such normalization. An Integer id would then reach
          # `Emit` as `subscriber_id` and fail `Deliver`'s `expects :subscriber_id, type: String`
          # despite passing every check here (Codex P2 finding). Returns the SAME object when its
          # id is already normalized (nil or a String), so the existing "passed through unchanged"
          # identity contract holds for the common case.
          def coerce_subscriber(raw)
            return raw if raw.id.nil? || raw.id.is_a?(String)

            new(url: raw.url, id: raw.id.to_s)
          end

          def coerce_hash(raw)
            # A key that isn't a Symbol/String (e.g. an Integer, from a raw DB row map) has no
            # #to_sym -- letting `to_sym` raise a bare NoMethodError here would propagate past
            # `resolve_subscribers`'s per-row `rescue Axn::Webhooks::InvalidTarget`, aborting the
            # WHOLE fan-out instead of rejecting just this one malformed row (Codex P2 finding).
            #
            # Named by CLASS only, never `.inspect` -- a plain Integer key is safe to show verbatim,
            # but a resolver mistake could just as easily use a COMPOUND object as a key (e.g. a
            # malformed `.to_h` transform keying by the record itself). That object's own #inspect
            # would otherwise render into this message, which `resolve_subscribers` stores verbatim
            # as a rejection's `:reason` -- an ActiveRecord-like model's #inspect commonly includes
            # every attribute, secrets included (Codex P1 finding, round 13).
            non_symbolizable = raw.keys.reject { |k| k.is_a?(Symbol) || k.is_a?(String) }
            raise Axn::Webhooks::InvalidTarget, "Hash has non-Symbol/String key(s): #{non_symbolizable.map(&:class).inspect}" if non_symbolizable.any?

            symbolized = begin
              raw.to_h { |k, v| [k.to_sym, v] }
            rescue EncodingError
              # The check above only rejects a key that ISN'T a Symbol/String -- but a String CAN
              # still fail `#to_sym` if it has an invalid encoding (a malformed byte sequence), even
              # though it passes that "is a String" check. Letting THAT raise a bare EncodingError
              # here would propagate past `resolve_subscribers`'s per-row `rescue
              # Axn::Webhooks::InvalidTarget`, aborting the WHOLE fan-out instead of rejecting just
              # this one malformed row (Codex P2 finding, round 22).
              raise Axn::Webhooks::InvalidTarget, "Hash has a key with an invalid encoding"
            end
            unknown = symbolized.keys - %i[url id]
            unknown_desc = unknown.map { |k| safe_key_name(k) }.join(", ")
            raise Axn::Webhooks::InvalidTarget, "Hash has unknown key(s): [#{unknown_desc}]" if unknown.any?
            # Names only key NAMES (matching the "unknown key(s)" message above), never `raw` itself
            # -- this only reaches here when every key IS :url/:id (any other key is already
            # caught, safely, above), but an :id VALUE isn't constrained to a simple scalar. A
            # plausible mistake (passing the whole record instead of `record.id`) would otherwise
            # have `raw.inspect` render that object's full #inspect verbatim (Codex P1 finding).
            raise Axn::Webhooks::InvalidTarget, "Hash must include :url (keys present: #{symbolized.keys.inspect})" unless symbolized.key?(:url)

            new(url: symbolized[:url], id: symbolized[:id]&.to_s)
          end

          # A plausible field-name typo (`:secret`, `:api_key`, `:token` -- the "unknown key(s)"
          # message exists to surface exactly this) is a short, simple identifier. `to_sym` already
          # ran unconditionally over EVERY key by the time this method sees them (round 13's
          # non-Symbol/String class-only fix doesn't apply here -- these keys already ARE Symbols),
          # so a resolver mistake keying its row by a URL String instead of `url:` (a plausible
          # `.to_h { |row| [row.url, row.id] }` bug) becomes a Symbol too, and echoing it verbatim
          # would render the whole URL -- credentials commonly embedded in it included (Codex P1
          # finding, round 20). Only a key matching this shape is safe to show as-is.
          SAFE_KEY_NAME = /\A[A-Za-z_][A-Za-z0-9_]{0,49}\z/
          private_constant :SAFE_KEY_NAME

          def safe_key_name(key)
            # `#match?` itself can raise (`Encoding::CompatibilityError`/`ArgumentError`) for a
            # String/Symbol in an unexpected encoding -- treated as "not a safe name" here, same as
            # every other malformed-input path in this file: never let a rejection-message helper
            # become the thing that raises past `resolve_subscribers`'s rescue.
            key.to_s.match?(SAFE_KEY_NAME) ? key.inspect : "<redacted>"
          rescue Encoding::CompatibilityError, ArgumentError
            "<redacted>"
          end
        end
      end
    end
  end
end
