# frozen_string_literal: true

require "base64"

RSpec.describe Axn::Webhooks::Outbound::Signer do
  # whsec_ + base64("secret") so decode_secret yields the raw "secret" bytes.
  let(:secret) { "whsec_#{Base64.strict_encode64('secret')}" }

  describe ":standard_webhooks strategy" do
    subject(:signer) { described_class.build(strategy: :standard_webhooks, opts: { secret: }, block: nil) }

    it "produces webhook-id / webhook-timestamp / v1 signature headers" do
      headers = signer.call(id: "msg_1", timestamp: 1_700_000_000, body: '{"a":1}')

      expect(headers["webhook-id"]).to eq("msg_1")
      expect(headers["webhook-timestamp"]).to eq("1700000000")
      expect(headers["webhook-signature"]).to start_with("v1,")
    end

    it "signs id.timestamp.body with the decoded secret so the inbound verifier accepts it" do
      id = "msg_1"
      ts = 1_700_000_000
      body = '{"a":1}'
      headers = signer.call(id:, timestamp: ts, body:)

      expected = Axn::Webhooks::Signature.compute(
        secret: "secret", payload: "#{id}.#{ts}.#{body}", digest: :sha256, encoding: :base64,
      )
      expect(headers["webhook-signature"]).to eq("v1,#{expected}")
    end

    it "resolves a callable secret per call rather than freezing it at build time" do
      calls = 0
      resolver = lambda do
        calls += 1
        secret
      end
      signer = described_class.build(strategy: :standard_webhooks, opts: { secret: resolver }, block: nil)

      2.times { signer.call(id: "msg_1", timestamp: 1_700_000_000, body: "{}") }

      expect(calls).to eq(2)
    end

    # The broad `rescue ArgumentError` around the whole method previously caught an ArgumentError
    # raised by the resolver ITSELF (e.g. a secret-store wrapper rejecting a bad response) and
    # rewrote it as the generic invalid-secret message, discarding the resolver's own diagnostic —
    # only Base64.strict_decode64's own ArgumentError (invalid base64) is meant to be caught here
    # (Codex P2 finding).
    it "preserves an exception raised by the secret resolver itself, rather than rewriting it as an invalid-secret error" do
      resolver = -> { raise ArgumentError, "secret store returned an invalid response" }
      signer = described_class.build(strategy: :standard_webhooks, opts: { secret: resolver }, block: nil)

      expect { signer.call(id: "msg_1", timestamp: 1_700_000_000, body: "{}") }
        .to raise_error(ArgumentError, "secret store returned an invalid response")
    end

    it "raises a named error when the resolved secret isn't a decodable whsec_ value" do
      signer = described_class.build(strategy: :standard_webhooks, opts: { secret: "not-whsec" }, block: nil)

      expect { signer.call(id: "msg_1", timestamp: 1_700_000_000, body: "{}") }
        .to raise_error(Axn::Webhooks::Error, /sign :standard_webhooks secret must be a whsec_<base64> value/)
    end

    it "raises rather than silently signing with an empty key when the secret is blank" do
      signer = described_class.build(strategy: :standard_webhooks, opts: { secret: "" }, block: nil)

      expect { signer.call(id: "msg_1", timestamp: 1_700_000_000, body: "{}") }
        .to raise_error(Axn::Webhooks::Error, /sign :standard_webhooks secret must be a whsec_<base64> value/)
    end

    it "raises rather than silently signing with an empty key when the secret is whsec_ with nothing after it" do
      signer = described_class.build(strategy: :standard_webhooks, opts: { secret: "whsec_" }, block: nil)

      expect { signer.call(id: "msg_1", timestamp: 1_700_000_000, body: "{}") }
        .to raise_error(Axn::Webhooks::Error, /sign :standard_webhooks secret must be a whsec_<base64> value/)
    end

    it "raises on a bare base64 secret missing the required whsec_ prefix" do
      signer = described_class.build(
        strategy: :standard_webhooks, opts: { secret: Base64.strict_encode64("secret") }, block: nil,
      )

      expect { signer.call(id: "msg_1", timestamp: 1_700_000_000, body: "{}") }
        .to raise_error(Axn::Webhooks::Error, /sign :standard_webhooks secret must be a whsec_<base64> value/)
    end

    # The secret can be re-resolved (and re-raise this same error) on every single delivery attempt,
    # so its message must never echo the actual secret bytes into logs/exception reporters — a
    # transiently-malformed value is exactly the case where the reporter is most likely to fire
    # (Codex P1 finding).
    it "never includes the actual secret bytes in the error message" do
      %w[a-live-looking-secret-value whsec_not-valid-base64!!!].each do |bad_secret|
        signer = described_class.build(strategy: :standard_webhooks, opts: { secret: bad_secret }, block: nil)

        expect { signer.call(id: "msg_1", timestamp: 1_700_000_000, body: "{}") }
          .to raise_error(Axn::Webhooks::Error) { |e| expect(e.message).not_to include(bad_secret) }
      end
    end

    it "never includes a non-String secret's value in the error message, only its class" do
      signer = described_class.build(strategy: :standard_webhooks, opts: { secret: 12_345 }, block: nil)

      expect { signer.call(id: "msg_1", timestamp: 1_700_000_000, body: "{}") }
        .to raise_error(Axn::Webhooks::Error, /Integer/)
    end

    # `resolve_secret` calls `@secret.call` with NO arguments (a signing secret is documented as
    # arity-free, unlike a subscriber resolver) — a callable that actually requires one would
    # otherwise boot successfully and raise ArgumentError on every real signing attempt, converted
    # into an Axn::Webhooks::Error `Deliver` can't classify as retryable and left for the async
    # adapter's unbounded exception retries instead of the bounded outbound retry engine (Codex P2
    # finding). Reject at construction (boot) instead.
    it "rejects a secret callable that cannot be invoked with zero arguments" do
      expect do
        described_class.build(strategy: :standard_webhooks, opts: { secret: ->(app) { app.fetch(:secret) } }, block: nil)
      end.to raise_error(ArgumentError, /secret callable must accept zero arguments/)
    end

    it "accepts a secret callable with an optional argument (zero-arg invocation still works)" do
      expect do
        described_class.build(strategy: :standard_webhooks, opts: { secret: ->(_app = nil) { secret } }, block: nil)
      end.not_to raise_error
    end
  end

  describe "custom block" do
    it "uses the block verbatim and returns its header hash" do
      signer = described_class.build(
        strategy: nil, opts: {},
        block: ->(id:, timestamp:, body:) { { "x-sig" => "#{id}:#{timestamp}:#{body.bytesize}" } }
      )
      expect(signer.call(id: "m", timestamp: 5, body: "abc")).to eq("x-sig" => "m:5:3")
    end
  end

  it "raises (ArgumentError: a boot-time declaration mistake, not a runtime condition) on an unknown strategy" do
    expect { described_class.build(strategy: :nope, opts: {}, block: nil) }
      .to raise_error(ArgumentError, /unknown sign strategy/)
  end
end
