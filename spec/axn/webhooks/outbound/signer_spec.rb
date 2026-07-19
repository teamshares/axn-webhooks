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

  it "raises on an unknown strategy" do
    expect { described_class.build(strategy: :nope, opts: {}, block: nil) }
      .to raise_error(Axn::Webhooks::Error, /unknown sign strategy/)
  end
end
