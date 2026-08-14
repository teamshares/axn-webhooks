# frozen_string_literal: true

require "base64"

RSpec.describe "verify :basic_auth strategy" do
  after { Axn::Webhooks::Inbound.reset! }

  def request(headers: {})
    Axn::Webhooks::Request.new(raw_body: "CallSid=CA123", headers:)
  end

  def basic(username, password)
    { "Authorization" => "Basic #{Base64.strict_encode64("#{username}:#{password}")}" }
  end

  def declare(**opts)
    Axn::Webhooks.inbound(:twilio) { verify :basic_auth, username: "twilio", password: "s3cret", **opts }
    Axn::Webhooks::Inbound[:twilio]
  end

  it "verifies matching credentials and rejects wrong ones" do
    endpoint = declare

    expect(endpoint.verify(request(headers: basic("twilio", "s3cret")))).to be_ok
    expect(endpoint.verify(request(headers: basic("twilio", "wrong")))).not_to be_ok
    expect(endpoint.verify(request(headers: basic("nope", "s3cret")))).not_to be_ok
  end

  it "rejects a request with no Authorization header, or a non-Basic scheme" do
    endpoint = declare

    expect(endpoint.verify(request)).not_to be_ok
    expect(endpoint.verify(request(headers: { "Authorization" => "Bearer abc123" }))).not_to be_ok
  end

  it "accepts a password containing colons" do
    Axn::Webhooks.inbound(:twilio) { verify :basic_auth, username: "twilio", password: "a:b:c" }

    expect(Axn::Webhooks::Inbound[:twilio].verify(request(headers: basic("twilio", "a:b:c")))).to be_ok
  end

  it "matches the scheme case-insensitively, as RFC 7617 requires" do
    endpoint = declare
    encoded = Base64.strict_encode64("twilio:s3cret")

    expect(endpoint.verify(request(headers: { "Authorization" => "basic #{encoded}" }))).to be_ok
  end

  it "resolves lambda credentials per request, so a rotated secret is picked up without a reboot" do
    password = "first"
    Axn::Webhooks.inbound(:twilio) { verify :basic_auth, username: "twilio", password: -> { password } }
    endpoint = Axn::Webhooks::Inbound[:twilio]

    expect(endpoint.verify(request(headers: basic("twilio", "first")))).to be_ok

    password = "second"
    expect(endpoint.verify(request(headers: basic("twilio", "first")))).not_to be_ok
    expect(endpoint.verify(request(headers: basic("twilio", "second")))).to be_ok
  end

  # Without this, `Authorization: Basic Og==` (":" -> empty user, empty password) authenticates
  # anyone against an unset credential pair — a misconfigured deploy silently open to the world.
  it "fails closed on a blank or missing credential rather than comparing against empty strings" do
    Axn::Webhooks.inbound(:twilio) { verify :basic_auth, username: "", password: "" }
    endpoint = Axn::Webhooks::Inbound[:twilio]
    blank = { "Authorization" => "Basic #{Base64.strict_encode64(':')}" }

    result = endpoint.verify(request(headers: blank))

    expect(result).not_to be_ok
    expect(result.exception).to be_a(Axn::Webhooks::Error)
    expect(endpoint.to_response(request(headers: blank)).status).to eq(401)
  end

  # Verify renders its `verifier:` input in the per-call log line, so a default Object#inspect
  # would write the plaintext password to the application log on every single request.
  describe "credential redaction" do
    subject(:verifier) { Axn::Webhooks::Verifiers::BasicAuth.new(username: "twilio", password: "s3cret") }

    it "redacts credentials from #inspect, keeping the realm (already public in the challenge)" do
      expect(verifier.inspect).to eq('#<Axn::Webhooks::Verifiers::BasicAuth realm="Webhook" credentials=[REDACTED]>')
      expect(verifier.inspect).not_to include("s3cret", "twilio")
    end

    # PP walks instance variables rather than calling #inspect, so this needs its own override.
    it "redacts credentials from pp too" do
      expect { pp verifier }.to output(/credentials=\[REDACTED\]/).to_stdout
      expect { pp verifier }.not_to output(/s3cret/).to_stdout
    end

    it "marks Verify's verifier input sensitive, so a custom verify block is covered too" do
      expect(Axn::Webhooks::Verify.internal_field_configs.find { |f| f.field == :verifier }.sensitive).to be(true)
    end
  end

  # PRO-3141 made verify failures name their cause. Basic auth rejects for reasons that have
  # nothing to do with a signature, and under RFC 7617 the bare first leg of every *successful*
  # webhook is a rejection — so labelling those :signature_mismatch would make the single
  # highest-volume value of this dimension both wrong and alarming.
  describe "rejection reasons" do
    it "reports :credentials_missing for the expected bare first leg, not a mismatch" do
      result = declare.verify(request)

      expect(result.reason).to eq(:credentials_missing)
      expect(result.error).to match(/awaits the 401 challenge/)
    end

    it "reports :credentials_missing for a non-Basic scheme" do
      expect(declare.verify(request(headers: { "Authorization" => "Bearer abc" })).reason).to eq(:credentials_missing)
    end

    it "reports :credentials_mismatch when credentials are offered but wrong" do
      result = declare.verify(request(headers: basic("twilio", "wrong")))

      expect(result.reason).to eq(:credentials_mismatch)
      expect(result.error).to match(/Basic credentials rejected/)
    end

    it "exposes no reason on success" do
      expect(declare.verify(request(headers: basic("twilio", "s3cret"))).reason).to be_nil
    end

    it "keeps both reasons in the closed enum Verify can render" do
      %i[credentials_missing credentials_mismatch].each do |reason|
        expect(Axn::Webhooks::Signature::REASONS).to include(reason)
        expect(Axn::Webhooks::Verify::MESSAGES).to have_key(reason)
      end
    end
  end

  describe "the 401 challenge" do
    # The regression this whole strategy exists for. Twilio (and any other client that doesn't
    # authenticate preemptively) sends its first request with no Authorization header and only
    # repeats it with credentials after a 401 carrying WWW-Authenticate. A bare 401 means the
    # second request never happens and every webhook is dropped — silently, since the first leg
    # looks like an ordinary auth failure.
    it "carries WWW-Authenticate so an unauthenticated client retries with credentials" do
      response = declare.to_response(request)

      expect(response.status).to eq(401)
      expect(response.headers["www-authenticate"]).to eq('Basic realm="Webhook"')
    end

    it "survives to the Rack layer, where the vendor actually reads it" do
      declare
      env = Rack::MockRequest.env_for("https://example.com/calls/notify", method: "POST", input: "CallSid=CA123")

      status, headers, = Axn::Webhooks::Inbound[:twilio].call(env)

      expect(status).to eq(401)
      expect(headers["www-authenticate"]).to eq('Basic realm="Webhook"')
    end

    it "uses a declared realm" do
      expect(declare(realm: "Buyout Webhooks").to_response(request).headers["www-authenticate"])
        .to eq('Basic realm="Buyout Webhooks"')
    end

    # RFC 7230 quoted-string rules. Stripping quotes instead would leave a trailing backslash
    # escaping the closing quote (`realm="Partner\"`) — malformed enough that a client may reject
    # the challenge and never retry, which is the failure this whole strategy exists to prevent.
    it "escapes quotes and backslashes in the realm rather than dropping them" do
      expect(declare(realm: 'Buyout "Webhooks"').to_response(request).headers["www-authenticate"])
        .to eq('Basic realm="Buyout \"Webhooks\""')

      expect(declare(realm: "Partner\\").to_response(request).headers["www-authenticate"])
        .to eq('Basic realm="Partner\\\\"')
    end

    it "rejects a realm containing control characters at declaration time" do
      expect { declare(realm: "Bad\r\nX-Injected: 1") }
        .to raise_error(Axn::Webhooks::Error, /realm cannot contain control characters/)
    end

    it "is not sent once the client authenticates" do
      expect(declare.to_response(request(headers: basic("twilio", "s3cret"))).headers).to eq({})
    end
  end
end
