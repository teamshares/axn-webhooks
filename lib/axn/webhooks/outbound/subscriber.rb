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
            when Subscriber then raw
            when String then new(url: raw, id: nil)
            when Hash then coerce_hash(raw)
            else
              raise Axn::Webhooks::InvalidTarget,
                    "must be a String URL or a Hash (got #{raw.class})"
            end
          end

          private

          def coerce_hash(raw)
            symbolized = raw.to_h { |k, v| [k.to_sym, v] }
            unknown = symbolized.keys - %i[url id]
            raise Axn::Webhooks::InvalidTarget, "Hash has unknown key(s): #{unknown.inspect}" if unknown.any?
            raise Axn::Webhooks::InvalidTarget, "Hash must include :url (got #{raw.inspect})" unless symbolized.key?(:url)

            new(url: symbolized[:url], id: symbolized[:id]&.to_s)
          end
        end
      end
    end
  end
end
