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

  # PRO-3141 — the preset delegates to Signature, so it separates the causes for free.
  it "names the cause: :replay_window for a stale request, :signature_mismatch for a bad one" do
    secret = whsec # Capture let-value as local variable for closure
    Axn::Webhooks.inbound(:codat) { verify :standard_webhooks, secret:, tolerance: 300 }

    stale_ts = (Time.now - 10_000).to_i.to_s
    stale = request(headers: { "webhook-id" => id, "webhook-timestamp" => stale_ts,
                               "webhook-signature" => "v1,#{sign(id:, timestamp: stale_ts, body:, key:)}" })
    expect(Axn::Webhooks::Inbound[:codat].verify(stale).reason).to eq(:replay_window)

    fresh_ts = Time.now.to_i.to_s
    tampered = request(headers: { "webhook-id" => id, "webhook-timestamp" => fresh_ts,
                                  "webhook-signature" => "v1,#{Base64.strict_encode64('nope-nope-nope-nope-nope-nope!!')}" })
    expect(Axn::Webhooks::Inbound[:codat].verify(tampered).reason).to eq(:signature_mismatch)
  end

  # A LITERAL secret is knowable at declaration, so the whsec_ format is checked there — symmetric
  # with outbound `sign :standard_webhooks`. Without it, a raw secret fails only at REQUEST time,
  # and does so two different ways depending on whether it happens to be valid Base64: it either
  # raises (a reported verifier crash) or — for a 32-char hex secret, a very common shape — decodes
  # SILENTLY to the wrong key, producing a quiet :signature_mismatch with nothing reported anywhere,
  # indistinguishable from a rotated key. Every request 401s either way.
  describe "literal secret validation at declaration" do
    def declare(secret)
      Axn::Webhooks::Inbound.reset!
      Axn::Webhooks.inbound(:v) { verify :standard_webhooks, secret: }
    end

    it "rejects a raw secret that isn't valid Base64" do
      expect { declare("sk_live_abc123") }.to raise_error(ArgumentError, /must be a whsec_<base64> value/)
    end

    # The dangerous one: valid Base64, so it would decode silently to the wrong key at request time.
    it "rejects a raw 32-char hex secret, which IS valid Base64 and would decode silently" do
      expect { declare("deadbeefdeadbeefdeadbeefdeadbeef") }
        .to raise_error(ArgumentError, /must be a whsec_<base64> value/)
    end

    it "rejects a whsec_ secret whose Base64 body doesn't decode" do
      expect { declare("whsec_!!!not-base64!!!") }.to raise_error(ArgumentError, /must be a whsec_<base64> value/)
    end

    it "names the shape without leaking the secret's bytes" do
      expect { declare("hunter2hunter2") }.to raise_error(ArgumentError) do |e|
        expect(e.message).to include("14-char String")
        expect(e.message).not_to include("hunter2")
      end
    end

    it "accepts a valid literal whsec_ secret" do
      expect { declare("whsec_#{Base64.strict_encode64('k')}") }.not_to raise_error
    end

    # A CALLABLE (or Resolver) secret is resolved per REQUEST — it may read a secret store or an
    # env var set after boot — so its value stays a request-time concern, exactly as outbound's is.
    it "does not resolve a callable secret at declaration" do
      expect { declare(-> { raise "should not be called at boot" }) }.not_to raise_error
    end
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
