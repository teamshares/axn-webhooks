# frozen_string_literal: true

RSpec.describe Axn::Webhooks::Resolvers do
  let(:request) do
    Axn::Webhooks::Request.new(
      raw_body: '{"a":1}',
      headers: { "X-Sig" => "abc" },
      params: { "challenge" => "xyz" },
      url: "https://example.com/hook",
    )
  end

  describe "request resolvers" do
    it "reads a header at resolve time" do
      expect(described_class.header("X-Sig").call(request)).to eq("abc")
    end

    it "reads raw_body, params, and url" do
      expect(described_class.raw_body.call(request)).to eq('{"a":1}')
      expect(described_class.params.call(request)).to eq("challenge" => "xyz")
      expect(described_class.url.call(request)).to eq("https://example.com/hook")
    end
  end

  describe ".resolve" do
    it "calls a Resolver with the request" do
      expect(described_class.resolve(described_class.header("X-Sig"), request)).to eq("abc")
    end

    it "treats a Symbol as a request reader" do
      expect(described_class.resolve(:raw_body, request)).to eq('{"a":1}')
    end

    it "calls a 1-arg proc with the request and a 0-arg proc with nothing" do
      expect(described_class.resolve(lambda(&:url), request)).to eq("https://example.com/hook")
      expect(described_class.resolve(-> { "boot-secret" }, request)).to eq("boot-secret")
    end

    it "passes literals through unchanged" do
      expect(described_class.resolve("literal", request)).to eq("literal")
    end
  end
end
