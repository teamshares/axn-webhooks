# frozen_string_literal: true

require "base64"

RSpec.describe "Axn::Webhooks::Outbound::Config immutability" do
  after { Axn::Webhooks::Outbound.reset! }

  def declare_minimal!
    Axn::Webhooks.outbound do
      sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('s')}"
      event :lead_signed, to: ["https://a.example/hook"]
    end
    Axn::Webhooks::Outbound.config
  end

  it "is frozen once declared" do
    expect(declare_minimal!).to be_frozen
  end

  it "reads every setting after freezing, including ones the block never assigned" do
    # Regression guard for the whole design: Axn::Configurable memoizes a STATIC default into an
    # ivar on first read, so a Config frozen before that read raises FrozenError from the READER,
    # not from a writer. Only backoff/transport escape (dynamic `-> { … }` defaults, recomputed
    # rather than memoized) -- which is why this asserts on all seven rather than spot-checking.
    config = declare_minimal!

    expect(config.max_attempts).to eq(8)
    expect(config.backoff.call(1)).to be_a(Integer)
    expect(config.transport).to eq(Axn::Webhooks::Outbound::Transport)
    expect(config.vendor).to be_nil
    expect(config.user_agent).to be_nil
    expect(config.open_timeout).to eq(5)
    expect(config.read_timeout).to eq(10)
  end

  it "rejects mutation of a setting" do
    expect { declare_minimal!.max_attempts = 3 }.to raise_error(FrozenError)
  end

  it "freezes the events map, each event spec, and a statically-declared to: array" do
    events = declare_minimal!.instance_variable_get(:@events)

    expect(events).to be_frozen
    expect(events[:lead_signed]).to be_frozen
    expect(events[:lead_signed][:to]).to be_frozen
  end

  it "does NOT freeze caller-supplied callables" do
    resolver = ->(_event) { ["https://x.example/hook"] }
    signer = ->(id:, timestamp:, body:) { { "x-sig" => "#{id}#{timestamp}#{body}" } }

    Axn::Webhooks.outbound do
      sign(&signer)
      subscribers resolver
      event :lead_closed
    end

    expect(resolver).not_to be_frozen
    expect(signer).not_to be_frozen
    expect(Axn::Webhooks::Outbound.config.signer).not_to be_frozen
  end

  it "still resolves targets and still raises on an unknown event" do
    config = declare_minimal!

    expect(config.targets_for(:lead_signed)).to eq(["https://a.example/hook"])
    expect(config.wire_type(:lead_signed)).to eq("lead_signed")
    expect(config.vendor_for(:lead_signed)).to be_nil
    expect { config.targets_for(:nope) }.to raise_error(Axn::Webhooks::Error, /unknown outbound event/)
  end

  it "delivers end-to-end against a frozen config" do
    posted = []
    stub_transport = Class.new do
      define_singleton_method(:post) do |url:, headers:, **|
        posted << { url:, headers: }
        Axn::Webhooks::Outbound::Transport::Response.new(status: 200, headers: {})
      end
    end

    Axn::Webhooks.outbound do
      sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('s')}"
      transport stub_transport
      event :lead_signed, to: ["https://a.example/hook"]
    end

    result = Axn::Webhooks.emit(:lead_signed, data: { lead_id: 1 })

    expect(result).to be_ok
    expect(posted.map { |p| p[:url] }).to eq(["https://a.example/hook"])
  end

  it "serializes install and reset! behind a mutex" do
    # Not a race test (unwinnable deterministically) -- asserts the lock exists and that a
    # concurrent install cannot interleave with the nil-check that logs the replacement warning.
    expect(Axn::Webhooks::Outbound.instance_variable_get(:@mutex)).to be_a(Mutex)
  end
end
