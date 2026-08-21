# frozen_string_literal: true

require "base64"

# Config#resolve_subscribers is the PRO-3214 seam: `targets_for` (the pre-existing API, still used
# by today's `Emit`) is a thin back-compat wrapper around this that drops rejections -- see its own
# doc comment in config.rb. This file covers what `targets_for` can't express: Hash-shaped rows
# (identity, not just a URL), per-row rejection instead of all-or-nothing, and the host policy.
RSpec.describe "Axn::Webhooks::Outbound::Config#resolve_subscribers" do
  after { Axn::Webhooks::Outbound.reset! }

  let(:secret) { "whsec_#{Base64.strict_encode64('s')}" }

  def outbound!(&block)
    s = secret
    Axn::Webhooks.outbound do
      sign :standard_webhooks, secret: s
      instance_eval(&block)
    end
    Axn::Webhooks::Outbound.config
  end

  describe "Hash-shaped rows" do
    it "accepts a Hash row from a static to: Array, carrying its id through" do
      config = outbound! { event :lead_signed, to: [{ url: "https://a.example/hook", id: 17 }] }
      resolution = config.resolve_subscribers(:lead_signed)

      expect(resolution.subscribers).to eq([Axn::Webhooks::Outbound::Subscriber.new(url: "https://a.example/hook", id: "17")])
      expect(resolution.rejections).to eq([])
    end

    it "accepts a Hash row from a runtime subscribers resolver" do
      config = outbound! do
        subscribers ->(_event) { [{ url: "https://a.example/hook", id: "17" }] }
        event :lead_closed
      end
      resolution = config.resolve_subscribers(:lead_closed)

      expect(resolution.subscribers.first.id).to eq("17")
    end

    it "still accepts a bare String URL alongside Hash rows (today's shape, unchanged)" do
      config = outbound! { event :lead_signed, to: ["https://a.example/hook", { url: "https://b.example/hook", id: 2 }] }
      resolution = config.resolve_subscribers(:lead_signed)

      expect(resolution.subscribers).to eq([
                                             Axn::Webhooks::Outbound::Subscriber.new(url: "https://a.example/hook", id: nil),
                                             Axn::Webhooks::Outbound::Subscriber.new(url: "https://b.example/hook", id: "2"),
                                           ])
    end

    it "copies a static Hash row instead of freezing the caller's own object (mirrors the String-row fix)" do
      # Same hazard `config_immutability_spec` already pins for a plain String `to:` entry: a Hash
      # row is caller-supplied too (`event to: SOME_CONSTANT_ARRAY`), so mutating it after boot must
      # not rewrite the already-validated config underneath it.
      app_row = { url: +"https://a.example/hook", id: "17" }
      config = outbound! { event :lead_signed, to: [app_row] }

      expect(app_row).not_to be_frozen
      expect(app_row[:url]).not_to be_frozen

      app_row[:url].replace("ftp://bad.example/hook")
      app_row[:id] = "rewritten"

      resolution = config.resolve_subscribers(:lead_signed)
      expect(resolution.subscribers.first.url).to eq("https://a.example/hook")
      expect(resolution.subscribers.first.id).to eq("17")
    end
  end

  describe "per-row rejection" do
    it "rejects a malformed row without discarding the good ones in the same resolution" do
      config = outbound! do
        subscribers ->(_event) { ["https://good.example/hook", { url: nil }, "not-a-url"] }
        event :lead_closed
      end
      resolution = config.resolve_subscribers(:lead_closed)

      expect(resolution.subscribers.map(&:url)).to eq(["https://good.example/hook"])
      expect(resolution.rejections.size).to eq(2)
      expect(resolution.rejections[0]).to include(reason: a_string_matching(/must be a String/))
      expect(resolution.rejections[1]).to include(reason: a_string_matching(/is not a valid URL|must be http/))
    end

    it "rejects a row carrying an unknown key (e.g. a caller trying to smuggle a secret through) rather than silently dropping it" do
      config = outbound! do
        subscribers ->(_event) { [{ url: "https://a.example/hook", secret: "shh" }] }
        event :lead_closed
      end
      resolution = config.resolve_subscribers(:lead_closed)

      expect(resolution.subscribers).to eq([])
      expect(resolution.rejections.first[:reason]).to match(/unknown key.*secret/)
    end

    it "still raises loudly on an unknown EVENT (unaffected by per-row rejection)" do
      config = outbound! { event :lead_signed, to: ["https://a.example/hook"] }
      expect { config.resolve_subscribers(:nope) }.to raise_error(Axn::Webhooks::Error, /unknown outbound event/)
    end
  end

  describe "allowed_hosts / allow_url declared on the outbound block" do
    it "rejects a runtime-resolved row whose host isn't on the allowlist" do
      config = outbound! do
        allowed_hosts %w[good.example]
        subscribers ->(_event) { ["https://good.example/hook", "https://evil.example/hook"] }
        event :lead_closed
      end
      resolution = config.resolve_subscribers(:lead_closed)

      expect(resolution.subscribers.map(&:url)).to eq(["https://good.example/hook"])
      expect(resolution.rejections.first[:reason]).to match(/not allowed/)
    end

    it "rejects a STATIC to: entry the allowlist refuses, at BOOT time (ArgumentError, not a runtime rejection)" do
      expect do
        outbound! do
          allowed_hosts %w[good.example]
          event :x, to: ["https://evil.example/hook"]
        end
      end.to raise_error(ArgumentError, /not allowed/)
    end

    it "enforces a declared allow_url predicate against a runtime-resolved row" do
      config = outbound! do
        allow_url ->(uri) { uri.host == "good.example" }
        subscribers ->(_event) { ["https://good.example/hook", "https://evil.example/hook"] }
        event :lead_closed
      end
      resolution = config.resolve_subscribers(:lead_closed)

      expect(resolution.subscribers.map(&:url)).to eq(["https://good.example/hook"])
    end

    it "rejects a non-callable allow_url at boot" do
      expect do
        outbound! do
          allow_url("not-callable")
          event :x, to: ["https://a.example/hook"]
        end
      end
        .to raise_error(ArgumentError, /allow_url got invalid value.*must be a callable/)
    end

    it "rejects a zero-arity allow_url at boot (it needs the parsed URI to do anything useful)" do
      expect do
        outbound! do
          allow_url(-> { true })
          event :x, to: ["https://a.example/hook"]
        end
      end
        .to raise_error(ArgumentError, /allow_url got invalid value.*must be a callable/)
    end

    # The splat-friendly DSL always wraps a single arg into an Array, so a non-String element is
    # the only way left to trip the setting's own validator.
    it "rejects a non-String element" do
      expect do
        outbound! do
          allowed_hosts(123)
          event :x, to: ["https://a.example/hook"]
        end
      end
        .to raise_error(ArgumentError, /allowed_hosts got invalid value.*must be an Array/)
    end
  end

  describe "callable-object resolvers (no #arity of their own)" do
    it "invokes a plain callable OBJECT subscribers resolver via #call, not bare #arity (Codex-style finding)" do
      store = Class.new { def call(event) = ["https://store.example/#{event}"] }.new
      config = outbound! do
        subscribers store
        event :lead_closed
      end

      expect(config.resolve_subscribers(:lead_closed).subscribers.map(&:url)).to eq(["https://store.example/lead_closed"])
    end

    it "invokes a zero-arity callable object too" do
      store = Class.new { def call = ["https://store.example/fixed"] }.new
      config = outbound! do
        subscribers store
        event :lead_closed
      end

      expect(config.resolve_subscribers(:lead_closed).subscribers.map(&:url)).to eq(["https://store.example/fixed"])
    end
  end
end
