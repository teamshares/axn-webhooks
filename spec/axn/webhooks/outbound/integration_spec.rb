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
end
