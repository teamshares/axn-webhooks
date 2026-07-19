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
    expect(verifier.call(request)).to be(true)
  end
end
