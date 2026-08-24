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

    # SECURITY: `secret: nil` (an unset ENV var is the obvious way in) reached request time, where
    # `decode_secret` coerced it with #to_s and Base64-decoded "" into an EMPTY HMAC key — so anyone
    # who knew that could forge a signature that verifies. Same fail-closed-on-blank concern
    # `verify :basic_auth` already handles. Exempt CALLABLES from the boot check, not non-Strings.
    it "rejects a nil secret rather than HMACing with an empty key" do
      expect { declare(nil) }.to raise_error(ArgumentError, /must be a whsec_<base64> value/)
    end

    it "rejects non-String, non-callable literals (Integer, Symbol)" do
      expect { declare(42) }.to raise_error(ArgumentError, /must be a whsec_<base64> value/)
      expect { declare(:a_symbol) }.to raise_error(ArgumentError, /must be a whsec_<base64> value/)
    end

    it "rejects an empty-String secret" do
      expect { declare("") }.to raise_error(ArgumentError, /must be a whsec_<base64> value/)
    end

    # Regression guard for the bypass itself, not just the declaration: a nil secret must never
    # leave an endpoint that accepts a signature computed with an empty key.
    it "leaves no endpoint that would verify a signature forged with an empty key" do
      expect { declare(nil) }.to raise_error(ArgumentError)
      expect { Axn::Webhooks::Inbound[:v] }.to raise_error(KeyError)
    end

    # A Resolver (e.g. `header("X-Secret")`) responds to #call, so it stays a request-time concern
    # exactly like a lambda.
    it "does not validate a Resolver secret at declaration" do
      expect { declare(Axn::Webhooks::Resolvers.header("X-Secret")) }.not_to raise_error
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

  # SECURITY, round-4 finding: exempting callables from the DECLARATION check left the identical
  # empty-key bypass open at REQUEST time. A lambda reading an unset ENV var, or a `header(...)`
  # resolver on an absent header, resolves to nil — and `decode_secret` coerced that with #to_s,
  # Base64-decoding "" into an EMPTY HMAC key. Anyone who knows the credential is missing could sign
  # with the empty key and verify. The literal fix did not cover this; the resolved value must be
  # validated too, on every request.
  describe "resolved (callable/Resolver) secret validation at request time" do
    def forge_with_empty_key
      id = "msg_1"
      ts = Time.now.to_i.to_s
      body = "{}"
      sig = Base64.strict_encode64(OpenSSL::HMAC.digest("sha256", "", "#{id}.#{ts}.#{body}"))
      Axn::Webhooks::Request.new(
        raw_body: body,
        headers: { "webhook-id" => id, "webhook-timestamp" => ts, "webhook-signature" => "v1,#{sig}" },
      )
    end

    def endpoint_with(secret)
      Axn::Webhooks::Inbound.reset!
      Axn::Webhooks.inbound(:v) { verify :standard_webhooks, secret: }
      Axn::Webhooks::Inbound[:v]
    end

    it "does not verify a signature forged with the empty key when a lambda resolves to nil" do
      expect(endpoint_with(-> {}).verify(forge_with_empty_key)).not_to be_ok
    end

    it "does not verify a signature forged with the empty key when a Resolver finds no header" do
      resolver = Axn::Webhooks::Resolvers.header("X-Absent-Secret")
      expect(endpoint_with(resolver).verify(forge_with_empty_key)).not_to be_ok
    end

    it "surfaces a missing resolved secret LOUDLY (misconfiguration, not a quiet mismatch)" do
      result = endpoint_with(-> {}).verify(forge_with_empty_key)
      expect(result.outcome).to be_exception
      expect(result.exception).to be_a(Axn::Webhooks::Error)
      expect(result.exception.message).to match(/must be a whsec_<base64> value/)
    end

    it "rejects a resolved secret that is present but missing the whsec_ prefix" do
      result = endpoint_with(-> { "deadbeefdeadbeefdeadbeefdeadbeef" }).verify(forge_with_empty_key)
      expect(result).not_to be_ok
    end

    it "never leaks the resolved secret's bytes into the error" do
      result = endpoint_with(-> { "hunter2hunter2" }).verify(forge_with_empty_key)
      expect(result.exception.message).to include("14-char String").and(satisfy { |m| !m.include?("hunter2") })
    end

    it "still verifies normally when the callable resolves to a valid whsec_ secret" do
      key = "topsecret"
      endpoint = endpoint_with(-> { "whsec_#{Base64.strict_encode64(key)}" })
      id = "msg_1"
      ts = Time.now.to_i.to_s
      body = "{}"
      sig = Base64.strict_encode64(OpenSSL::HMAC.digest("sha256", key, "#{id}.#{ts}.#{body}"))
      request = Axn::Webhooks::Request.new(
        raw_body: body,
        headers: { "webhook-id" => id, "webhook-timestamp" => ts, "webhook-signature" => "v1,#{sig}" },
      )
      expect(endpoint.verify(request)).to be_ok
    end
  end

  # The root cause both bypasses shared: #to_s turned nil into "" and "" is valid Base64.
  describe ".decode_secret hardening" do
    it "refuses to coerce a non-String into an empty key" do
      expect { Axn::Webhooks::Verifiers::StandardWebhooks.decode_secret(nil) }.to raise_error(ArgumentError)
    end

    it "still decodes a valid whsec_ String" do
      expect(Axn::Webhooks::Verifiers::StandardWebhooks.decode_secret("whsec_#{Base64.strict_encode64('abc')}")).to eq("abc")
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
