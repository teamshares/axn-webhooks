# frozen_string_literal: true

require "base64"

# Proves the outbound Signer and the inbound verify :standard_webhooks strategy agree: a body signed
# for delivery verifies against the receiver's verifier using the fresh per-attempt timestamp.
RSpec.describe "outbound signing <-> inbound verification round-trip" do
  after { Axn::Webhooks::Outbound.reset! }

  let(:secret) { "whsec_#{Base64.strict_encode64('shared-secret')}" }

  it "an outbound-signed request passes the inbound verifier" do
    signer = Axn::Webhooks::Outbound::Signer.build(strategy: :standard_webhooks, opts: { secret: }, block: nil)
    id = "msg_round_trip"
    ts = Time.now.to_i
    body = Axn::Webhooks::Outbound::Envelope.build(id:, type: "lead_signed", data: { lead_id: 1 })
    # Envelope uses its own timestamp; sign with the same ts we present in the header.
    headers = signer.call(id:, timestamp: ts, body:)

    request = Axn::Webhooks::Request.new(
      raw_body: body,
      headers: {
        "webhook-id" => headers["webhook-id"],
        "webhook-timestamp" => headers["webhook-timestamp"],
        "webhook-signature" => headers["webhook-signature"],
      },
    )

    verifier = Axn::Webhooks::Verifiers.build(strategy: :standard_webhooks, opts: { secret: }, block: nil)
    # A built-in strategy returns a Signature::Check, not a bare boolean (PRO-3141).
    expect(verifier.call(request)).to be_ok
  end
  # The point of mirroring the inbound option names is that the two halves agree in practice.
  it "an outbound sign :hmac request passes the inbound verify :hmac verifier" do
    signer = Axn::Webhooks::Outbound::Signer.build(
      strategy: :hmac, opts: { secret: "shared-hmac-secret", header: "X-Signature" }, block: nil,
    )
    body = Axn::Webhooks::Outbound::Envelope.build(id: "msg_1", type: "lead_signed", data: { lead_id: 1 })
    headers = signer.call(id: "msg_1", timestamp: Time.now.to_i, body:)

    request = Axn::Webhooks::Request.new(raw_body: body, headers: { "X-Signature" => headers["X-Signature"] })

    verifier = Axn::Webhooks::Verifiers.build(
      strategy: :hmac,
      opts: { secret: "shared-hmac-secret", signature: Axn::Webhooks::Resolvers.header("X-Signature") },
      block: nil,
    )
    expect(verifier.call(request)).to be_ok
  end

  it "round-trips the timestamped form, including the replay window" do
    ts = Time.now.to_i
    signer = Axn::Webhooks::Outbound::Signer.build(
      strategy: :hmac,
      opts: { secret: "shared", header: "X-Signature", timestamp_header: "X-Timestamp",
              signing_string: "v0:{timestamp}:{body}", prefix: "v0=" },
      block: nil,
    )
    body = %({"a":1})
    headers = signer.call(id: "msg_1", timestamp: ts, body:)

    request = Axn::Webhooks::Request.new(
      raw_body: body,
      headers: { "X-Signature" => headers["X-Signature"], "X-Timestamp" => headers["X-Timestamp"] },
    )

    verifier = Axn::Webhooks::Verifiers.build(
      strategy: :hmac,
      opts: {
        secret: "shared",
        signature: Axn::Webhooks::Resolvers.header("X-Signature"),
        signing_string: ->(req) { "v0:#{req.header('X-Timestamp')}:#{req.raw_body}" },
        prefix: "v0=",
        replay: { timestamp: Axn::Webhooks::Resolvers.header("X-Timestamp"), within: 300 },
      },
      block: nil,
    )
    expect(verifier.call(request)).to be_ok
  end

  describe "per-subscriber secrets (PRO-3214)" do
    let(:sub_a) { Axn::Webhooks::Outbound::Subscriber.new(url: "https://a.example/hook", id: "a") }
    let(:sub_b) { Axn::Webhooks::Outbound::Subscriber.new(url: "https://b.example/hook", id: "b") }
    let(:secret_a) { "whsec_#{Base64.strict_encode64('secret-for-a')}" }
    let(:secret_b) { "whsec_#{Base64.strict_encode64('secret-for-b')}" }

    it "signs each subscriber with its OWN secret, and each verifies only against its own" do
      secrets = { "a" => secret_a, "b" => secret_b }
      signer = Axn::Webhooks::Outbound::Signer.build(
        strategy: :standard_webhooks, opts: { secret: ->(sub) { secrets.fetch(sub.id) } }, block: nil,
      )
      body = Axn::Webhooks::Outbound::Envelope.build(id: "msg_1", type: "lead_signed", data: {})
      ts = Time.now.to_i

      headers_a = signer.call(id: "msg_1", timestamp: ts, body:, subscriber: sub_a)
      headers_b = signer.call(id: "msg_1", timestamp: ts, body:, subscriber: sub_b)

      request_a = Axn::Webhooks::Request.new(raw_body: body, headers: headers_a)
      request_b = Axn::Webhooks::Request.new(raw_body: body, headers: headers_b)

      verifier_a = Axn::Webhooks::Verifiers.build(strategy: :standard_webhooks, opts: { secret: secret_a }, block: nil)
      verifier_b = Axn::Webhooks::Verifiers.build(strategy: :standard_webhooks, opts: { secret: secret_b }, block: nil)

      # Each subscriber's own request verifies against ITS OWN secret...
      expect(verifier_a.call(request_a)).to be_ok
      expect(verifier_b.call(request_b)).to be_ok
      # ...and NOT against the other's -- proving these are genuinely independent secrets, not one
      # shared value that happens to pass both checks.
      expect(verifier_a.call(request_b)).not_to be_ok
      expect(verifier_b.call(request_a)).not_to be_ok
    end
  end
end
