# frozen_string_literal: true

RSpec.describe Axn::Webhooks::Inbound::DSL do
  describe "#challenge" do
    it "defaults __challenge__ to nil when undeclared" do
      expect(described_class.new.__challenge__).to be_nil
    end

    it "captures the resolver with no guard" do
      dsl = described_class.new
      resolver = ->(req) { req.params["challenge"] }
      dsl.challenge(resolver)
      expect(dsl.__challenge__).to eq(resolver:, guard: nil)
    end

    it "captures the resolver and an if: guard" do
      dsl = described_class.new
      resolver = ->(req) { req.params["hub.challenge"] }
      guard = ->(req) { req.params["hub.verify_token"] == "secret" }
      dsl.challenge(resolver, if: guard)
      expect(dsl.__challenge__).to eq(resolver:, guard:)
    end
  end
end
