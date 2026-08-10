# frozen_string_literal: true

RSpec.describe "Axn::Webhooks::Inbound static_respond" do
  before do
    stub_const("Handlers", Module.new)
    stub_const("Handlers::Created", Class.new do
      include Axn

      expects :event, allow_blank: true
      def call = nil
    end)
    stub_const("Handlers::FailsQuietly", Class.new do
      include Axn

      expects :event, allow_blank: true
      def call = fail!("we don't care")
    end)
    stub_const("Handlers::Boom", Class.new do
      include Axn

      expects :event, allow_blank: true
      def call = raise("handler crashed")
    end)
    stub_const("AsyncHandler", Class.new do
      def self.calls = (@calls ||= [])
      def self.call_async(**kwargs) = calls << kwargs
    end)
  end

  after { Axn::Webhooks::Inbound.reset! }

  def req(body) = Axn::Webhooks::Request.new(raw_body: body)

  describe "registration" do
    it "rejects declaring both respond and static_respond at declaration time" do
      expect do
        Axn::Webhooks.inbound(:bad) do
          verify { |_req| true }
          dispatch to: "Handlers::Created"
          respond { |result| text(result.to_s) }
          static_respond { text("Hello API Event Received") }
        end
      end.to raise_error(Axn::Webhooks::Error, /declares both `respond` and `static_respond`/)
    end

    it "allows static_respond alone" do
      expect do
        Axn::Webhooks.inbound(:ok) do
          verify { |_req| true }
          dispatch to: "Handlers::Created"
          static_respond { text("Hello API Event Received") }
        end
      end.not_to raise_error
    end
  end

  describe "rendering" do
    it "renders the static body on a genuine sync handler success" do
      Axn::Webhooks.inbound(:vendor) do
        verify { |_req| true }
        dispatch to: "Handlers::Created" # mode: :auto, no adapter configured -> sync
        static_respond { text("Hello API Event Received") }
      end
      response = Axn::Webhooks::Inbound[:vendor].to_response(req("{}"))
      expect(response.status).to eq(200)
      expect(response.body).to eq("Hello API Event Received")
    end

    it "renders the static body on an unmatched event (otherwise: :ack)" do
      Axn::Webhooks.inbound(:vendor) do
        verify { |_req| true }
        dispatch on: ->(e) { e["t"] }, to: { "known" => "Handlers::Created" }, otherwise: :ack
        static_respond { text("Hello API Event Received") }
      end
      response = Axn::Webhooks::Inbound[:vendor].to_response(req('{"t":"surprise"}'))
      expect(response.status).to eq(200)
      expect(response.body).to eq("Hello API Event Received")
    end

    it "renders the static body on a handler business fail!" do
      Axn::Webhooks.inbound(:vendor) do
        verify { |_req| true }
        dispatch to: "Handlers::FailsQuietly"
        static_respond { text("Hello API Event Received") }
      end
      response = Axn::Webhooks::Inbound[:vendor].to_response(req("{}"))
      expect(response.status).to eq(200)
      expect(response.body).to eq("Hello API Event Received")
    end

    it "renders the static body for a verify-only endpoint (no dispatch declared)" do
      Axn::Webhooks.inbound(:vendor) do
        verify { |_req| true }
        static_respond { text("Hello API Event Received") }
      end
      response = Axn::Webhooks::Inbound[:vendor].to_response(req(""))
      expect(response.status).to eq(200)
      expect(response.body).to eq("Hello API Event Received")
    end

    it "does not render the static body on a handler crash (still maps to 500)" do
      Axn::Webhooks.inbound(:vendor) do
        verify { |_req| true }
        dispatch to: "Handlers::Boom"
        static_respond { text("Hello API Event Received") }
      end
      response = Axn::Webhooks::Inbound[:vendor].to_response(req("{}"))
      expect(response.status).to eq(500)
      expect(response.body).not_to eq("Hello API Event Received")
    end

    it "does not render the static body on a verify failure (still 401)" do
      Axn::Webhooks.inbound(:vendor) do
        verify { |_req| false }
        dispatch to: "Handlers::Created"
        static_respond { text("Hello API Event Received") }
      end
      response = Axn::Webhooks::Inbound[:vendor].to_response(req("{}"))
      expect(response.status).to eq(401)
      expect(response.body).not_to eq("Hello API Event Received")
    end

    it "does not render the static body on retry_later! (still 503)" do
      stub_const("Handlers::RetriesLater", Class.new do
        include Axn::Webhooks::Handler

        expects :event, allow_blank: true
        def call = Axn::Webhooks.retry_later!(after: 45)
      end)
      Axn::Webhooks.inbound(:vendor) do
        verify { |_req| true }
        dispatch to: "Handlers::RetriesLater"
        static_respond { text("Hello API Event Received") }
      end
      response = Axn::Webhooks::Inbound[:vendor].to_response(req("{}"))
      expect(response.status).to eq(503)
      expect(response.headers["retry-after"]).to eq("45")
      expect(response.body).not_to eq("Hello API Event Received")
    end

    it "renders the static body when mode: :async enqueues successfully" do
      Axn::Webhooks.inbound(:vendor) do
        verify { |_req| true }
        dispatch to: "AsyncHandler", mode: :async
        static_respond { text("Hello API Event Received") }
      end
      response = Axn::Webhooks::Inbound[:vendor].to_response(req("{}"))
      expect(response.status).to eq(200)
      expect(response.body).to eq("Hello API Event Received")
      expect(AsyncHandler.calls).to eq([{ event: {} }])
    end

    it "renders the static body on a per-route async(...) entry" do
      Axn::Webhooks.inbound(:vendor) do
        verify { |_req| true }
        dispatch on: ->(e) { e["t"] }, to: { "a" => async("AsyncHandler") }
        static_respond { text("Hello API Event Received") }
      end
      response = Axn::Webhooks::Inbound[:vendor].to_response(req('{"t":"a"}'))
      expect(response.status).to eq(200)
      expect(response.body).to eq("Hello API Event Received")
      expect(AsyncHandler.calls).to eq([{ event: { "t" => "a" } }])
    end

    it "does not force sync dispatch, unlike respond" do
      Handlers::Created._async_adapter = :sidekiq
      allow(Handlers::Created).to receive(:call_async)
      Axn::Webhooks.inbound(:vendor) do
        verify { |_req| true }
        dispatch to: "Handlers::Created" # mode: :auto + adapter configured -> would be async
        static_respond { text("Hello API Event Received") }
      end
      response = Axn::Webhooks::Inbound[:vendor].to_response(req("{}"))
      expect(response.body).to eq("Hello API Event Received")
      expect(Handlers::Created).to have_received(:call_async)
    ensure
      Handlers::Created._async_adapter = nil
    end

    it "does not raise when combined with explicit mode: :async" do
      expect do
        Axn::Webhooks.inbound(:vendor) do
          verify { |_req| true }
          dispatch to: "AsyncHandler", mode: :async
          static_respond { text("Hello API Event Received") }
        end
      end.not_to raise_error
    end

    it "maps a raise inside the static_respond block to a reported 500" do
      Axn::Webhooks.inbound(:vendor) do
        verify { |_req| true }
        dispatch to: "Handlers::Created"
        static_respond { text(no_such_helper) }
      end
      response = nil
      expect { response = Axn::Webhooks::Inbound[:vendor].to_response(req("{}")) }.not_to raise_error
      expect(response.status).to eq(500)
    end

    it "maps a static_respond block that returns a non-Response to a 500" do
      Axn::Webhooks.inbound(:vendor) do
        verify { |_req| true }
        dispatch to: "Handlers::Created"
        static_respond { "a raw string, not a Response" }
      end
      response = nil
      expect { response = Axn::Webhooks::Inbound[:vendor].to_response(req("{}")) }.not_to raise_error
      expect(response).to be_a(Axn::Webhooks::Response)
      expect(response.status).to eq(500)
    end
  end
end
