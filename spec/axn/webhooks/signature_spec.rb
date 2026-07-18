# frozen_string_literal: true

require "openssl"
require "base64"

RSpec.describe Axn::Webhooks::Signature do
  # RFC 4231 Test Case 2 — a published, independent HMAC-SHA256 vector.
  let(:secret)  { "Jefe" }
  let(:payload) { "what do ya want for nothing?" }
  let(:hex)     { "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843" }

  describe ".compute" do
    it "produces the RFC 4231 hex vector for sha256" do
      expect(described_class.compute(secret:, payload:, digest: :sha256, encoding: :hex)).to eq(hex)
    end

    it "encodes as standard and url-safe base64 of the same digest bytes" do
      raw = OpenSSL::HMAC.digest("SHA256", secret, payload)
      expect(described_class.compute(secret:, payload:, encoding: :base64)).to eq(Base64.strict_encode64(raw))
      expect(described_class.compute(secret:, payload:, encoding: :base64_urlsafe)).to eq(Base64.urlsafe_encode64(raw))
    end

    it "supports sha1 and md5 digests" do
      expect(described_class.compute(secret:, payload:, digest: :sha1))
        .to eq(OpenSSL::HMAC.hexdigest("SHA1", secret, payload))
      expect(described_class.compute(secret:, payload:, digest: :md5))
        .to eq(OpenSSL::HMAC.hexdigest("MD5", secret, payload))
    end
  end

  describe ".hmac" do
    it "accepts a matching signature" do
      expect(described_class.hmac(secret:, payload:, signature: hex)).to be(true)
    end

    it "rejects a tampered signature" do
      bad = hex.sub(/.\z/, hex[-1] == "0" ? "1" : "0")
      expect(described_class.hmac(secret:, payload:, signature: bad)).to be(false)
    end

    it "rejects a wrong secret" do
      expect(described_class.hmac(secret: "wrong", payload:, signature: hex)).to be(false)
    end

    it "rejects nil / empty signatures without raising" do
      expect(described_class.hmac(secret:, payload:, signature: nil)).to be(false)
      expect(described_class.hmac(secret:, payload:, signature: "")).to be(false)
    end

    it "strips a prefix before comparing (Slack-style v0=)" do
      expect(described_class.hmac(secret:, payload:, signature: "v0=#{hex}", prefix: "v0=")).to be(true)
      expect(described_class.hmac(secret:, payload:, signature: hex, prefix: "v0=")).to be(false)
    end

    it "passes if ANY candidate in a multi-signature header matches (key rotation)" do
      expect(described_class.hmac(secret:, payload:, signature: "deadbeef #{hex}")).to be(true)
      expect(described_class.hmac(secret:, payload:, signature: "deadbeef,#{hex}")).to be(true)
      expect(described_class.hmac(secret:, payload:, signature: "deadbeef cafebabe")).to be(false)
    end

    it "verifies a base64-urlsafe signature (Merge-style)" do
      raw = OpenSSL::HMAC.digest("SHA256", secret, payload)
      sig = Base64.urlsafe_encode64(raw)
      expect(described_class.hmac(secret:, payload:, signature: sig, encoding: :base64_urlsafe)).to be(true)
    end
  end

  describe ".secure_compare" do
    it "is true only for identical strings" do
      expect(described_class.secure_compare("abc", "abc")).to be(true)
      expect(described_class.secure_compare("abc", "abd")).to be(false)
    end

    it "is false (never raises) for length mismatch or nil" do
      expect(described_class.secure_compare("abc", "abcd")).to be(false)
      expect(described_class.secure_compare(nil, "abc")).to be(false)
      expect(described_class.secure_compare("abc", nil)).to be(false)
    end
  end

  describe "replay window" do
    let(:secret)  { "Jefe" }
    let(:payload) { "what do ya want for nothing?" }
    let(:hex)     { "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843" }
    let(:now)     { Time.at(1_700_000_000) }

    it "accepts a signature whose timestamp is within tolerance" do
      ts = (now - 60).to_i
      expect(described_class.hmac(secret:, payload:, signature: hex, timestamp: ts, tolerance: 300, now:)).to be(true)
    end

    it "rejects a signature whose timestamp is outside tolerance (replay)" do
      ts = (now - 600).to_i
      expect(described_class.hmac(secret:, payload:, signature: hex, timestamp: ts, tolerance: 300, now:)).to be(false)
    end

    it "rejects future timestamps beyond tolerance (bidirectional)" do
      ts = (now + 600).to_i
      expect(described_class.hmac(secret:, payload:, signature: hex, timestamp: ts, tolerance: 300, now:)).to be(false)
    end

    it "rejects a missing or unparseable timestamp when tolerance is set" do
      expect(described_class.hmac(secret:, payload:, signature: hex, timestamp: nil, tolerance: 300, now:)).to be(false)
      expect(described_class.hmac(secret:, payload:, signature: hex, timestamp: "not-a-time", tolerance: 300, now:)).to be(false)
    end

    it "accepts a String epoch and a Time" do
      expect(described_class.within_tolerance?(timestamp: (now - 10).to_i.to_s, tolerance: 300, now:)).to be(true)
      expect(described_class.within_tolerance?(timestamp: now - 10, tolerance: 300, now:)).to be(true)
    end

    it "ignores the window entirely when tolerance is nil" do
      expect(described_class.hmac(secret:, payload:, signature: hex, timestamp: nil, tolerance: nil, now:)).to be(true)
    end

    it "pins the inclusive boundary: exactly at tolerance is accepted" do
      ts = (now - 300).to_i
      expect(described_class.hmac(secret:, payload:, signature: hex, timestamp: ts, tolerance: 300, now:)).to be(true)
    end

    it "rejects timestamps just outside the inclusive boundary" do
      ts = (now - 301).to_i
      expect(described_class.hmac(secret:, payload:, signature: hex, timestamp: ts, tolerance: 300, now:)).to be(false)
    end
  end
end
