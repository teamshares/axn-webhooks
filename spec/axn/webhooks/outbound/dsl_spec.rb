# frozen_string_literal: true

require "base64"

RSpec.describe "Axn::Webhooks.outbound" do
  after { Axn::Webhooks::Outbound.reset! }

  let(:secret) { "whsec_#{Base64.strict_encode64('secret')}" }

  it "captures signer, events, and retry curve; resolves static targets" do
    Axn::Webhooks.outbound do
      sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('secret')}"
      max_attempts 5
      backoff ->(attempt) { attempt * 10 }
      event :lead_signed, to: ["https://os.example/hook"]
    end

    config = Axn::Webhooks::Outbound.config
    expect(config.targets_for(:lead_signed)).to eq(["https://os.example/hook"])
    expect(config.max_attempts).to eq(5)
    expect(config.backoff.call(3)).to eq(30)
    expect(config.wire_type(:lead_signed)).to eq("lead_signed")
    expect(config.signer.call(id: "m", timestamp: 1, body: "b")).to include("webhook-signature")
  end

  it "supports a per-event wire type override" do
    Axn::Webhooks.outbound do
      sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('s')}"
      event :lead_signed, type: "lead.signed", to: ["https://x"]
    end
    expect(Axn::Webhooks::Outbound.config.wire_type(:lead_signed)).to eq("lead.signed")
  end

  it "stringifies a non-String per-event wire type override (codex P2)" do
    Axn::Webhooks.outbound do
      sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('s')}"
      event :x, type: :sym_type
    end
    result = Axn::Webhooks::Outbound.config.wire_type(:x)
    expect(result).to eq("sym_type")
    expect(result).to be_a(String)
  end

  it "falls back to the block-level `subscribers` resolver when an event has no `to:`" do
    Axn::Webhooks.outbound do
      sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('s')}"
      subscribers ->(event) { ["https://resolved/#{event}"] }
      event :lead_closed
    end
    expect(Axn::Webhooks::Outbound.config.targets_for(:lead_closed)).to eq(["https://resolved/lead_closed"])
  end

  it "does NOT fall back to `subscribers` when a declared per-event `to:` resolver returns nil" do
    Axn::Webhooks.outbound do
      sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('s')}"
      subscribers ->(_event) { ["https://DEFAULT"] }
      event :x, to: ->(_event) {}
      event :y
    end
    config = Axn::Webhooks::Outbound.config

    # Declared `to:` won even though it resolved to nil -> deliver nowhere, NOT the default audience.
    expect(config.targets_for(:x)).to eq([])
    # Undeclared `to:` still falls back to the block-level `subscribers` resolver, unchanged.
    expect(config.targets_for(:y)).to eq(["https://DEFAULT"])
  end

  it "invokes a per-event `to:` lambda (arity-aware) instead of wrapping the Proc itself" do
    Axn::Webhooks.outbound do
      sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('s')}"
      event :lead_signed, to: ->(event) { ["https://u/#{event}"] }
    end
    expect(Axn::Webhooks::Outbound.config.targets_for(:lead_signed)).to eq(["https://u/lead_signed"])
  end

  it "still supports a static Array `to:` alongside a per-event lambda on another event" do
    Axn::Webhooks.outbound do
      sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('s')}"
      event :lead_signed, to: ["https://os.example/hook"]
      event :lead_closed, to: ->(event) { ["https://u/#{event}"] }
    end
    config = Axn::Webhooks::Outbound.config
    expect(config.targets_for(:lead_signed)).to eq(["https://os.example/hook"])
    expect(config.targets_for(:lead_closed)).to eq(["https://u/lead_closed"])
  end

  it "raises loudly on an unknown event, listing the known ones" do
    Axn::Webhooks.outbound do
      sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('s')}"
      event :lead_signed, to: ["https://x"]
    end
    expect { Axn::Webhooks::Outbound.config.targets_for(:nope) }
      .to raise_error(Axn::Webhooks::Error, /unknown outbound event :nope.*lead_signed/m)
  end

  it "raises when config is read before `outbound` is declared" do
    Axn::Webhooks::Outbound.reset!
    expect { Axn::Webhooks::Outbound.config }.to raise_error(Axn::Webhooks::Error, /no `outbound` block/)
  end

  it "warns (does not raise) at boot when an event has a statically empty target list" do
    expect(Axn.config.logger).to receive(:warn).with(/lead_signed.*empty/i)
    Axn::Webhooks.outbound do
      sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('s')}"
      event :lead_signed, to: []
    end
  end

  it "warns (does not raise) when a second `outbound` block replaces the first" do
    Axn::Webhooks.outbound do
      sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('s')}"
      event :lead_signed, to: ["https://x"]
    end

    expect(Axn.config.logger).to receive(:warn).with(/second.*outbound.*block.*replaces/i)
    Axn::Webhooks.outbound do
      sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('s')}"
      event :lead_closed, to: ["https://y"]
    end

    expect(Axn::Webhooks::Outbound.config.targets_for(:lead_closed)).to eq(["https://y"])
  end

  describe "vendor tagging" do
    it "stamps the block-level default vendor for an event with no override" do
      Axn::Webhooks.outbound do
        sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('s')}"
        vendor :internal
        event :lead_signed, to: ["https://x"]
      end
      expect(Axn::Webhooks::Outbound.config.vendor_for(:lead_signed)).to eq(:internal)
    end

    it "lets a per-event vendor override the block-level default" do
      Axn::Webhooks.outbound do
        sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('s')}"
        vendor :internal
        event :lead_signed, to: ["https://x"], vendor: :leads_pipeline
      end
      expect(Axn::Webhooks::Outbound.config.vendor_for(:lead_signed)).to eq(:leads_pipeline)
    end

    it "is nil when neither the block nor the event declares one" do
      Axn::Webhooks.outbound do
        sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('s')}"
        event :lead_signed, to: ["https://x"]
      end
      expect(Axn::Webhooks::Outbound.config.vendor_for(:lead_signed)).to be_nil
    end
  end

  describe "validation" do
    # Every check below is a pure declaration mistake, decided once at boot when the `outbound`
    # block is evaluated — never triggered by runtime/user data, and not something a running app
    # would rescue-and-continue past. So it's plain ArgumentError, not the gem's own
    # `Axn::Webhooks::Error` (reserved for conditions that can happen at runtime and might
    # legitimately be rescued — e.g. `targets_for`'s unknown-event error, raised on every `emit`
    # call rather than once at boot).
    it "rejects a non-positive max_attempts" do
      expect do
        Axn::Webhooks.outbound do
          sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('s')}"
          max_attempts 0
          event :x, to: ["https://x"]
        end
      end.to raise_error(ArgumentError, /max_attempts got invalid value.*must be a positive Integer/)
    end

    it "rejects a non-Numeric timeout (e.g. a String from ENV.fetch)" do
      expect do
        Axn::Webhooks.outbound do
          sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('s')}"
          timeouts open: "5"
          event :x, to: ["https://x"]
        end
      end.to raise_error(ArgumentError, /open_timeout got invalid value.*must be a positive Numeric/)
    end

    it "rejects a non-positive read timeout" do
      expect do
        Axn::Webhooks.outbound do
          sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('s')}"
          timeouts read: 0
          event :x, to: ["https://x"]
        end
      end.to raise_error(ArgumentError, /read_timeout got invalid value.*must be a positive Numeric/)
    end

    it "rejects a zero-arity backoff" do
      expect do
        Axn::Webhooks.outbound do
          sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('s')}"
          backoff -> { 30 }
          event :x, to: ["https://x"]
        end
      end.to raise_error(ArgumentError, /backoff got invalid value.*must be a callable accepting the attempt number/)
    end

    it "accepts a plain callable object backoff (no #arity of its own — only Method#arity via #call)" do
      backoff_object = Class.new { def call(attempt) = attempt * 10 }.new

      expect do
        Axn::Webhooks.outbound do
          sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('s')}"
          backoff backoff_object
          event :x, to: ["https://x"]
        end
      end.not_to raise_error
    end

    it "rejects a backoff that reports arity 1 but actually requires a keyword (fails on the real .call(attempt))" do
      expect do
        Axn::Webhooks.outbound do
          sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('s')}"
          backoff ->(attempt:) { attempt * 10 }
          event :x, to: ["https://x"]
        end
      end.to raise_error(ArgumentError, /backoff got invalid value.*must be a callable accepting the attempt number/)
    end

    it "rejects a backoff that reports negative arity but actually requires two positional args" do
      expect do
        Axn::Webhooks.outbound do
          sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('s')}"
          backoff ->(a, b, *_rest) { a + b }
          event :x, to: ["https://x"]
        end
      end.to raise_error(ArgumentError, /backoff got invalid value.*must be a callable accepting the attempt number/)
    end

    it "accepts a splat-only backoff, which genuinely works with .call(attempt)" do
      expect do
        Axn::Webhooks.outbound do
          sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('s')}"
          backoff ->(*rest) { rest.first * 10 }
          event :x, to: ["https://x"]
        end
      end.not_to raise_error
    end

    it "rejects a user_agent callable that cannot be invoked with zero arguments" do
      # Deliver resolves a callable user_agent with NO arguments (documented zero-arg contract) —
      # one requiring an argument would otherwise boot successfully and raise ArgumentError on
      # every real delivery attempt.
      expect do
        Axn::Webhooks.outbound do
          sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('s')}"
          user_agent ->(deploy) { deploy }
          event :x, to: ["https://x"]
        end
      end.to raise_error(ArgumentError, /user_agent got invalid value.*callable must accept zero arguments/)
    end

    it "accepts a plain String user_agent" do
      expect do
        Axn::Webhooks.outbound do
          sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('s')}"
          user_agent "my-app"
          event :x, to: ["https://x"]
        end
      end.not_to raise_error
    end

    describe "headers (PRO-3214)" do
      it "rejects a non-callable headers value" do
        expect do
          Axn::Webhooks.outbound do
            sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('s')}"
            headers("not-callable")
            event :x, to: ["https://x"]
          end
        end.to raise_error(ArgumentError, /headers got invalid value.*must be a callable/)
      end

      it "rejects a headers callable needing more than the subscriber" do
        expect do
          Axn::Webhooks.outbound do
            sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('s')}"
            headers ->(a, b) { { "x" => "#{a}#{b}" } }
            event :x, to: ["https://x"]
          end
        end.to raise_error(ArgumentError, /headers got invalid value.*must be a callable/)
      end

      it "accepts a zero-arity headers callable" do
        expect do
          Axn::Webhooks.outbound do
            sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('s')}"
            headers -> { { "x-static" => "1" } }
            event :x, to: ["https://x"]
          end
        end.not_to raise_error
      end

      it "accepts a one-arity (subscriber-aware) headers callable" do
        expect do
          Axn::Webhooks.outbound do
            sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('s')}"
            headers ->(sub) { { "x-subscriber" => sub&.id.to_s } }
            event :x, to: ["https://x"]
          end
        end.not_to raise_error
      end

      it "accepts a block form" do
        expect do
          Axn::Webhooks.outbound do
            sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('s')}"
            headers { |sub| { "x-subscriber" => sub&.id.to_s } }
            event :x, to: ["https://x"]
          end
        end.not_to raise_error
      end
    end

    it "rejects a `to:` that is neither an Array nor callable" do
      expect do
        Axn::Webhooks.outbound do
          sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('s')}"
          event :x, to: { url: "https://x" }
        end
      end.to raise_error(ArgumentError, /`to:` must be an Array of URLs or a callable/)
    end

    it "rejects a non-http(s) static URL" do
      expect do
        Axn::Webhooks.outbound do
          sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('s')}"
          event :x, to: ["file:///etc/passwd"]
        end
      end.to raise_error(ArgumentError, /must be http\(s\)/)
    end

    it "rejects an unparseable static URL" do
      expect do
        Axn::Webhooks.outbound do
          sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('s')}"
          event :x, to: ["http://[::not-a-host"]
        end
      end.to raise_error(ArgumentError, /is not a valid URL/)
    end

    it "rejects a static URL with an http(s) scheme but no host" do
      # URI.parse accepts these as scheme=https with a nil/empty host; the built-in Transport would
      # only fail constructing/sending the request at delivery time, so boot-time validation must
      # check the host explicitly rather than trusting the scheme alone.
      %w[https:foo https: https:///hook].each do |url|
        expect do
          Axn::Webhooks.outbound do
            sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('s')}"
            event :x, to: [url]
          end
        end.to raise_error(ArgumentError, /must be http\(s\)/), "expected #{url.inspect} to be rejected"
      end
    end

    it "rejects a non-String static URL (e.g. a URI object) instead of letting it through via #to_s" do
      # #to_s alone would parse fine here, but the ORIGINAL non-String object stays in `@events` and
      # is later handed to `Deliver` as `url:` (`expects :url, type: String`) — accepted at boot,
      # rejected at emission/delivery time instead.
      expect do
        Axn::Webhooks.outbound do
          sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('s')}"
          event :x, to: [URI("https://example.com/hook")]
        end
      end.to raise_error(ArgumentError, /must be a String/)
    end

    it "does not eagerly validate a callable `to:` (resolved per emission, not at boot)" do
      expect do
        Axn::Webhooks.outbound do
          sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('s')}"
          event :x, to: ->(_event) { ["not-a-url"] }
        end
      end.not_to raise_error
    end
  end

  describe "Config#transport" do
    it "defaults to Outbound::Transport when the block does not call `transport`" do
      Axn::Webhooks.outbound do
        sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('s')}"
        event :lead_signed, to: ["https://x"]
      end
      expect(Axn::Webhooks::Outbound.config.transport).to eq(Axn::Webhooks::Outbound::Transport)
    end

    it "uses the object passed to `transport` when the block declares one" do
      custom_transport = Object.new
      Axn::Webhooks.outbound do
        sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('s')}"
        transport custom_transport
        event :lead_signed, to: ["https://x"]
      end
      expect(Axn::Webhooks::Outbound.config.transport).to equal(custom_transport)
    end
  end
end
