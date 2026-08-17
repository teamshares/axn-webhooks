# frozen_string_literal: true

require "base64"

# PRO-3148. Under RFC 7617 a client that doesn't authenticate preemptively sends one bare request
# per *successful* webhook — so settling that leg as a Verify failure made the highest-volume
# outcome on a healthy endpoint a recorded failure, and a cross-vendor "verify failures" monitor
# unusable without knowing which vendors happen to use Basic auth.
#
# The bare leg is a protocol precondition, not a failed verification: there is nothing to verify.
# `Endpoint#to_response` answers the challenge before `Verify` runs at all.
RSpec.describe "the challenge-required precondition" do
  after { Axn::Webhooks::Inbound.reset! }

  def request(headers: {})
    Axn::Webhooks::Request.new(raw_body: "CallSid=CA123", headers:)
  end

  def basic(username, password)
    { "Authorization" => "Basic #{Base64.strict_encode64("#{username}:#{password}")}" }
  end

  def declare(name = :twilio, &extra)
    Axn::Webhooks.inbound(name) do
      verify :basic_auth, username: "twilio", password: "s3cret"
      instance_exec(&extra) if extra
    end
    Axn::Webhooks::Inbound[name]
  end

  # A spy on the real Verify axn: `and_call_original` so every other assertion in this file is
  # about genuine behaviour, and the "was it invoked" question is answered separately.
  before { allow(Axn::Webhooks::Verify).to receive(:call).and_call_original }

  # A real handler Axn that records what reached it — the "no path to a handler" criterion is about
  # the handler actually running, not about the status code standing in for it.
  before do
    stub_const("SpyHandler", Class.new do
      include Axn

      expects :event, allow_blank: true
      def call = self.class.calls << event
      def self.calls = @calls ||= []
    end)
  end

  # Form-encoded, like the Twilio traffic this is drawn from — so `parse:` reads params, not JSON.
  def dispatching_endpoint = declare { dispatch to: "SpyHandler", parse: :params.to_proc }

  describe "a bare request — the first leg of the handshake" do
    it "answers the challenge with a 401 without recording a Verify failure" do
      response = declare.to_response(request)

      expect(response.status).to eq(401)
      expect(response.headers["www-authenticate"]).to eq('Basic realm="Webhook"')
      expect(Axn::Webhooks::Verify).not_to have_received(:call)
    end

    it "treats a blank Authorization header as absent — it is not an authentication attempt either" do
      declare.to_response(request(headers: { "Authorization" => "  " }))

      expect(Axn::Webhooks::Verify).not_to have_received(:call)
    end

    it "never reaches the handler" do
      dispatching_endpoint.to_response(request)

      expect(SpyHandler.calls).to be_empty
    end
  end

  # The distinction that keeps :credentials_missing worth alerting on: a client that sent SOME
  # Authorization header expected to authenticate, and got it wrong. Folding it into the challenge
  # would 401 it forever with no telemetry at all.
  describe "a non-Basic Authorization header — a client that did expect to authenticate" do
    it "is verified and rejected, so it stays visible as :credentials_missing" do
      endpoint = declare
      headers = { "Authorization" => "Bearer abc123" }

      expect(endpoint.to_response(request(headers:)).status).to eq(401)
      expect(Axn::Webhooks::Verify).to have_received(:call)
      expect(endpoint.verify(request(headers:)).reason).to eq(:credentials_missing)
    end
  end

  describe "credentials that were offered" do
    it "records a Verify failure naming :credentials_mismatch when they are wrong" do
      endpoint = declare
      headers = basic("twilio", "wrong")

      expect(endpoint.to_response(request(headers:)).status).to eq(401)
      expect(Axn::Webhooks::Verify).to have_received(:call)
      expect(endpoint.verify(request(headers:)).reason).to eq(:credentials_mismatch)
    end

    it "dispatches exactly as before when they are right" do
      response = dispatching_endpoint.to_response(request(headers: basic("twilio", "s3cret")))

      expect(response.status).to eq(200)
      expect(SpyHandler.calls.size).to eq(1)
    end
  end

  # The precondition is opt-in per verifier, so the signature strategies — which have no challenge
  # to offer and no handshake to complete — must be untouched. Asserted, not assumed.
  describe "signature strategies" do
    it "verify a request carrying no Authorization header exactly as before" do
      Axn::Webhooks.inbound(:merge) { verify :hmac, secret: "shh", signature: header("X-Sig") }
      endpoint = Axn::Webhooks::Inbound[:merge]

      response = endpoint.to_response(request)

      expect(response.status).to eq(401)
      expect(response.headers).to eq({})
      expect(Axn::Webhooks::Verify).to have_received(:call)
      expect(endpoint.verify(request).reason).to eq(:signature_missing)
    end

    it "never require a challenge" do
      Axn::Webhooks.inbound(:merge) { verify :hmac, secret: "shh", signature: header("X-Sig") }

      expect(Axn::Webhooks::Inbound[:merge]).not_to be_challenge_required(request)
    end
  end

  describe "a custom verify block" do
    it "verifies as before, since a bare lambda declares no challenge" do
      Axn::Webhooks.inbound(:vendor) { verify { |_req| false } }

      expect(Axn::Webhooks::Inbound[:vendor].to_response(request).status).to eq(401)
      expect(Axn::Webhooks::Verify).to have_received(:call)
    end

    # The shape buyout's Twilio routes actually use: the BasicAuth verifier wrapped in a block the
    # gem cannot see through (Twilio::SignatureShadow, for PRO-3124). Without a declaration these
    # endpoints — the ones this issue was filed for — would keep recording the bare leg.
    it "can declare the precondition itself, mirroring `unauthorized_headers`" do
      verifier = Axn::Webhooks::Verifiers::BasicAuth.new(username: "twilio", password: "s3cret")
      Axn::Webhooks.inbound(:shadowed) do
        verify { |req| verifier.call(req) }
        unauthorized_headers verifier.unauthorized_headers
        challenge_required { |req| verifier.challenge_required?(req) }
      end
      endpoint = Axn::Webhooks::Inbound[:shadowed]

      response = endpoint.to_response(request)

      expect(response.status).to eq(401)
      expect(response.headers["www-authenticate"]).to eq('Basic realm="Webhook"')
      expect(Axn::Webhooks::Verify).not_to have_received(:call)
      expect(endpoint.to_response(request(headers: basic("twilio", "wrong"))).status).to eq(401)
      expect(Axn::Webhooks::Verify).to have_received(:call)
    end

    # Challenging a client with nothing is the PRO-3146 silent-drop failure exactly: the client is
    # told to retry and never told how, so every request is dropped forever. Now with no verify
    # failure recorded either, it would be invisible as well as broken — so it fails the boot.
    it "is rejected at declaration time when there is no challenge to send" do
      expect do
        Axn::Webhooks.inbound(:vendor) do
          verify { |_req| false }
          challenge_required { |_req| true }
        end
      end.to raise_error(Axn::Webhooks::Error, /challenge_required.*unauthorized_headers/m)
    end

    it "wins over the verifier's own predicate, as `unauthorized_headers` does" do
      endpoint = declare { challenge_required { |_req| false } }

      expect(endpoint.to_response(request).status).to eq(401)
      expect(Axn::Webhooks::Verify).to have_received(:call)
    end
  end

  # The predicate is a request-dependent extension point, and it runs on the Rack path ahead of
  # everything else — so like the verifier, the `parse:` step and the GET challenge resolver, it gets
  # an Axn boundary rather than being trusted not to raise on adversarial input.
  describe "a predicate that raises" do
    def endpoint_with_raising_predicate
      declare { challenge_required { |_req| raise "predicate exploded" } }
    end

    it "does not escape to the Rack layer" do
      Axn::Webhooks.inbound(:twilio) do
        verify :basic_auth, username: "twilio", password: "s3cret"
        challenge_required { |_req| raise "predicate exploded" }
      end
      env = Rack::MockRequest.env_for("https://example.com/calls/notify", method: "POST", input: "CallSid=CA123")

      expect { Axn::Webhooks::Inbound[:twilio].call(env) }.not_to raise_error
    end

    # Falls through to Verify — the behaviour from before the precondition existed. Safe by
    # construction: Verify still decides, so a broken predicate can never dispatch an
    # unauthenticated request, and it can't drop an authenticated one either.
    it "falls through to verification rather than 401ing an authenticated request" do
      stub_const("SpyHandler", Class.new do
        include Axn

        expects :event, allow_blank: true
        def call = self.class.calls << event
        def self.calls = @calls ||= []
      end)
      Axn::Webhooks.inbound(:twilio) do
        verify :basic_auth, username: "twilio", password: "s3cret"
        challenge_required { |_req| raise "predicate exploded" }
        dispatch to: "SpyHandler", parse: :params.to_proc
      end

      response = Axn::Webhooks::Inbound[:twilio].to_response(request(headers: basic("twilio", "s3cret")))

      expect(response.status).to eq(200)
      expect(SpyHandler.calls.size).to eq(1)
    end

    it "still rejects an unauthenticated request" do
      expect(endpoint_with_raising_predicate.to_response(request).status).to eq(401)
    end

    it "reports the exception exactly once, so a permanently-broken predicate isn't silent" do
      reports = []
      original = Axn.config.instance_variable_get(:@on_exception)
      Axn.config.instance_variable_set(:@on_exception, ->(e, **) { reports << e })

      begin
        endpoint_with_raising_predicate.to_response(request)
      ensure
        Axn.config.instance_variable_set(:@on_exception, original)
      end

      expect(reports.size).to eq(1)
      expect(reports.first.message).to eq("predicate exploded")
    end
  end

  # #verify and #handle are the verification *stage*: asking them about a bare request asks "does
  # this verify?", and the honest answer stays no. Settling them ok? would be an authentication
  # bypass; the public predicate is how a caller driving the endpoint by hand answers the challenge.
  describe "the library-level entry points" do
    it "still report a bare request as unverified" do
      endpoint = declare

      expect(endpoint.verify(request)).not_to be_ok
      expect(endpoint.verify(request).reason).to eq(:credentials_missing)
    end

    it "expose the precondition so a hand-driven caller can answer the challenge first" do
      endpoint = declare

      expect(endpoint).to be_challenge_required(request)
      expect(endpoint).not_to be_challenge_required(request(headers: basic("twilio", "wrong")))
      expect(endpoint).not_to be_challenge_required(request(headers: { "Authorization" => "Bearer abc" }))
    end
  end
end
