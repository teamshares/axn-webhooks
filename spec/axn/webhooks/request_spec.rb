# frozen_string_literal: true

RSpec.describe Axn::Webhooks::Request do
  subject(:request) do
    described_class.new(
      raw_body: '{"a":1}',
      headers: { "Content-Type" => "application/json", "X-Merge-Webhook-Signature" => "abc" },
      params: { "challenge" => "xyz" },
      url: "https://example.com/webhooks/merge",
      http_method: "post",
    )
  end

  it "exposes the raw body verbatim" do
    expect(request.raw_body).to eq('{"a":1}')
  end

  it "looks up headers case-insensitively" do
    expect(request.header("x-merge-webhook-signature")).to eq("abc")
    expect(request.header("X-MERGE-WEBHOOK-SIGNATURE")).to eq("abc")
    expect(request.header("Content-Type")).to eq("application/json")
  end

  it "returns nil for an unknown header" do
    expect(request.header("X-Absent")).to be_nil
  end

  it "exposes params, url, and an upcased http_method" do
    expect(request.params).to eq("challenge" => "xyz")
    expect(request.url).to eq("https://example.com/webhooks/merge")
    expect(request.http_method).to eq("POST")
  end

  it "defaults params to empty and http_method to POST" do
    bare = described_class.new(raw_body: "")
    expect(bare.params).to eq({})
    expect(bare.http_method).to eq("POST")
    expect(bare.header("anything")).to be_nil
  end

  it "does not let callers mutate internal params" do
    expect { request.params["injected"] = true }.to raise_error(FrozenError)
  end
end
