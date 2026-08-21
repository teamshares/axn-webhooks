# frozen_string_literal: true

RSpec.describe Axn::Webhooks::Outbound::Subscriber do
  describe ".coerce" do
    it "passes a Subscriber through unchanged" do
      sub = described_class.new(url: "https://x.example/hook", id: "17")
      expect(described_class.coerce(sub)).to equal(sub)
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
