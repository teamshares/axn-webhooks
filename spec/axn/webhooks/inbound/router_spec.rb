# frozen_string_literal: true

RSpec.describe Axn::Webhooks::Inbound::Router do
  # Stand-in handler classes (any object works; Router only resolves + returns them).
  before do
    stub_const("HandleWebhook", Class.new)
    stub_const("Actions::Codat::ConnectionUpdated", Class.new)
    stub_const("PaymentOrders::DispatchCompleted", Class.new)
  end

  it "resolves a single string handler with the whole event" do
    router = described_class.new(to: "HandleWebhook")
    expect(router.resolve({ "any" => 1 })).to eq([HandleWebhook, { event: { "any" => 1 } }])
  end

  it "resolves a keyed handler from an explicit map" do
    router = described_class.new(
      on: ->(e) { e["eventType"] },
      to: { "connection.updated" => "Actions::Codat::ConnectionUpdated" },
    )
    expect(router.resolve({ "eventType" => "connection.updated" }))
      .to eq([Actions::Codat::ConnectionUpdated, { event: { "eventType" => "connection.updated" } }])
  end

  it "extracts scalar handler args via a with: proc" do
    router = described_class.new(
      on: ->(e) { e["event"] },
      to: { "reconciled" => { call: "PaymentOrders::DispatchCompleted",
                              with: ->(e) { { payment_order_id: e.dig("data", "id") } } } },
    )
    event = { "event" => "reconciled", "data" => { "id" => 42 } }
    expect(router.resolve(event)).to eq([PaymentOrders::DispatchCompleted, { payment_order_id: 42 }])
  end

  it "derives the class from the key via convention (default transform)" do
    router = described_class.new(on: ->(e) { e["eventType"] }, to: "Actions::Codat")
    stub_const("Actions::Codat::ConnectionUpdated", Actions::Codat::ConnectionUpdated) # ensure defined
    expect(router.resolve({ "eventType" => "connection.updated" }).first)
      .to eq(Actions::Codat::ConnectionUpdated)
  end

  it "applies a custom via: transform" do
    stub_const("Codat::ConnectionUpdatedHandler", Class.new)
    router = described_class.new(
      on: ->(e) { e["eventType"] }, to: "Codat",
      via: ->(k) { "#{k.split('.').map(&:capitalize).join}Handler" }
    )
    expect(router.resolve({ "eventType" => "connection.updated" }).first)
      .to eq(Codat::ConnectionUpdatedHandler)
  end

  it "raises NameError for a missing handler constant (loud)" do
    router = described_class.new(to: "Actions::Nope::Missing")
    expect { router.resolve({}) }.to raise_error(NameError)
  end

  it "raises for an unmatched key with no otherwise (loud)" do
    router = described_class.new(on: ->(e) { e["eventType"] }, to: { "known" => "HandleWebhook" })
    expect { router.resolve({ "eventType" => "surprise" }) }
      .to raise_error(Axn::Webhooks::Error, /surprise/)
  end

  it "returns :ack for an unmatched key when otherwise: :ack" do
    router = described_class.new(on: ->(e) { e["eventType"] }, to: { "known" => "HandleWebhook" }, otherwise: :ack)
    expect(router.resolve({ "eventType" => "surprise" })).to eq(:ack)
  end

  it "runs an otherwise: proc for an unmatched key then acks" do
    seen = []
    router = described_class.new(
      on: ->(e) { e["eventType"] }, to: { "known" => "HandleWebhook" },
      otherwise: ->(e) { seen << e["eventType"] }
    )
    expect(router.resolve({ "eventType" => "surprise" })).to eq(:ack)
    expect(seen).to eq(["surprise"])
  end

  it "requires a to: target" do
    expect { described_class.new(to: nil) }.to raise_error(Axn::Webhooks::Error, /to:/)
  end
end
