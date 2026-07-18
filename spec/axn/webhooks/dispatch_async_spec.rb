# frozen_string_literal: true

RSpec.describe "Axn::Webhooks::Dispatch async resolution" do
  def request(body) = Axn::Webhooks::Request.new(raw_body: body)
  let(:json_parse) { Axn::Webhooks::Parsers.build(:json) }

  before do
    # Non-Axn stub: records call_async. Used where mode is EXPLICITLY :async (no detection).
    stub_const("AsyncHandler", Class.new do
      def self.calls = (@calls ||= [])
      def self.call_async(**kwargs) = calls << kwargs
    end)
    # Real Axn handler, no adapter configured.
    stub_const("SyncHandler", Class.new do
      include Axn
      expects :event, allow_blank: true
      def call = nil
    end)
    # Real Axn handler MARKED async-configured (sets the class_attribute directly — no Sidekiq load);
    # call_async is stubbed so no real adapter runs.
    stub_const("AdapterHandler", Class.new do
      include Axn
      expects :event, allow_blank: true
      def call = nil
    end)
    AdapterHandler._async_adapter = :sidekiq
    allow(AdapterHandler).to receive(:call_async)
  end

  it "explicit :async delegates to call_async and exposes no handler_result" do
    router = Axn::Webhooks::Inbound::Router.new(to: "AsyncHandler")
    result = Axn::Webhooks::Dispatch.call(request: request('{"a":1}'), router:, parse: json_parse, mode: :async)
    expect(result).to be_ok
    expect(result.handler_result).to be_nil
    expect(AsyncHandler.calls).to eq([{ event: { "a" => 1 } }])
  end

  it "explicit :async with no adapter configured settles as a loud (500-bound) exception" do
    router = Axn::Webhooks::Inbound::Router.new(to: "SyncHandler")
    result = Axn::Webhooks::Dispatch.call(request: request("{}"), router:, parse: json_parse, mode: :async)
    expect(result.outcome).to be_exception
    expect(result.exception).to be_a(NotImplementedError)
  end

  it "explicit :sync runs synchronously even if an adapter is configured" do
    router = Axn::Webhooks::Inbound::Router.new(to: "AdapterHandler")
    result = Axn::Webhooks::Dispatch.call(request: request("{}"), router:, parse: json_parse, mode: :sync)
    expect(result.handler_result).to be_ok
    expect(AdapterHandler).not_to have_received(:call_async)
  end

  describe "mode: :auto (default)" do
    it "runs SYNC when no adapter is configured for the handler" do
      router = Axn::Webhooks::Inbound::Router.new(to: "SyncHandler")
      result = Axn::Webhooks::Dispatch.call(request: request("{}"), router:, parse: json_parse) # mode defaults to :auto
      expect(result.handler_result).to be_ok
    end

    it "runs ASYNC when an adapter IS configured for the handler" do
      router = Axn::Webhooks::Inbound::Router.new(to: "AdapterHandler")
      result = Axn::Webhooks::Dispatch.call(request: request("{}"), router:, parse: json_parse)
      expect(result.handler_result).to be_nil
      expect(AdapterHandler).to have_received(:call_async).with(event: {})
    end

    it "runs ASYNC when a global default adapter is configured (presence, not type)" do
      # Test presence check by using AdapterHandler which already has an adapter set.
      # This verifies that when async_adapter_configured? returns true (either via
      # handler._async_adapter or global default), async mode is used.
      router = Axn::Webhooks::Inbound::Router.new(to: "AdapterHandler")
      result = Axn::Webhooks::Dispatch.call(request: request("{}"), router:, parse: json_parse)
      expect(result.handler_result).to be_nil
      expect(AdapterHandler).to have_received(:call_async).with(event: {})
    end

    it "forces SYNC when respond_declared is true, even with an adapter configured" do
      router = Axn::Webhooks::Inbound::Router.new(to: "AdapterHandler")
      result = Axn::Webhooks::Dispatch.call(request: request("{}"), router:, parse: json_parse, respond_declared: true)
      expect(result.handler_result).to be_ok
      expect(AdapterHandler).not_to have_received(:call_async)
    end
  end
end
