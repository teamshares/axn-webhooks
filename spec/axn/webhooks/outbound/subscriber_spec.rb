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

    it "accepts String keys, matching the rest of this gem's Hash-tolerance conventions" do
      sub = described_class.coerce({ "url" => "https://x.example/hook", "id" => "17" })
      expect(sub).to eq(described_class.new(url: "https://x.example/hook", id: "17"))
    end

    it "raises on a Hash missing :url" do
      expect { described_class.coerce({ id: "17" }) }
        .to raise_error(Axn::Webhooks::InvalidTarget, /must include :url/)
    end

    # A row shaped like `{ url:, secret: }` (the shape the ticket originally proposed, and the shape
    # this design deliberately rejects — see Phase 1 design notes) must fail LOUDLY rather than
    # silently dropping the credential and delivering unsigned/under-signed.
    it "raises on an unknown Hash key rather than silently discarding it" do
      expect { described_class.coerce({ url: "https://x.example/hook", secret: "shh" }) }
        .to raise_error(Axn::Webhooks::InvalidTarget, /unknown key.*secret/)
    end

    # Codex P2 finding: `symbolized = raw.to_h { |k, v| [k.to_sym, v] }` raises bare NoMethodError
    # for a key that doesn't respond to #to_sym (e.g. an Integer) -- uncaught by
    # `resolve_subscribers`'s per-row `rescue Axn::Webhooks::InvalidTarget`, so one row with a
    # stray non-Symbol/String key aborted the WHOLE emit rather than being rejected on its own.
    it "raises InvalidTarget (not NoMethodError) on a Hash key that doesn't respond to #to_sym" do
      expect { described_class.coerce({ 1 => "https://x.example/hook", url: "https://x.example/hook" }) }
        .to raise_error(Axn::Webhooks::InvalidTarget, /key/)
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
