# frozen_string_literal: true

RSpec.describe Axn::Webhooks::Outbound::CallableArity do
  describe ".accepted_keywords" do
    it "lists required keyword params" do
      callable = ->(id:, timestamp:, body:) { [id, timestamp, body] }
      expect(described_class.accepted_keywords(callable)).to contain_exactly(:id, :timestamp, :body)
    end

    it "lists optional keyword params alongside required ones" do
      callable = ->(id:, timestamp: nil) { [id, timestamp] }
      expect(described_class.accepted_keywords(callable)).to contain_exactly(:id, :timestamp)
    end

    it "returns :all for a callable that double-splats (accepts any keyword)" do
      callable = ->(id:, **) { id }
      expect(described_class.accepted_keywords(callable)).to eq(:all)
    end

    it "ignores positional params entirely" do
      callable = ->(pos, id:) { [pos, id] }
      expect(described_class.accepted_keywords(callable)).to contain_exactly(:id)
    end

    it "returns an empty Array for a callable that accepts no keywords at all" do
      callable = -> {}
      expect(described_class.accepted_keywords(callable)).to eq([])
    end

    it "works via #parameters on a plain callable OBJECT, not just a Proc/lambda" do
      obj = Class.new { def call(id:, body:) = [id, body] }.new
      expect(described_class.accepted_keywords(obj)).to contain_exactly(:id, :body)
    end
  end
end
