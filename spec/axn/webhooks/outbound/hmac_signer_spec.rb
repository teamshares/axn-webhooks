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
      expect { build(secret: "s", header: nil) }.to raise_error(ArgumentError, /requires a `header:`/)
      expect { build(secret: "s", header: "") }.to raise_error(ArgumentError, /requires a `header:`/)
    end

    it "rejects an unknown template placeholder" do
      expect { build(secret: "s", header: "X-Sig", signing_string: "{nope}:{body}") }
        .to raise_error(ArgumentError, /unknown placeholder.*\{nope\}/)
    end

    it "rejects {timestamp} with no timestamp_header to carry it" do
      expect { build(secret: "s", header: "X-Sig", signing_string: "{timestamp}:{body}") }
        .to raise_error(ArgumentError, /timestamp_header/)
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
