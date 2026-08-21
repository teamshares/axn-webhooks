# frozen_string_literal: true

RSpec.describe Axn::Webhooks::Outbound::Signer do
  def build(**opts)
    described_class.build(strategy: :hmac, opts:, block: nil)
  end

  describe "the minimal form" do
    it "emits one hex sha256 header over the raw body" do
      headers = build(secret: "s3kr1t", header: "X-Signature").call(id: "msg_1", timestamp: 1_755_740_000, body: "{}")

      expected = Axn::Webhooks::Signature.compute(secret: "s3kr1t", payload: "{}", digest: :sha256, encoding: :hex)
      expect(headers).to eq("X-Signature" => expected)
    end

    it "resolves a callable secret fresh on every call" do
      secrets = %w[first second]
      signer = build(secret: -> { secrets.shift }, header: "X-Signature")

      first = signer.call(id: "m", timestamp: 1, body: "b")
      second = signer.call(id: "m", timestamp: 1, body: "b")

      expect(first).not_to eq(second)
    end

    it "honors digest, encoding and prefix" do
      headers = build(secret: "s", header: "X-Sig", digest: :sha1, encoding: :base64, prefix: "v1=")
                .call(id: "m", timestamp: 1, body: "b")

      expected = Axn::Webhooks::Signature.compute(secret: "s", payload: "b", digest: :sha1, encoding: :base64)
      expect(headers["X-Sig"]).to eq("v1=#{expected}")
    end
  end

  describe "the timestamped form" do
    it "renders the template and emits the timestamp header alongside the signature" do
      headers = build(
        secret: "s", header: "X-Signature", timestamp_header: "X-Timestamp",
        signing_string: "v0:{timestamp}:{body}", prefix: "v0="
      ).call(id: "m", timestamp: 1_755_740_000, body: '{"a":1}')

      expected = Axn::Webhooks::Signature.compute(
        secret: "s", payload: 'v0:1755740000:{"a":1}', digest: :sha256, encoding: :hex,
      )
      expect(headers).to eq("X-Signature" => "v0=#{expected}", "X-Timestamp" => "1755740000")
    end
  end

  describe "boot-time validation" do
    it "requires a header to emit — omitting it is Ruby's own missing-keyword error" do
      expect { build(secret: "s") }.to raise_error(ArgumentError, /missing keyword: :header/)
    end

    it "rejects a header explicitly declared as nil or blank (e.g. an unset ENV var)" do
      expect { build(secret: "s", header: nil) }.to raise_error(ArgumentError, /`header:` must be a non-empty String/)
      expect { build(secret: "s", header: "  ") }.to raise_error(ArgumentError, /`header:` must be a non-empty String/)
    end

    it "rejects a non-String header name, which would reach Net::HTTP as a garbage key" do
      # `false.to_s` is "false" and `123.to_s` is "123", so a `to_s`-based blank check accepts both
      # and publishes a signer that emits `{ false => "<sig>" }` (Codex review).
      expect { build(secret: "s", header: false) }.to raise_error(ArgumentError, /`header:` must be a non-empty String/)
      expect { build(secret: "s", header: 123) }.to raise_error(ArgumentError, /`header:` must be a non-empty String/)
    end

    it "rejects a non-String timestamp_header, which would sign a timestamp it never emits" do
      # `timestamp_header: false` passes a `to_s` check and satisfies the {timestamp}-needs-a-header
      # rule, but `call`'s `if @timestamp_header` is falsey — so the receiver gets a timestamp-bound
      # signature with no timestamp to reconstruct it from (Codex review).
      expect { build(secret: "s", header: "X-Sig", timestamp_header: false, signing_string: "{timestamp}:{body}") }
        .to raise_error(ArgumentError, /`timestamp_header:` must be a non-empty String/)
    end

    it "rejects a timestamp_header colliding with the signature header, case-insensitively" do
      # The timestamp assignment lands second and OVERWRITES the signature, so every delivery ships
      # unverifiable — silently. HTTP header names are case-insensitive (Codex review).
      expect { build(secret: "s", header: "X-Sig", timestamp_header: "X-Sig") }
        .to raise_error(ArgumentError, /same header name/)
      expect { build(secret: "s", header: "X-Sig", timestamp_header: "x-sig") }
        .to raise_error(ArgumentError, /same header name/)
    end

    it "rejects an unknown template placeholder" do
      expect { build(secret: "s", header: "X-Sig", signing_string: "{nope}:{body}") }
        .to raise_error(ArgumentError, /unknown or malformed placeholder.*\{nope\}/)
    end

    it "rejects a MALFORMED placeholder, which a \\w+ scan silently treats as literal text" do
      # `{time-stamp}` and `{timestamp` both matched nothing, so declaration succeeded and `render`
      # signed the brace text literally — a signature the receiver cannot reconstruct, from an
      # option whose whole selling point is declaration-time validation (Codex review).
      expect { build(secret: "s", header: "X-Sig", timestamp_header: "X-Ts", signing_string: "{time-stamp}:{body}") }
        .to raise_error(ArgumentError, /unknown or malformed placeholder/)
      expect { build(secret: "s", header: "X-Sig", timestamp_header: "X-Ts", signing_string: "{timestamp:{body}") }
        .to raise_error(ArgumentError, /unknown or malformed placeholder/)
      expect { build(secret: "s", header: "X-Sig", signing_string: "body}") }
        .to raise_error(ArgumentError, /unknown or malformed placeholder/)
    end

    it "rejects {timestamp} with no timestamp_header to carry it" do
      expect { build(secret: "s", header: "X-Sig", signing_string: "{timestamp}:{body}") }
        .to raise_error(ArgumentError, /timestamp_header/)
    end

    it "rejects a blank timestamp_header, which would emit a header with an empty name" do
      expect { build(secret: "s", header: "X-Sig", timestamp_header: "") }
        .to raise_error(ArgumentError, /`timestamp_header:`/)
    end

    it "treats a blank timestamp_header as absent when {timestamp} is referenced" do
      expect { build(secret: "s", header: "X-Sig", signing_string: "{timestamp}:{body}", timestamp_header: "") }
        .to raise_error(ArgumentError, /`timestamp_header:`/)
    end

    it "rejects header names that are not valid HTTP field tokens" do
      # Net::HTTP stores whatever key it is handed and serializes it into the header line, so a
      # space produces a malformed request and a newline can append wire headers (Codex review).
      expect { build(secret: "s", header: "X Signature") }
        .to raise_error(ArgumentError, /valid HTTP header name/)
      expect { build(secret: "s", header: "X-Sig", timestamp_header: "X\nInjected: evil") }
        .to raise_error(ArgumentError, /valid HTTP header name/)
      expect { build(secret: "s", header: "X-Sig:") }
        .to raise_error(ArgumentError, /valid HTTP header name/)
    end

    it "accepts the punctuation RFC 7230 allows in a field name" do
      expect { build(secret: "s", header: "X-Custom_Sig.v1") }.not_to raise_error
    end

    it "rejects a header name that collides with one Deliver manages, case-insensitively" do
      # Deliver merges its own lowercase content-type/user-agent AFTER the signer's headers. Ruby
      # Hash keys are case-SENSITIVE so both survive the merge, but Net::HTTP is case-INSENSITIVE
      # and the later assignment wins — silently replacing the signature (Codex review).
      expect { build(secret: "s", header: "Content-Type") }
        .to raise_error(ArgumentError, /Deliver sets itself/)
      expect { build(secret: "s", header: "X-Sig", timestamp_header: "User-Agent") }
        .to raise_error(ArgumentError, /Deliver sets itself/)
    end

    it "rejects an unsupported digest at declaration time, not on every delivery" do
      expect { build(secret: "s", header: "X-Sig", digest: :sha265) }
        .to raise_error(ArgumentError, /unsupported digest/)
    end

    it "rejects an unsupported encoding at declaration time, not on every delivery" do
      expect { build(secret: "s", header: "X-Sig", encoding: :base64_url) }
        .to raise_error(ArgumentError, /unsupported encoding/)
    end

    it "rejects a secret callable that requires an argument" do
      expect { build(secret: ->(x) { x }, header: "X-Sig") }
        .to raise_error(ArgumentError, /must accept zero arguments/)
    end
  end

  describe "runtime secret validation" do
    it "refuses to sign with a blank secret, without leaking it" do
      signer = build(secret: -> { "" }, header: "X-Sig")

      expect { signer.call(id: "m", timestamp: 1, body: "b") }
        .to raise_error(Axn::Webhooks::Error, /secret must be a non-empty String/)
    end

    it "never interpolates the secret into the error message" do
      signer = build(secret: -> { :not_a_string }, header: "X-Sig")

      expect { signer.call(id: "m", timestamp: 1, body: "b") }
        .to raise_error(Axn::Webhooks::Error) { |e| expect(e.message).not_to include("not_a_string") }
    end
  end
end
