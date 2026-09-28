# frozen_string_literal: true

require "base64"

# The request-auth primitives live in axn core (Axn::Extensions::Auth) so axn-openapi and this gem share
# one hardened implementation. These pin that each webhooks entry point delegates rather than keeping a
# private copy that could drift — and that the webhooks-only conventions layered on top survive.
RSpec.describe "delegation to Axn::Extensions::Auth" do
  let(:auth) { Axn::Extensions::Auth }

  after { Axn::Webhooks::Inbound.reset! }

  def request(headers: {}) = Axn::Webhooks::Request.new(raw_body: "{}", headers:)

  describe "Verifiers.require_secret!" do
    it "delegates to core, keeping this gem's default error class" do
      allow(auth).to receive(:require_secret!).and_call_original
      expect { Axn::Webhooks::Verifiers.require_secret!("verify :x", "") }
        .to raise_error(Axn::Webhooks::Error, "verify :x secret must be a non-empty String (got an empty String)")
      expect(auth).to have_received(:require_secret!).with("verify :x", "", label: "secret", error: Axn::Webhooks::Error)
    end
  end

  describe "Resolvers" do
    it "delegates Proc resolution to core" do
      allow(auth).to receive(:resolve).and_call_original
      expect(Axn::Webhooks::Resolvers.resolve(-> { "zero" }, request)).to eq("zero")
      expect(auth).to have_received(:resolve)
    end

    it "keeps resolving the webhooks-only shapes: a Resolver and a Symbol" do
      req = request(headers: { "X-Sig" => "abc" })
      expect(Axn::Webhooks::Resolvers.resolve(Axn::Webhooks::Resolvers.header("X-Sig"), req)).to eq("abc")
      expect(Axn::Webhooks::Resolvers.resolve(:raw_body, req)).to eq("{}")
      expect(Axn::Webhooks::Resolvers.deferred?(:raw_body)).to be(true)
      expect(Axn::Webhooks::Resolvers.deferred?(-> {})).to be(true)
      expect(Axn::Webhooks::Resolvers.deferred?("literal")).to be(false)
    end
  end

  describe "verify :basic_auth" do
    it "compares through core's length-independent secure_compare" do
      allow(auth).to receive(:secure_compare).and_call_original
      Axn::Webhooks.inbound(:twilio) { verify :basic_auth, username: "u", password: "p" }
      header = { "Authorization" => "Basic #{Base64.strict_encode64('u:p')}" }
      expect(Axn::Webhooks::Inbound[:twilio].verify(request(headers: header))).to be_ok
      expect(auth).to have_received(:secure_compare).twice
    end
  end

  describe "Verify" do
    it "reads a verdict through core's verified?" do
      allow(auth).to receive(:verified?).and_call_original
      Axn::Webhooks.inbound(:custom) { verify { |_req| true } }
      expect(Axn::Webhooks::Inbound[:custom].verify(request)).to be_ok
      expect(auth).to have_received(:verified?)
    end

    it "keeps a core verdict's reason instead of collapsing it to :signature_mismatch" do
      Axn::Webhooks.inbound(:custom) { verify { |_req| Axn::Extensions::Auth::CREDENTIALS_MISMATCH } }
      result = Axn::Webhooks::Inbound[:custom].verify(request)
      expect(result).not_to be_ok
      expect(result.reason).to eq(:credentials_mismatch)
    end

    it "still reads an unknown reason as a signature mismatch" do
      Axn::Webhooks.inbound(:custom) { verify { |_req| Axn::Extensions::Auth::Verdict.rejected(:who_knows) } }
      expect(Axn::Webhooks::Inbound[:custom].verify(request).reason).to eq(:signature_mismatch)
    end
  end

  describe "verify :bearer" do
    def declare
      Axn::Webhooks.inbound(:partner) { verify :bearer, keys: { "partner" => "tok" } }
      Axn::Webhooks::Inbound[:partner]
    end

    it "authenticates with core's Bearer strategy" do
      endpoint = declare
      expect(endpoint.verify(request(headers: { "Authorization" => "Bearer tok" }))).to be_ok
      mismatch = endpoint.verify(request(headers: { "Authorization" => "Bearer nope" }))
      expect(mismatch.reason).to eq(:credentials_mismatch)
      expect(mismatch.error).to eq("Webhook verification failed: credentials rejected")
      missing = endpoint.verify(request)
      expect(missing.reason).to eq(:credentials_missing)
      expect(missing.error).not_to include("Basic")
    end

    it "answers a 401 with the Bearer challenge" do
      response = declare.to_response(request)
      expect(response.status).to eq(401)
      expect(response.headers).to include("www-authenticate" => "Bearer")
    end

    it "accepts a custom header" do
      Axn::Webhooks.inbound(:partner) { verify :bearer, keys: { "partner" => "tok" }, header: "X-API-Key" }
      expect(Axn::Webhooks::Inbound[:partner].verify(request(headers: { "X-API-Key" => "tok" }))).to be_ok
    end
  end
end
