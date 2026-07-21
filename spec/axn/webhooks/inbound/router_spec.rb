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
    expect(router.resolve({ "any" => 1 })).to eq([HandleWebhook, { event: { "any" => 1 } }, nil])
  end

  it "resolves a keyed handler from an explicit map" do
    router = described_class.new(
      on: ->(e) { e["eventType"] },
      to: { "connection.updated" => "Actions::Codat::ConnectionUpdated" },
    )
    expect(router.resolve({ "eventType" => "connection.updated" }))
      .to eq([Actions::Codat::ConnectionUpdated, { event: { "eventType" => "connection.updated" } }, nil])
  end

  it "extracts scalar handler args via a with: proc" do
    router = described_class.new(
      on: ->(e) { e["event"] },
      to: { "reconciled" => { call: "PaymentOrders::DispatchCompleted",
                              with: ->(e) { { payment_order_id: e.dig("data", "id") } } } },
    )
    event = { "event" => "reconciled", "data" => { "id" => 42 } }
    expect(router.resolve(event)).to eq([PaymentOrders::DispatchCompleted, { payment_order_id: 42 }, nil])
  end

  it "derives the class from the key via convention (default transform)" do
    router = described_class.new(on: ->(e) { e["eventType"] }, to: "Actions::Codat")
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

  it "surfaces async: true from a map entry as the third tuple element" do
    router = described_class.new(
      on: ->(e) { e["type"] },
      to: { "block_actions" => { call: "HandleWebhook", async: true } },
    )
    expect(router.resolve({ "type" => "block_actions" }))
      .to eq([HandleWebhook, { event: { "type" => "block_actions" } }, true])
  end

  it "surfaces async: false from a map entry as the third tuple element" do
    router = described_class.new(
      on: ->(e) { e["type"] },
      to: { "view_submission" => { call: "HandleWebhook", async: false } },
    )
    expect(router.resolve({ "type" => "view_submission" }))
      .to eq([HandleWebhook, { event: { "type" => "view_submission" } }, false])
  end

  it "combines async: with a with: extractor on the same entry" do
    router = described_class.new(
      on: ->(e) { e["event"] },
      to: { "reconciled" => { call: "PaymentOrders::DispatchCompleted",
                              with: ->(e) { { payment_order_id: e.dig("data", "id") } },
                              async: true } },
    )
    event = { "event" => "reconciled", "data" => { "id" => 42 } }
    expect(router.resolve(event)).to eq([PaymentOrders::DispatchCompleted, { payment_order_id: 42 }, true])
  end

  it "treats an explicit async: nil as no-opinion (not an error)" do
    router = described_class.new(
      on: ->(e) { e["type"] },
      to: { "view_submission" => { call: "HandleWebhook", async: nil } },
    )
    expect(router.resolve({ "type" => "view_submission" }))
      .to eq([HandleWebhook, { event: { "type" => "view_submission" } }, nil])
  end

  it "raises for a non-boolean async: on an entry (loud)" do
    router = described_class.new(
      on: ->(e) { e["type"] },
      to: { "block_actions" => { call: "HandleWebhook", async: :yes } },
    )
    expect { router.resolve({ "type" => "block_actions" }) }
      .to raise_error(Axn::Webhooks::Error, /async:/)
  end
end
