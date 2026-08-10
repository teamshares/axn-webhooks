# frozen_string_literal: true

RSpec.describe Axn::Webhooks::Inbound::DSL do
  describe "#static_respond" do
    it "defaults __static_respond__ to nil when undeclared" do
      expect(described_class.new.__static_respond__).to be_nil
    end

    it "captures the declared block" do
      dsl = described_class.new
      block = -> { text("Hello API Event Received") }
      dsl.static_respond(&block)
      expect(dsl.__static_respond__).to eq(block)
    end
  end
end
