# frozen_string_literal: true

RSpec.describe "401 response headers" do
  after { Axn::Webhooks::Inbound.reset! }

  def request = Axn::Webhooks::Request.new(raw_body: "{}", headers: {})

  it "stays bare for a signature strategy — there is nothing to challenge a signing client with" do
    Axn::Webhooks.inbound(:merge) { verify :hmac, secret: "shh", signature: header("X-Sig") }

    response = Axn::Webhooks::Inbound[:merge].to_response(request)

    expect(response.status).to eq(401)
    expect(response.headers).to eq({})
  end

  it "stays bare for a custom verify block that declares nothing" do
    Axn::Webhooks.inbound(:vendor) { verify { |_req| false } }

    expect(Axn::Webhooks::Inbound[:vendor].to_response(request).headers).to eq({})
  end

  it "carries a declared `unauthorized_headers` for a custom verify block" do
    Axn::Webhooks.inbound(:vendor) do
      verify { |_req| false }
      unauthorized_headers "WWW-Authenticate" => %(Basic realm="Custom")
    end

    response = Axn::Webhooks::Inbound[:vendor].to_response(request)

    # Response lower-cases header keys (Rack 3 SPEC), so the declaration's casing doesn't matter.
    expect(response.headers["www-authenticate"]).to eq('Basic realm="Custom"')
  end

  it "prefers a declaration over the verifier's own headers" do
    Axn::Webhooks.inbound(:twilio) do
      verify :basic_auth, username: "twilio", password: "s3cret", realm: "FromVerifier"
      unauthorized_headers "WWW-Authenticate" => %(Basic realm="FromDeclaration")
    end

    expect(Axn::Webhooks::Inbound[:twilio].to_response(request).headers["www-authenticate"])
      .to eq('Basic realm="FromDeclaration"')
  end

  it "attaches the challenge to a verifier crash too, so a transient misconfiguration self-heals" do
    Axn::Webhooks.inbound(:vendor) do
      verify { |_req| raise "boom" }
      unauthorized_headers "WWW-Authenticate" => %(Basic realm="Custom")
    end

    response = Axn::Webhooks::Inbound[:vendor].to_response(request)

    expect(response.status).to eq(401)
    expect(response.headers["www-authenticate"]).to eq('Basic realm="Custom"')
  end
end
