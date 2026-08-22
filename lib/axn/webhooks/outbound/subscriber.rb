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
            non_symbolizable = raw.keys.reject { |k| k.is_a?(Symbol) || k.is_a?(String) }
            raise Axn::Webhooks::InvalidTarget, "Hash has non-Symbol/String key(s): #{non_symbolizable.inspect}" if non_symbolizable.any?

            symbolized = raw.to_h { |k, v| [k.to_sym, v] }
            unknown = symbolized.keys - %i[url id]
            raise Axn::Webhooks::InvalidTarget, "Hash has unknown key(s): #{unknown.inspect}" if unknown.any?
            # Names only key NAMES (matching the "unknown key(s)" message above), never `raw` itself
            # -- this only reaches here when every key IS :url/:id (any other key is already
            # caught, safely, above), but an :id VALUE isn't constrained to a simple scalar. A
            # plausible mistake (passing the whole record instead of `record.id`) would otherwise
            # have `raw.inspect` render that object's full #inspect verbatim (Codex P1 finding).
            raise Axn::Webhooks::InvalidTarget, "Hash must include :url (keys present: #{symbolized.keys.inspect})" unless symbolized.key?(:url)

            new(url: symbolized[:url], id: symbolized[:id]&.to_s)
          end
        end
      end
    end
  end
end
