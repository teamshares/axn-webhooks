# frozen_string_literal: true

RSpec.describe "Axn::Webhooks::Dispatch async resolution" do
  def request(body) = Axn::Webhooks::Request.new(raw_body: body)
  let(:json_parse) { Axn::Webhooks::Parsers.build(:json) }

  # Stubs the global default adapter for these tests. Also neutralizes Dispatch's own
  # `_ensure_default_async_configured` (invoked on every `Dispatch.new`, since Dispatch is
  # itself a real Axn action subject to the same auto-configure-on-first-instantiation
  # behavior as any handler): without this, the FIRST test in the suite to stub a truthy
  # global default would cause Dispatch to eagerly `async :sidekiq` on ITSELF and blow up
  # with the real adapter's `LoadError` (Sidekiq/ActiveJob aren't test deps) — unrelated to
  # what's under test here, which is the HANDLER's own async resolution.
  def stub_global_default_adapter(adapter)
    allow(Axn.config).to receive(:_default_async_adapter).and_return(adapter)
    allow(Axn::Webhooks::Dispatch).to receive(:_ensure_default_async_configured)
  end

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
    expect(result.exception).to be_a(Axn::Webhooks::Error)
  end

  it "explicit :async on an explicitly-disabled handler settles as a catchable exception, " \
     "even with a global default adapter configured" do
    stub_global_default_adapter(:sidekiq)
    SyncHandler._async_adapter = false
    router = Axn::Webhooks::Inbound::Router.new(to: "SyncHandler")

    result = nil
    expect do
      result = Axn::Webhooks::Dispatch.call(request: request("{}"), router:, parse: json_parse, mode: :async)
    end.not_to raise_error

    expect(result.outcome).to be_exception
    expect(result.exception).to be_a(Axn::Webhooks::Error)
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

    it "runs ASYNC when a global default adapter is configured and the handler has no explicit setting" do
      stub_global_default_adapter(:sidekiq)
      allow(SyncHandler).to receive(:call_async)
      router = Axn::Webhooks::Inbound::Router.new(to: "SyncHandler")
      result = Axn::Webhooks::Dispatch.call(request: request("{}"), router:, parse: json_parse)
      expect(result.handler_result).to be_nil
      expect(SyncHandler).to have_received(:call_async).with(event: {})
    end

    it "runs SYNC when the handler is explicitly disabled, even with a global default adapter configured" do
      stub_global_default_adapter(:sidekiq)
      SyncHandler._async_adapter = false
      router = Axn::Webhooks::Inbound::Router.new(to: "SyncHandler")

      result = nil
      expect do
        result = Axn::Webhooks::Dispatch.call(request: request("{}"), router:, parse: json_parse)
      end.not_to raise_error

      expect(result.handler_result).to be_ok
    end

    it "forces SYNC when respond_declared is true, even with an adapter configured" do
      router = Axn::Webhooks::Inbound::Router.new(to: "AdapterHandler")
      result = Axn::Webhooks::Dispatch.call(request: request("{}"), router:, parse: json_parse, respond_declared: true)
      expect(result.handler_result).to be_ok
      expect(AdapterHandler).not_to have_received(:call_async)
    end

    it "runs SYNC when the handler's adapter is explicitly disabled (false is not 'configured')" do
      SyncHandler._async_adapter = false
      router = Axn::Webhooks::Inbound::Router.new(to: "SyncHandler")
      result = Axn::Webhooks::Dispatch.call(request: request("{}"), router:, parse: json_parse) # mode defaults to :auto
      expect(result.handler_result).to be_ok
    end
  end

  describe "per-route async: flag (PRO-2952)" do
    it "an entry with async: true enqueues even when respond_declared forces the endpoint sync" do
      router = Axn::Webhooks::Inbound::Router.new(
        on: ->(e) { e["type"] },
        to: { "block_actions" => { call: "AsyncHandler", async: true } },
      )
      result = Axn::Webhooks::Dispatch.call(
        request: request('{"type":"block_actions"}'), router:, parse: json_parse, respond_declared: true,
      )
      expect(result).to be_ok
      expect(result.handler_result).to be_nil
      expect(AsyncHandler.calls).to eq([{ event: { "type" => "block_actions" } }])
    end

    it "an entry with async: false runs sync even when endpoint mode: :async" do
      router = Axn::Webhooks::Inbound::Router.new(
        on: ->(e) { e["type"] },
        to: { "view_submission" => { call: "AdapterHandler", async: false } },
      )
      result = Axn::Webhooks::Dispatch.call(
        request: request('{"type":"view_submission"}'), router:, parse: json_parse, mode: :async,
      )
      expect(result.handler_result).to be_ok
      expect(AdapterHandler).not_to have_received(:call_async)
    end

    it "an entry with no async: still honors the respond_declared sync default" do
      router = Axn::Webhooks::Inbound::Router.new(
        on: ->(e) { e["type"] },
        to: { "view_submission" => { call: "AdapterHandler" } },
      )
      result = Axn::Webhooks::Dispatch.call(
        request: request('{"type":"view_submission"}'), router:, parse: json_parse, respond_declared: true,
      )
      expect(result.handler_result).to be_ok
      expect(AdapterHandler).not_to have_received(:call_async)
    end

    it "async: true on an adapter-less Axn handler settles as a reported exception" do
      router = Axn::Webhooks::Inbound::Router.new(
        on: ->(e) { e["type"] },
        to: { "block_actions" => { call: "SyncHandler", async: true } },
      )
      result = Axn::Webhooks::Dispatch.call(
        request: request('{"type":"block_actions"}'), router:, parse: json_parse, respond_declared: true,
      )
      expect(result.outcome).to be_exception
      expect(result.exception).to be_a(Axn::Webhooks::Error)
    end
  end
end
