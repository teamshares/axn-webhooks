# frozen_string_literal: true

require "openssl"

RSpec.describe "verify :hmac strategy" do
  after { Axn::Webhooks::Inbound.reset! }

  let(:secret) { "shh" }
  let(:body)   { '{"ok":true}' }

  def request(headers:, body: '{"ok":true}')
    Axn::Webhooks::Request.new(raw_body: body, headers:)
  end

  it "verifies a hex sha256 signature over the raw body (Merge/MT-style)" do
    sig = OpenSSL::HMAC.hexdigest("SHA256", secret, body)
    Axn::Webhooks.inbound(:merge) { verify :hmac, secret: "shh", signature: header("X-Sig") }

    expect(Axn::Webhooks::Inbound[:merge].verify(request(headers: { "X-Sig" => sig }))).to be_ok
    expect(Axn::Webhooks::Inbound[:merge].verify(request(headers: { "X-Sig" => "deadbeef" }))).not_to be_ok
  end

  it "supports base64_urlsafe encoding" do
    raw = OpenSSL::HMAC.digest("SHA256", secret, body)
    sig = [raw].pack("m0").tr("+/", "-_") # urlsafe base64, no padding stripped by pack
    Axn::Webhooks.inbound(:merge) do
      verify :hmac, secret: "shh", signature: header("X-Sig"), encoding: :base64_urlsafe
    end
    expect(Axn::Webhooks::Inbound[:merge].verify(request(headers: { "X-Sig" => sig }))).to be_ok
  end

  it "supports a custom signing_string and a v0= prefix (Slack-style)" do
    ts = "1700000000"
    signed = "v0:#{ts}:#{body}"
    sig = "v0=#{OpenSSL::HMAC.hexdigest('SHA256', secret, signed)}"
    Axn::Webhooks.inbound(:slack) do
      verify(
        :hmac,
        secret: "shh",
        signing_string: ->(r) { "v0:#{r.header('X-Ts')}:#{r.raw_body}" },
        signature: header("X-Slack-Sig"),
        prefix: "v0=",
      )
    end
    req = request(headers: { "X-Ts" => ts, "X-Slack-Sig" => sig })
    expect(Axn::Webhooks::Inbound[:slack].verify(req)).to be_ok
  end

  it "rejects a stale timestamp when replay protection is configured" do
    stale = (Time.now - 10_000).to_i.to_s
    sig = OpenSSL::HMAC.hexdigest("SHA256", secret, body)
    Axn::Webhooks.inbound(:lob) do
      verify :hmac, secret: "shh", signature: header("X-Sig"),
                    replay: { timestamp: header("X-Ts"), within: 300 }
    end
    req = request(headers: { "X-Sig" => sig, "X-Ts" => stale })
    expect(Axn::Webhooks::Inbound[:lob].verify(req)).not_to be_ok
  end

  it "raises a loud developer error when a required option is missing" do
    expect { Axn::Webhooks.inbound(:x) { verify :hmac, secret: "s" } } # no signature:
      .to raise_error(ArgumentError, /signature/)
  end
end
