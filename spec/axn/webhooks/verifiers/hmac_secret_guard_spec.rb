# frozen_string_literal: true

RSpec.describe "verify :hmac secret guard" do
  # SECURITY: "" is a LEGAL HMAC key, so an empty secret does not fail — it makes the expected
  # signature a value any stranger can compute. `nil` happened to fail closed (OpenSSL raises
  # TypeError), which is exactly why testing only nil missed this. The attacker-controlled shape is
  # a per-request resolver whose lookup misses and returns "" for a tenant the ATTACKER names.
  def endpoint(secret)
    Axn::Webhooks::Inbound.reset!
    Axn::Webhooks.inbound(:v) { verify :hmac, secret:, signature: header("X-Sig") }
    Axn::Webhooks::Inbound[:v]
  end

  def request_signed_with(key, body: '{"a":1}', headers: {})
    Axn::Webhooks::Request.new(
      raw_body: body,
      headers: { "X-Sig" => OpenSSL::HMAC.hexdigest("sha256", key, body) }.merge(headers),
    )
  end

  it "does not authenticate a signature forged with the empty key when the secret is a blank literal" do
    expect { endpoint("") }.to raise_error(ArgumentError, /non-empty String/)
  end

  it "does not authenticate a signature forged with the empty key when a callable resolves to blank" do
    result = endpoint(-> { "" }).verify(request_signed_with(""))
    expect(result).not_to be_ok
    expect(result.exception).to be_a(Axn::Webhooks::Error)
  end

  it "does not authenticate when a per-request resolver misses for an attacker-chosen key" do
    tenants = { "acme" => "acme-key" }
    endpoint = endpoint(->(r) { tenants[r.header("X-Tenant")].to_s })

    forged = request_signed_with("", headers: { "X-Tenant" => "attacker-chosen" })
    expect(endpoint.verify(forged)).not_to be_ok
  end

  it "rejects a nil resolved secret loudly rather than via OpenSSL's TypeError" do
    result = endpoint(-> {}).verify(request_signed_with(""))
    expect(result).not_to be_ok
    expect(result.exception).to be_a(Axn::Webhooks::Error)
  end

  it "rejects a non-String resolved secret" do
    expect(endpoint(-> { 42 }).verify(request_signed_with(""))).not_to be_ok
    expect(endpoint(-> { false }).verify(request_signed_with(""))).not_to be_ok
  end

  it "never leaks the secret's bytes in the error" do
    result = endpoint(-> { 42 }).verify(request_signed_with(""))
    expect(result.exception.message).to include("Integer").and(satisfy { |m| !m.include?("42") })
  end

  # Positive controls: the guard must not break real verification.
  it "still verifies a correct signature" do
    expect(endpoint("real-secret").verify(request_signed_with("real-secret"))).to be_ok
  end

  it "still rejects a wrong signature as a quiet mismatch, not an exception" do
    result = endpoint("real-secret").verify(request_signed_with("other-secret"))
    expect(result).not_to be_ok
    expect(result.reason).to eq(:signature_mismatch)
    expect(result.outcome).not_to be_exception
  end
end
