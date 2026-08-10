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

    it "rejects a block that declares a parameter (e.g. a copy-pasted respond block)" do
      dsl = described_class.new
      expect do
        dsl.static_respond { |result| text(result.to_s) }
      end.to raise_error(Axn::Webhooks::Error, /must take no arguments/)
    end

    it "rejects a lambda with a parameter" do
      dsl = described_class.new
      expect do
        dsl.static_respond(&->(result) { text(result.to_s) })
      end.to raise_error(Axn::Webhooks::Error, /must take no arguments/)
    end
  end
end
