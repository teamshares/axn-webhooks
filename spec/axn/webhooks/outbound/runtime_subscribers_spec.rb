# frozen_string_literal: true

require "base64"

# Guards the README's "Routing: sender-owned config today" promise: the `subscribers` / `to:` lambda
# is the seam a DB-backed subscription store slots into with no API change. `dsl_spec` covers the
# resolver at the `Config#targets_for` level; this covers the whole path through `Axn::Webhooks.emit`
# — that the resolver is consulted on EVERY emit (never memoized at boot), so rows added or removed
# at runtime are honored without a redeploy.
RSpec.describe "outbound subscribers resolved at emit time" do
  after { Axn::Webhooks::Outbound.reset! }

  # Stand-in for an ActiveRecord-backed store: rows mutate between emits.
  let(:store) { [] }

  let(:enqueued) { [] }

  before do
    rows = store
    Axn::Webhooks.outbound do
      sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('s')}"
      subscribers ->(event) { rows.select { |r| r[:event] == event.to_s }.map { |r| r[:url] } }
      event :lead_closed # no `to:` -> block-level resolver
      event :lead_signed, to: ->(_event) { rows.map { |r| r[:url] } } # per-event resolver
    end

    calls = enqueued
    allow(Axn::Webhooks::Outbound::Deliver).to receive(:call) { |**kw| calls << kw }
  end

  def urls_delivered_to = enqueued.map { |kw| kw[:url] }

  it "consults the block-level `subscribers` resolver on every emit, not once at boot" do
    expect(Axn::Webhooks.emit(:lead_closed).target_count).to eq(0)

    store << { event: "lead_closed", url: "https://added-after-boot.example/hook" }
    expect(Axn::Webhooks.emit(:lead_closed).target_count).to eq(1)
    expect(urls_delivered_to).to eq(["https://added-after-boot.example/hook"])

    store.clear
    expect(Axn::Webhooks.emit(:lead_closed).target_count).to eq(0)
    expect(urls_delivered_to.size).to eq(1) # the removed row is not delivered to again
  end

  it "re-resolves a per-event `to:` callable on every emit too" do
    store << { event: "lead_signed", url: "https://one.example/hook" }
    Axn::Webhooks.emit(:lead_signed)

    store << { event: "lead_signed", url: "https://two.example/hook" }
    result = Axn::Webhooks.emit(:lead_signed)

    expect(result.target_count).to eq(2)
    expect(urls_delivered_to).to eq(%w[https://one.example/hook https://one.example/hook https://two.example/hook])
  end

  it "gives each runtime-resolved target its own webhook-id within a single emit" do
    store << { event: "lead_closed", url: "https://a.example/hook" }
    store << { event: "lead_closed", url: "https://b.example/hook" }

    result = Axn::Webhooks.emit(:lead_closed, data: { lead_id: 1 })

    expect(result.webhook_ids.uniq.size).to eq(2)
    expect(result.webhook_ids).to match_array(enqueued.map { |kw| kw[:webhook_id] })
  end
end
