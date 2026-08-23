# frozen_string_literal: true

RSpec.describe Axn::Webhooks::Outbound::Subscriber do
  describe ".coerce" do
    it "passes a Subscriber through unchanged when its id is already a String (or nil)" do
      sub = described_class.new(url: "https://x.example/hook", id: "17")
      expect(described_class.coerce(sub)).to equal(sub)

      nil_id_sub = described_class.new(url: "https://x.example/hook")
      expect(described_class.coerce(nil_id_sub)).to equal(nil_id_sub)
    end

    # Codex P2 finding: a resolver constructing `Subscriber.new(url:, id: 17)` directly (an
    # Integer, not stringified) skipped the stringification the Hash-row path applies via
    # `coerce_hash`'s `symbolized[:id]&.to_s`. `Emit` then forwards the Integer as `subscriber_id`,
    # but `Deliver` declares that `expects :subscriber_id, type: String` -- so this otherwise-valid
    # target failed DELIVERY validation, despite passing every check `resolve_subscribers` runs.
    it "stringifies a prebuilt Subscriber's non-String id, matching the Hash-row path" do
      sub = described_class.new(url: "https://x.example/hook", id: 17)
      expect(described_class.coerce(sub)).to eq(described_class.new(url: "https://x.example/hook", id: "17"))
    end

    it "wraps a bare String URL with a nil id (today's shape, unchanged)" do
      sub = described_class.coerce("https://x.example/hook")
      expect(sub).to eq(described_class.new(url: "https://x.example/hook", id: nil))
    end

    it "builds from a Hash with :url and :id, stringifying id" do
      sub = described_class.coerce({ url: "https://x.example/hook", id: 17 })
      expect(sub).to eq(described_class.new(url: "https://x.example/hook", id: "17"))
    end

    it "builds from a Hash with :url only, defaulting id to nil" do
      sub = described_class.coerce({ url: "https://x.example/hook" })
      expect(sub).to eq(described_class.new(url: "https://x.example/hook", id: nil))
    end

    # Codex P1 finding, round 26: `symbolized[:id]&.to_s` accepted ANY value under `:id` and blindly
    # stringified it -- a resolver mistake passing the whole record instead of `record.id` (or a
    # Hash like `{ token: "live-key" }`) had its full contents rendered into the resulting
    # `subscriber_id`, which is NOT just log/rejection-message text: it's persisted in every async
    # job payload, exposed via `result.deliveries`, and stamped as an observability tag -- the exact
    # channel this whole design exists to keep credential-free. Only a documented scalar shape
    # (String, Integer, Symbol, or nil) is accepted; anything else raises loudly instead of silently
    # embedding its contents.
    it "raises on a compound (non-scalar) :id value rather than stringifying its contents" do
      expect { described_class.coerce({ url: "https://x.example/hook", id: { token: "live-key-do-not-leak" } }) }
        .to raise_error(Axn::Webhooks::InvalidTarget) { |e| expect(e.message).not_to include("live-key-do-not-leak") }
    end

    it "accepts a Symbol :id, stringifying it like an Integer" do
      sub = described_class.coerce({ url: "https://x.example/hook", id: :abc123 })
      expect(sub).to eq(described_class.new(url: "https://x.example/hook", id: "abc123"))
    end

    # Codex P2 finding, round 26: a String `:id` with an invalid encoding passed through unchanged
    # (`String#to_s` returns `self`) -- `Emit` forwards it as `subscriber_id`, and a JSON-backed
    # async adapter (Sidekiq) raises `JSON::GeneratorError` while SERIALIZING the enqueue payload,
    # aborting the whole `emit` rather than rejecting just this one malformed row.
    it "raises on a String :id with an invalid encoding" do
      bad_id = "\xFF".dup.force_encoding("UTF-8")

      expect { described_class.coerce({ url: "https://x.example/hook", id: bad_id }) }
        .to raise_error(Axn::Webhooks::InvalidTarget, /encoding/)
    end

    it "raises on a prebuilt Subscriber's compound (non-scalar) id too, not just the Hash-row path" do
      sub = described_class.new(url: "https://x.example/hook", id: { token: "live-key-do-not-leak" })

      expect { described_class.coerce(sub) }
        .to raise_error(Axn::Webhooks::InvalidTarget) { |e| expect(e.message).not_to include("live-key-do-not-leak") }
    end

    it "raises on a prebuilt Subscriber's invalidly-encoded String id too, not just the Hash-row path" do
      bad_id = "\xFF".dup.force_encoding("UTF-8")
      sub = described_class.new(url: "https://x.example/hook", id: bad_id)

      expect { described_class.coerce(sub) }.to raise_error(Axn::Webhooks::InvalidTarget, /encoding/)
    end

    it "accepts String keys, matching the rest of this gem's Hash-tolerance conventions" do
      sub = described_class.coerce({ "url" => "https://x.example/hook", "id" => "17" })
      expect(sub).to eq(described_class.new(url: "https://x.example/hook", id: "17"))
    end

    it "raises on a Hash missing :url" do
      expect { described_class.coerce({ id: "17" }) }
        .to raise_error(Axn::Webhooks::InvalidTarget, /must include :url/)
    end

    # Codex P1 finding, round 10: this branch only reaches `raw.inspect` when every key IS
    # `:url`/`:id` (any OTHER key is already caught, safely, by the "unknown key(s)" check above)
    # -- but `:id`'s VALUE isn't constrained to a simple scalar. A plausible mistake (passing the
    # whole record instead of `record.id`) puts a verbose object under `:id`, and the OLD message
    # interpolated the whole raw Hash, which would render that object's full #inspect. The message
    # now names only key NAMES, matching the "unknown key(s)" message's existing convention, so it
    # can never echo an arbitrary value regardless of what ends up under :id.
    it "never echoes the Hash's VALUES in the missing-:url message, only its key names" do
      fake_record = Struct.new(:id, :api_token) do
        def inspect = "#<FakeRecord id=1, api_token=\"live-key-do-not-leak\">"
      end.new(1, "live-key-do-not-leak")

      expect { described_class.coerce({ id: fake_record }) }
        .to raise_error(Axn::Webhooks::InvalidTarget) { |e| expect(e.message).not_to include("live-key-do-not-leak") }
    end

    # A row shaped like `{ url:, secret: }` (the shape the ticket originally proposed, and the shape
    # this design deliberately rejects — see Phase 1 design notes) must fail LOUDLY rather than
    # silently dropping the credential and delivering unsigned/under-signed.
    it "raises on an unknown Hash key rather than silently discarding it" do
      expect { described_class.coerce({ url: "https://x.example/hook", secret: "shh" }) }
        .to raise_error(Axn::Webhooks::InvalidTarget, /unknown key.*secret/)
    end

    # Codex P1 finding, round 20: `coerce_hash` symbolizes EVERY key via `k.to_sym` before
    # computing `unknown` -- so a resolver mistake keying its row by a URL String instead of using
    # `url:` (e.g. `{ "https://hooks.example/services/T00/B00/live-secret" => "17" }`, a plausible
    # `.to_h { |row| [row.url, row.id] }` bug) becomes a Symbol too, and the OLD message named it
    # via `unknown.inspect` -- the SAME class of leak round 13 fixed for a non-Symbol/String key,
    # just for a key that's ALREADY a String/Symbol by the time it gets here (so that fix's
    # class-only check never applied). Only a short, identifier-shaped key name (the plausible
    # "typo'd field name" case this message exists to surface, e.g. `:secret`) is safe to show
    # as-is; anything else -- long, or containing URL-shaped punctuation -- must not echo its
    # content.
    it "never echoes an unknown key's full content when it isn't a plausible field-name typo (e.g. a URL used as a key)" do
      leaky_key = "https://hooks.example/services/T00/B00/live-secret-do-not-leak"

      expect { described_class.coerce({ leaky_key => "17", url: "https://x.example/hook" }) }
        .to raise_error(Axn::Webhooks::InvalidTarget) { |e| expect(e.message).not_to include("live-secret-do-not-leak") }
    end

    # Codex P2 finding: `symbolized = raw.to_h { |k, v| [k.to_sym, v] }` raises bare NoMethodError
    # for a key that doesn't respond to #to_sym (e.g. an Integer) -- uncaught by
    # `resolve_subscribers`'s per-row `rescue Axn::Webhooks::InvalidTarget`, so one row with a
    # stray non-Symbol/String key aborted the WHOLE emit rather than being rejected on its own.
    it "raises InvalidTarget (not NoMethodError) on a Hash key that doesn't respond to #to_sym" do
      expect { described_class.coerce({ 1 => "https://x.example/hook", url: "https://x.example/hook" }) }
        .to raise_error(Axn::Webhooks::InvalidTarget, /key/)
    end

    # Codex P2 finding, round 22: the `non_symbolizable` check above only rejects a key that ISN'T
    # a Symbol/String -- but a String CAN still fail `#to_sym` if it has an invalid encoding (e.g.
    # `"\xFF".force_encoding("UTF-8")`, a malformed byte sequence), even though it passes that "is a
    # String" check. `raw.to_h { |k, v| [k.to_sym, v] }` then raised a bare `EncodingError`, which
    # `resolve_subscribers`'s per-row `rescue Axn::Webhooks::InvalidTarget` never catches --
    # aborting the WHOLE fan-out instead of rejecting just this one malformed row.
    it "raises InvalidTarget (not EncodingError) on a String key with an invalid encoding" do
      bad_key = "\xFF".dup.force_encoding("UTF-8")

      expect { described_class.coerce({ bad_key => "17", url: "https://x.example/hook" }) }
        .to raise_error(Axn::Webhooks::InvalidTarget, /key/)
    end

    # Codex P1 finding, round 13: the message above named the offending key(s) via
    # `non_symbolizable.inspect` -- safe for a plain Integer key, but a resolver mistake could just
    # as easily use a COMPOUND object as a key (e.g. `{ subscription_record => url }`, from a
    # malformed `.to_h` transform). That object's own #inspect renders into the exception message,
    # which `resolve_subscribers` stores verbatim as a rejection's `:reason` -- an ActiveRecord-like
    # model's #inspect commonly includes every attribute, secrets included.
    it "never echoes a non-Symbol/String key's #inspect in the message, only its class" do
      fake_record = Struct.new(:id, :api_token) do
        def inspect = "#<FakeRecord id=1 api_token=\"live-key-do-not-leak\">"
      end.new(1, "live-key-do-not-leak")

      expect { described_class.coerce({ fake_record => "https://x.example/hook", url: "https://x.example/hook" }) }
        .to raise_error(Axn::Webhooks::InvalidTarget) { |e| expect(e.message).not_to include("live-key-do-not-leak") }
    end

    it "raises on anything that isn't a String, Hash, or Subscriber" do
      expect { described_class.coerce(nil) }
        .to raise_error(Axn::Webhooks::InvalidTarget, /must be a String URL or a Hash/)
      expect { described_class.coerce(42) }
        .to raise_error(Axn::Webhooks::InvalidTarget, /must be a String URL or a Hash/)
      expect { described_class.coerce(URI("https://x.example/hook")) }
        .to raise_error(Axn::Webhooks::InvalidTarget, /must be a String URL or a Hash/)
    end
  end
end
