# frozen_string_literal: true

require "rack"

# A malformed query/form body must fail SOFT before authentication (so an unauthenticated sender
# can't turn a 401 into a 500 plus an on_exception page per request), WITHOUT discarding the
# failure the post-verification parse step needs — or a verified request silently dispatches an
# empty event instead of being reported as UnparseableBody (Codex review).
RSpec.describe "unparseable params, before vs after verification" do
  let(:bad_form_body) { "a=%ZZ" }
  let(:deep_query) { "a#{'[a]' * 200}=1" }
  let(:reported) { [] }

  before do
    allow(Axn.config).to receive(:on_exception) { |e, **| reported << e.class }
    Axn::Webhooks::Inbound.reset!
    stub_const("ParamsHandler", Class.new do
      include Axn

      expects :event, allow_blank: true

      def call = (Thread.current[:event] = event)
    end)
    Thread.current[:event] = :never_ran
  end

  def form_env(body)
    Rack::MockRequest.env_for(
      "https://e/x", method: "POST", input: body, "CONTENT_TYPE" => "application/x-www-form-urlencoded"
    )
  end

  def json_env(body, query: nil)
    url = query ? "https://e/x?#{query}" : "https://e/x"
    Rack::MockRequest.env_for(url, method: "POST", input: body, "CONTENT_TYPE" => "application/json")
  end

  def declare(verified: true, parse: nil, **kwargs)
    Axn::Webhooks.inbound(:v) do
      verify { |_req| verified }
      dispatch(to: "ParamsHandler", parse:, **kwargs)
    end
    Axn::Webhooks::Inbound[:v]
  end

  describe "after verification (the parse step must see the failure)" do
    let(:params_parse) { :params.to_proc }

    it "reports UnparseableBody and does not dispatch an empty event" do
      status, = declare(parse: params_parse).call(form_env(bad_form_body))

      expect(Thread.current[:event]).to eq(:never_ran)
      expect(reported).to eq([Axn::Webhooks::UnparseableBody])
      expect(status).to eq(200) # the unparseable_status default
    end

    it "honors a per-endpoint unparseable_status" do
      status, = declare(parse: params_parse, unparseable_status: 400).call(form_env("#{deep_query}&b=2"))

      expect(status).to eq(400)
      expect(reported).to eq([Axn::Webhooks::UnparseableBody])
    end

    it "still dispatches normally when the form body parses (positive control)" do
      status, = declare(parse: params_parse).call(form_env("a=1"))

      expect(Thread.current[:event]).to eq({ "a" => "1" })
      expect(status).to eq(200)
      expect(reported).to be_empty
    end
  end

  describe "before verification (must stay soft)" do
    it "returns 401 without reporting, for a hostile body on an unverified request" do
      status, = declare(verified: false, parse: :params.to_proc).call(form_env(deep_query))

      expect(status).to eq(401)
      expect(reported).to be_empty
    end

    it "does not raise inside a custom verifier that reads params of a malformed body" do
      Axn::Webhooks.inbound(:v) do
        verify { |req| req.params["token"] == "ok" }
        dispatch to: "ParamsHandler"
      end

      status, = Axn::Webhooks::Inbound[:v].call(form_env(bad_form_body))

      expect(status).to eq(401)
      expect(reported).to be_empty
    end
  end

  describe "no downgrade of an unrelated parse" do
    # The signature covers the BODY, not the query string, so an attacker can append a hostile
    # query to a validly-signed request. That must not make it unparseable — a JSON parse never
    # consumed params, so the query's failure is irrelevant to it.
    # The consumption gate must be scoped to the PARSE CALL, not the request's lifetime: a custom
    # verifier or a challenge_required predicate legitimately reads params BEFORE the parse step,
    # and counting that read re-opens the very downgrade this gate exists to prevent (Codex review).
    it "is not downgraded when a custom VERIFIER read params first" do
      Axn::Webhooks.inbound(:v) do
        verify { |req| req.params["x"].nil? } # reads params, and verifies
        dispatch to: "ParamsHandler"          # default JSON parse — never reads params
      end

      status, = Axn::Webhooks::Inbound[:v].call(json_env('{"a":1}', query: deep_query))

      expect(Thread.current[:event]).to eq({ "a" => 1 })
      expect(status).to eq(200)
      expect(reported).to be_empty
    end

    it "still parses a valid JSON body when the query string is malformed" do
      status, = declare(parse: nil).call(json_env('{"a":1}', query: deep_query))

      expect(Thread.current[:event]).to eq({ "a" => 1 })
      expect(status).to eq(200)
      expect(reported).to be_empty
    end
  end
end
