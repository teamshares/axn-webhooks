# frozen_string_literal: true

RSpec.describe Axn::Webhooks::Inbound::DSL do
  describe "#respond" do
    it "defaults __respond__ to nil when undeclared" do
      expect(described_class.new.__respond__).to be_nil
    end

    it "captures the declared block" do
      dsl = described_class.new
      block = ->(r) { text(r.to_s) }
      dsl.respond(&block)
      expect(dsl.__respond__).to eq(block)
    end
  end
end
