# frozen_string_literal: true

RSpec.describe Axn::Webhooks::Verify do
  let(:request) { Axn::Webhooks::Request.new(raw_body: "body", headers: { "X-Token" => "ok" }) }

  it "succeeds when the verifier returns truthy" do
    result = described_class.call(request:, verifier: ->(req) { req.header("X-Token") == "ok" })
    expect(result).to be_ok
  end

  it "fails quietly (failure, not exception) on a signature mismatch" do
    result = described_class.call(request:, verifier: ->(_req) { false })
    expect(result).not_to be_ok
    expect(result.outcome).to be_failure
    expect(result.outcome).not_to be_exception
    expect(result.error).to include("verification failed")
  end

  it "surfaces a verifier crash as an exception (loud), preserving the error" do
    boom = Class.new(StandardError)
    result = described_class.call(request:, verifier: ->(_req) { raise boom, "bad header" })
    expect(result).not_to be_ok
    expect(result.outcome).to be_exception
    expect(result.exception).to be_a(boom)
  end
end
