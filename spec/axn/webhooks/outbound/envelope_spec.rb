# frozen_string_literal: true

require "json"

RSpec.describe Axn::Webhooks::Outbound::Envelope do
  describe ".new_id" do
    it "is prefixed and unique" do
      a = described_class.new_id
      b = described_class.new_id
      expect(a).to start_with("msg_")
      expect(a).not_to eq(b)
    end
  end

  describe ".build" do
    it "produces the {id,timestamp,type,data} envelope as JSON" do
      json = described_class.build(id: "msg_1", type: "lead_signed",
                                   data: { "lead_id" => 42 }, now: Time.at(1_700_000_000))
      expect(JSON.parse(json)).to eq(
        "id" => "msg_1", "timestamp" => 1_700_000_000,
        "type" => "lead_signed", "data" => { "lead_id" => 42 }
      )
    end
  end
end
