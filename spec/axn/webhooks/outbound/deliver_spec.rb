# frozen_string_literal: true

require "base64"

RSpec.describe Axn::Webhooks::Outbound::Deliver do
  after { Axn::Webhooks::Outbound.reset! }

  # A recording fake transport; `script` maps call-index -> Response or a raise.
  def fake_transport(*responses)
    Class.new do
      define_method(:calls) { @calls ||= [] }
      define_method(:post) do |url:, body:, headers:|
        calls << { url:, body:, headers: }
        outcome = responses[calls.size - 1] || responses.last
        raise outcome if outcome.is_a?(Class) || outcome.is_a?(Exception)

        outcome
      end
    end.new
  end

  def ok(status, headers = {}) = Axn::Webhooks::Outbound::Transport::Response.new(status:, headers:)

  def declare!(transport:, max_attempts: 8, backoff: ->(_n) { 60 })
    t = transport
    ma = max_attempts
    bo = backoff
    Axn::Webhooks.outbound do
      sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('secret')}"
      transport t
      max_attempts ma
      backoff bo
      event :lead_signed, to: ["https://os.example/hook"]
    end
  end

  let(:kwargs) { { url: "https://os.example/hook", webhook_id: "msg_1", body: '{"a":1}', event: "lead_signed" } }

  it "signs per attempt and succeeds on 2xx" do
    transport = fake_transport(ok(202))
    declare!(transport:)

    result = described_class.call(**kwargs)

    expect(result).to be_ok
    headers = transport.calls.first[:headers]
    expect(headers["webhook-id"]).to eq("msg_1")
    expect(headers["webhook-signature"]).to start_with("v1,")
    expect(headers["content-type"]).to eq("application/json")
  end

  it "quietly fails (no reschedule) on a permanent 4xx" do
    transport = fake_transport(ok(422))
    declare!(transport:)
    allow(described_class).to receive(:call_async)

    result = described_class.call(**kwargs)

    expect(result).not_to be_ok
    expect(result.outcome).to be_failure
    expect(result.outcome).not_to be_exception
    expect(described_class).not_to have_received(:call_async)
  end

  it "reschedules with backoff on a retryable 5xx when attempts remain" do
    transport = fake_transport(ok(503))
    declare!(transport:, backoff: ->(n) { n * 100 })
    allow(described_class).to receive(:call_async)

    described_class.call(**kwargs, attempt: 1)

    expect(described_class).to have_received(:call_async).with(
      hash_including(webhook_id: "msg_1", attempt: 2, _async: { wait: 100 }),
    )
  end

  it "honors Retry-After when it exceeds the computed backoff" do
    transport = fake_transport(ok(429, "retry-after" => "300"))
    declare!(transport:, backoff: ->(_n) { 60 })
    allow(described_class).to receive(:call_async)

    described_class.call(**kwargs, attempt: 1)

    expect(described_class).to have_received(:call_async).with(hash_including(_async: { wait: 300 }))
  end

  it "reschedules (does not raise) on a retryable network error" do
    transport = fake_transport(Timeout::Error)
    declare!(transport:, backoff: ->(_n) { 60 })
    allow(described_class).to receive(:call_async)

    result = described_class.call(**kwargs, attempt: 1)

    expect(result).to be_ok # rescheduled, current attempt acked
    expect(described_class).to have_received(:call_async).with(hash_including(attempt: 2))
  end

  it "reports once and fails (no reschedule) when retries are exhausted" do
    transport = fake_transport(ok(500))
    declare!(transport:, max_attempts: 3)
    allow(described_class).to receive(:call_async)
    expect(Axn.config).to receive(:on_exception).at_least(:once)

    result = described_class.call(**kwargs, attempt: 3)

    expect(result).not_to be_ok
    expect(described_class).not_to have_received(:call_async)
  end

  it "lets an unexpected (non-network) transport exception propagate as a loud exception" do
    transport = fake_transport(ArgumentError.new("boom"))
    declare!(transport:)

    result = described_class.call(**kwargs)
    expect(result.outcome).to be_exception
  end
end
