# frozen_string_literal: true

require "openssl"
require "base64"

RSpec.describe "verify :standard_webhooks strategy" do
  after { Axn::Webhooks::Inbound.reset! }

  let(:key)    { "raw-signing-key" }
  let(:whsec)  { "whsec_#{Base64.strict_encode64(key)}" }
  let(:id)     { "msg_123" }
  let(:body)   { '{"hello":"world"}' }

  def sign(id:, timestamp:, body:, key:)
    Base64.strict_encode64(OpenSSL::HMAC.digest("SHA256", key, "#{id}.#{timestamp}.#{body}"))
  end

  def request(headers:, body: '{"hello":"world"}')
    Axn::Webhooks::Request.new(raw_body: body, headers:)
  end

  it "verifies a v1, candidate over id.timestamp.body (whsec_ secret)" do
    secret = whsec  # Capture let-value as local variable for closure
    ts = Time.now.to_i.to_s
    headers = {
      "webhook-id" => id,
      "webhook-timestamp" => ts,
      "webhook-signature" => "v1,#{sign(id:, timestamp: ts, body:, key:)}",
    }
    Axn::Webhooks.inbound(:codat) { verify :standard_webhooks, secret: }
    expect(Axn::Webhooks::Inbound[:codat].verify(request(headers:))).to be_ok
  end

  it "passes if ANY space-separated v1 candidate matches (key rotation) and this proves the v1, comma isn't split naively" do
    secret = whsec  # Capture let-value as local variable for closure
    ts = Time.now.to_i.to_s
    good = sign(id:, timestamp: ts, body:, key:)
    headers = {
      "webhook-id" => id,
      "webhook-timestamp" => ts,
      "webhook-signature" => "v1,AAAA v1,#{good}",
    }
    Axn::Webhooks.inbound(:codat) { verify :standard_webhooks, secret: }
    expect(Axn::Webhooks::Inbound[:codat].verify(request(headers:))).to be_ok
  end

  it "rejects a tampered signature" do
    secret = whsec  # Capture let-value as local variable for closure
    ts = Time.now.to_i.to_s
    headers = {
      "webhook-id" => id,
      "webhook-timestamp" => ts,
      "webhook-signature" => "v1,#{Base64.strict_encode64('nope-nope-nope-nope-nope-nope!!')}",
    }
    Axn::Webhooks.inbound(:codat) { verify :standard_webhooks, secret: }
    expect(Axn::Webhooks::Inbound[:codat].verify(request(headers:))).not_to be_ok
  end

  it "rejects a timestamp outside the tolerance window" do
    secret = whsec  # Capture let-value as local variable for closure
    ts = (Time.now - 10_000).to_i.to_s
    headers = {
      "webhook-id" => id,
      "webhook-timestamp" => ts,
      "webhook-signature" => "v1,#{sign(id:, timestamp: ts, body:, key:)}",
    }
    Axn::Webhooks.inbound(:codat) { verify :standard_webhooks, secret:, tolerance: 300 }
    expect(Axn::Webhooks::Inbound[:codat].verify(request(headers:))).not_to be_ok
  end

  describe Axn::Webhooks::Verifiers::StandardWebhooks do
    it "decodes a whsec_ secret to its raw bytes" do
      expect(described_class.decode_secret("whsec_#{Base64.strict_encode64('abc')}")).to eq("abc")
    end

    it "extracts only v1, candidates, stripped to the bare signature" do
      expect(described_class.extract_v1("v1,AAA v2,BBB v1,CCC")).to eq(%w[AAA CCC])
    end
  end
end
