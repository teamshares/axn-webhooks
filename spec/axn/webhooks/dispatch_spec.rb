# frozen_string_literal: true

RSpec.describe Axn::Webhooks::Dispatch do
  def request(body) = Axn::Webhooks::Request.new(raw_body: body)
  let(:json_parse) { Axn::Webhooks::Parsers.build(:json) }

  # Real handler Axns exercising each outcome.
  before do
    stub_const("OkHandler", Class.new do
      include Axn

      expects :event, allow_blank: true
      def call = nil
    end)
    stub_const("FailHandler", Class.new do
      include Axn

      expects :event, allow_blank: true
      def call = fail!("we don't care")
    end)
    stub_const("BoomHandler", Class.new do
      include Axn

      expects :event, allow_blank: true
      def call = raise("handler crashed")
    end)
  end

  it "invokes the matched handler and succeeds when it succeeds" do
    router = Axn::Webhooks::Inbound::Router.new(to: "OkHandler")
    result = described_class.call(request: request('{"a":1}'), router:, parse: json_parse)
    expect(result).to be_ok
    expect(result.handler_result).to be_a(Axn::Result)
    expect(result.handler_result).to be_ok
  end

  it "settles as a quiet failure when the handler fail!s" do
    router = Axn::Webhooks::Inbound::Router.new(to: "FailHandler")
    result = described_class.call(request: request("{}"), router:, parse: json_parse)
    expect(result.outcome).to be_failure
    expect(result.outcome).not_to be_exception
    expect(result.error).to include("we don't care")
  end

  it "settles as a loud exception when the handler crashes" do
    router = Axn::Webhooks::Inbound::Router.new(to: "BoomHandler")
    result = described_class.call(request: request("{}"), router:, parse: json_parse)
    expect(result.outcome).to be_exception
    expect(result.exception).to be_a(RuntimeError)
  end

  it "settles as a loud exception for a missing handler class" do
    router = Axn::Webhooks::Inbound::Router.new(to: "Totally::Missing::Handler")
    result = described_class.call(request: request("{}"), router:, parse: json_parse)
    expect(result.outcome).to be_exception
    expect(result.exception).to be_a(NameError)
  end

  it "settles as a loud exception for an unmatched key with no otherwise" do
    router = Axn::Webhooks::Inbound::Router.new(on: ->(e) { e["t"] }, to: { "known" => "OkHandler" })
    result = described_class.call(request: request('{"t":"surprise"}'), router:, parse: json_parse)
    expect(result.outcome).to be_exception
  end

  it "acknowledges (success) an unmatched key when otherwise: :ack" do
    router = Axn::Webhooks::Inbound::Router.new(on: ->(e) { e["t"] }, to: { "known" => "OkHandler" }, otherwise: :ack)
    result = described_class.call(request: request('{"t":"surprise"}'), router:, parse: json_parse)
    expect(result).to be_ok
  end

  it "settles as a loud exception on a body that fails to parse" do
    router = Axn::Webhooks::Inbound::Router.new(to: "OkHandler")
    result = described_class.call(request: request("not json"), router:, parse: json_parse)
    expect(result.outcome).to be_exception
  end

  it "reports a handler crash to on_exception exactly once" do
    reports = []
    original = Axn.config.instance_variable_get(:@on_exception)
    Axn.config.instance_variable_set(:@on_exception, ->(e, **) { reports << e })
    begin
      router = Axn::Webhooks::Inbound::Router.new(to: "BoomHandler")
      result = described_class.call(request: request("{}"), router:, parse: json_parse)
      expect(result.outcome).to be_exception
      expect(reports.count { |e| e.is_a?(RuntimeError) }).to eq(1)
    ensure
      Axn.config.instance_variable_set(:@on_exception, original)
    end
  end

  describe Axn::Webhooks::Parsers do
    it "defaults to JSON and passes a proc through" do
      req = Axn::Webhooks::Request.new(raw_body: '{"k":"v"}', params: { "p" => 1 })
      expect(described_class.build(:json).call(req)).to eq("k" => "v")
      expect(described_class.build(nil).call(req)).to eq("k" => "v")
      expect(described_class.build(lambda(&:params)).call(req)).to eq("p" => 1)
    end

    it "rejects an unknown parse option" do
      expect { described_class.build(:xml) }.to raise_error(Axn::Webhooks::Error, /parse/)
    end
  end
end

RSpec.describe "Axn::Webhooks::Dispatch retry_later" do
  after { Axn::Webhooks::Inbound.reset! }

  it "catches a handler RetryLater as a non-exception result exposing retry_after" do
    stub_const("RetryingHandler", Class.new do
      include Axn

      expects :event, allow_blank: true
      def call = Axn::Webhooks.retry_later!(after: 45)
    end)

    router = Axn::Webhooks::Inbound::Router.new(to: "RetryingHandler")
    result = Axn::Webhooks::Dispatch.call(
      request: Axn::Webhooks::Request.new(raw_body: "{}"),
      router:, parse: Axn::Webhooks::Parsers.build(:json), mode: :sync
    )

    expect(result).to be_ok
    expect(result.outcome).not_to be_exception
    expect(result.retry_later).to be(true)
    expect(result.retry_after).to eq(45)
  end

  it "catches a bare handler RetryLater (no after:) as a non-exception result with retry_later true and retry_after nil" do
    stub_const("BareRetryingHandler", Class.new do
      include Axn

      expects :event, allow_blank: true
      def call = Axn::Webhooks.retry_later!
    end)

    router = Axn::Webhooks::Inbound::Router.new(to: "BareRetryingHandler")
    result = Axn::Webhooks::Dispatch.call(
      request: Axn::Webhooks::Request.new(raw_body: "{}"),
      router:, parse: Axn::Webhooks::Parsers.build(:json), mode: :sync
    )

    expect(result).to be_ok
    expect(result.outcome).not_to be_exception
    expect(result.retry_later).to be(true)
    expect(result.retry_after).to be_nil
  end
end
