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

  describe Axn::Webhooks::Parsers do
    it "defaults to JSON and passes a proc through" do
      req = Axn::Webhooks::Request.new(raw_body: '{"k":"v"}', params: { "p" => 1 })
      expect(described_class.build(:json).call(req)).to eq("k" => "v")
      expect(described_class.build(nil).call(req)).to eq("k" => "v")
      # rubocop:disable Style/SymbolProc
      expect(described_class.build(proc { |r| r.params }).call(req)).to eq("p" => 1)
      # rubocop:enable Style/SymbolProc
    end

    it "rejects an unknown parse option" do
      expect { described_class.build(:xml) }.to raise_error(Axn::Webhooks::Error, /parse/)
    end
  end
end
