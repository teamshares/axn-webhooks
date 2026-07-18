# frozen_string_literal: true

RSpec.describe Axn::Webhooks::Inbound::Challenge do
  def req(params) = Axn::Webhooks::Request.new(raw_body: "", params:)

  it "echoes the resolver's value as a 200 text/plain Response" do
    result = described_class.call(request: req("challenge" => "xyz"), resolver: ->(r) { r.params["challenge"] })
    expect(result).to be_ok
    expect(result.response.status).to eq(200)
    expect(result.response.body).to eq("xyz")
    expect(result.response.headers).to eq("content-type" => "text/plain")
  end

  it "computes a 400 Response (no exception) when the resolver returns nil" do
    result = described_class.call(request: req({}), resolver: ->(r) { r.params["challenge"] })
    expect(result).to be_ok
    expect(result.response.status).to eq(400)
  end

  it "computes a 403 Response when a guard rejects the request" do
    result = described_class.call(
      request: req("hub.challenge" => "xyz", "hub.verify_token" => "wrong"),
      resolver: ->(r) { r.params["hub.challenge"] },
      guard: ->(r) { r.params["hub.verify_token"] == "right" },
    )
    expect(result).to be_ok
    expect(result.response.status).to eq(403)
  end

  it "echoes when the guard accepts the request" do
    result = described_class.call(
      request: req("hub.challenge" => "xyz", "hub.verify_token" => "right"),
      resolver: ->(r) { r.params["hub.challenge"] },
      guard: ->(r) { r.params["hub.verify_token"] == "right" },
    )
    expect(result).to be_ok
    expect(result.response.body).to eq("xyz")
  end

  it "reports (exception) rather than raises when the resolver crashes" do
    result = nil
    expect { result = described_class.call(request: req({}), resolver: ->(_r) { raise "boom" }) }.not_to raise_error
    expect(result.outcome).to be_exception
  end
end
