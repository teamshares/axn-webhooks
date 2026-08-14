# frozen_string_literal: true

require "rack"

# PRO-3143: a correctly-signed request whose body doesn't parse used to map to a 500, and vendors
# retry non-2xx (Lob for 5 days, then disables the endpoint) — so the gem's answer to "this body is
# malformed" was to invite the sender to deliver it again forever. Retrying can never fix a malformed
# body, so the outcome is terminal: report it (you want to know a vendor is sending garbage) and ack.
RSpec.describe "Axn::Webhooks::Inbound unparseable body" do
  before do
    stub_const("Handlers", Module.new)
    stub_const("Handlers::Created", Class.new do
      include Axn

      expects :event, allow_blank: true
      def call = nil
    end)
    stub_const("Handlers::Boom", Class.new do
      include Axn

      expects :event, allow_blank: true
      def call = raise("handler crashed")
    end)
  end

  after do
    Axn::Webhooks::Inbound.reset!
    Axn::Webhooks.reset_config!
  end

  def req(body) = Axn::Webhooks::Request.new(raw_body: body)

  describe "the default mapping" do
    it "acks an empty body rather than 500ing it (the reported repro)" do
      Axn::Webhooks.inbound(:vendor) do
        verify { |_req| true }
        dispatch to: "Handlers::Created"
      end
      response = Axn::Webhooks::Inbound[:vendor].to_response(req(""))
      expect(response.status).to eq(200)
      expect(response.body).to eq("")
    end

    it "acks a malformed body over the full Rack contract too" do
      Axn::Webhooks.inbound(:vendor) do
        verify { |_req| true }
        dispatch to: "Handlers::Created"
      end
      env = Rack::MockRequest.env_for("/webhooks/vendor", method: "POST", input: "not json",
                                                          "CONTENT_TYPE" => "application/json")
      status, _headers, body = Axn::Webhooks::Inbound[:vendor].call(env)
      expect(status).to eq(200)
      expect(body).to eq([""])
    end

    it "still reports the malformed body to on_exception exactly once" do
      reports = []
      original = Axn.config.instance_variable_get(:@on_exception)
      Axn.config.instance_variable_set(:@on_exception, ->(e, **) { reports << e })
      begin
        Axn::Webhooks.inbound(:vendor) do
          verify { |_req| true }
          dispatch to: "Handlers::Created"
        end
        Axn::Webhooks::Inbound[:vendor].to_response(req("not json"))
        expect(reports.count { |e| e.is_a?(Axn::Webhooks::UnparseableBody) }).to eq(1)
      ensure
        Axn.config.instance_variable_set(:@on_exception, original)
      end
    end

    it "still 500s a handler crash — only the parse step became terminal" do
      Axn::Webhooks.inbound(:vendor) do
        verify { |_req| true }
        dispatch to: "Handlers::Boom"
      end
      expect(Axn::Webhooks::Inbound[:vendor].to_response(req("{}")).status).to eq(500)
    end

    it "still 401s an unverified request, malformed body or not (verify comes first)" do
      Axn::Webhooks.inbound(:vendor) do
        verify { |_req| false }
        dispatch to: "Handlers::Created"
      end
      expect(Axn::Webhooks::Inbound[:vendor].to_response(req("not json")).status).to eq(401)
    end

    it "acks without enqueueing on an async endpoint — parse runs before the async branch" do
      stub_const("AsyncHandler", Class.new do
        def self.calls = (@calls ||= [])
        def self.call_async(**kwargs) = calls << kwargs
      end)
      Axn::Webhooks.inbound(:vendor) do
        verify { |_req| true }
        dispatch to: "AsyncHandler", mode: :async
      end
      expect(Axn::Webhooks::Inbound[:vendor].to_response(req("not json")).status).to eq(200)
      expect(AsyncHandler.calls).to be_empty
    end

    it "does not run a declared respond block (there is no handler result to read)" do
      Axn::Webhooks.inbound(:vendor) do
        verify { |_req| true }
        dispatch to: "Handlers::Created"
        respond { |result| text(result.no_such_exposure) }
      end
      expect(Axn::Webhooks::Inbound[:vendor].to_response(req("not json")).status).to eq(200)
    end
  end

  describe "static_respond" do
    # Dropbox Sign reads the BODY, not the status: without the exact expected text it treats the
    # delivery as failed and redelivers — which would rebuild the very retry loop this fixes.
    it "renders the declared static body, so a body-keyed vendor sees a real ack" do
      Axn::Webhooks.inbound(:vendor) do
        verify { |_req| true }
        dispatch to: "Handlers::Created"
        static_respond { text("Hello API Event Received") }
      end
      response = Axn::Webhooks::Inbound[:vendor].to_response(req("not json"))
      expect(response.status).to eq(200)
      expect(response.body).to eq("Hello API Event Received")
    end

    it "keeps the declared body but restamps its status when a non-200 is configured" do
      Axn::Webhooks.configure { |c| c.unparseable_status = 400 }
      Axn::Webhooks.inbound(:vendor) do
        verify { |_req| true }
        dispatch to: "Handlers::Created"
        static_respond { text("Hello API Event Received") }
      end
      response = Axn::Webhooks::Inbound[:vendor].to_response(req("not json"))
      expect(response.status).to eq(400)
      expect(response.body).to eq("Hello API Event Received")
      expect(response.headers["content-type"]).to eq("text/plain")
    end

    it "maps a raise inside the static_respond block to a 500, as on every other row" do
      Axn::Webhooks.inbound(:vendor) do
        verify { |_req| true }
        dispatch to: "Handlers::Created"
        static_respond { text(no_such_helper) }
      end
      expect(Axn::Webhooks::Inbound[:vendor].to_response(req("not json")).status).to eq(500)
    end
  end

  describe "the unparseable_status knob" do
    it "defaults to 200 — the only status every vendor reads as terminal" do
      expect(Axn::Webhooks.config.unparseable_status).to eq(200)
    end

    it "honors a configured status for vendors that treat 4xx as terminal" do
      Axn::Webhooks.configure { |c| c.unparseable_status = 400 }
      Axn::Webhooks.inbound(:vendor) do
        verify { |_req| true }
        dispatch to: "Handlers::Created"
      end
      expect(Axn::Webhooks::Inbound[:vendor].to_response(req("not json")).status).to eq(400)
    end

    it "lets a per-endpoint declaration win over the configured default" do
      Axn::Webhooks.configure { |c| c.unparseable_status = 400 }
      Axn::Webhooks.inbound(:vendor) do
        verify { |_req| true }
        dispatch to: "Handlers::Created", unparseable_status: 200
      end
      expect(Axn::Webhooks::Inbound[:vendor].to_response(req("not json")).status).to eq(200)
    end

    it "can be set back to 500 to restore the pre-PRO-3143 retry-inviting behavior" do
      Axn::Webhooks.inbound(:vendor) do
        verify { |_req| true }
        dispatch to: "Handlers::Created", unparseable_status: 500
      end
      expect(Axn::Webhooks::Inbound[:vendor].to_response(req("not json")).status).to eq(500)
    end

    it "rejects a non-Integer configured value" do
      expect { Axn::Webhooks.configure { |c| c.unparseable_status = "200" } }.to raise_error(ArgumentError, /unparseable_status/)
    end

    it "rejects a configured value outside the HTTP status range" do
      expect { Axn::Webhooks.configure { |c| c.unparseable_status = 999 } }.to raise_error(ArgumentError, /unparseable_status/)
    end

    it "rejects a bad per-endpoint value at declaration time" do
      expect do
        Axn::Webhooks.inbound(:vendor) do
          verify { |_req| true }
          dispatch to: "Handlers::Created", unparseable_status: :ack
        end
      end.to raise_error(Axn::Webhooks::Error, /unparseable_status/)
    end
  end
end
