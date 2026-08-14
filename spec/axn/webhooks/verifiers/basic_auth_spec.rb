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

    it "uses a declared realm, stripping quotes that would break the header" do
      endpoint = declare(realm: 'Buyout "Webhooks"')

      expect(endpoint.to_response(request).headers["www-authenticate"]).to eq('Basic realm="Buyout Webhooks"')
    end

    it "is not sent once the client authenticates" do
      expect(declare.to_response(request(headers: basic("twilio", "s3cret"))).headers).to eq({})
    end
  end
end
