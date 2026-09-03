# frozen_string_literal: true

require "openssl"
require "rack"

RSpec.describe "Axn::Webhooks inbound invoked_via stamp" do
  after { Axn::Webhooks::Inbound.reset! }

  before do
    stub_const("Handlers", Module.new)
    stub_const("Handlers::Created", Class.new do
      include Axn

      expects :event
      exposes :seen_id
      def call = expose(seen_id: event.dig("data", "id"))
    end)
  end

  def capture_events(&)
    events = []
    callback = ->(*, payload) { events << payload }
    ActiveSupport::Notifications.subscribed(callback, "axn.call", &)
    events
  end

  def dimensions_for(klass, events)
    events.find { |e| e[:action].instance_of?(klass) }&.dig(:dimensions)
  end

  describe "#call (the Rack entrypoint)" do
    it "stamps invoked_via: :webhooks on every step of the POST pipeline, including the handler" do
      Axn::Webhooks.inbound(:vendor) do
        verify { |_req| true }
        dispatch on: ->(e) { e["type"] }, to: { "created" => "Handlers::Created" }
      end

      body = '{"type":"created","data":{"id":99}}'
      env = Rack::MockRequest.env_for("/webhooks/vendor", method: "POST", input: body,
                                                          "CONTENT_TYPE" => "application/json")

      events = capture_events { Axn::Webhooks::Inbound[:vendor].call(env) }

      [
        Axn::Webhooks::Inbound::BuildRequest,
        Axn::Webhooks::Verify,
        Axn::Webhooks::Dispatch,
        Handlers::Created,
      ].each do |klass|
        expect(dimensions_for(klass, events)).to eq(invoked_via: "webhooks"), "expected #{klass} to be stamped"
      end
    end

    it "stamps invoked_via: :webhooks on the GET/challenge branch too" do
      Axn::Webhooks.inbound(:vendor) { challenge ->(req) { req.params["challenge"] } }
      env = Rack::MockRequest.env_for("/webhooks/vendor?challenge=xyz", method: "GET", input: "")

      events = capture_events { Axn::Webhooks::Inbound[:vendor].call(env) }

      expect(dimensions_for(Axn::Webhooks::Inbound::BuildRequest, events)).to eq(invoked_via: "webhooks")
      expect(dimensions_for(Axn::Webhooks::Inbound::Challenge, events)).to eq(invoked_via: "webhooks")
    end

    it "stamps a declared respond block too" do
      Axn::Webhooks.inbound(:vendor) do
        verify { |_req| true }
        dispatch on: ->(e) { e["type"] }, to: { "created" => "Handlers::Created" }
        respond { |result| text(result.seen_id.to_s) }
      end

      body = '{"type":"created","data":{"id":99}}'
      env = Rack::MockRequest.env_for("/webhooks/vendor", method: "POST", input: body,
                                                          "CONTENT_TYPE" => "application/json")

      events = capture_events { Axn::Webhooks::Inbound[:vendor].call(env) }

      expect(dimensions_for(Axn::Webhooks::Respond, events)).to eq(invoked_via: "webhooks")
    end
  end

  describe "#handle (the direct verify+dispatch entrypoint)" do
    it "stamps invoked_via: :webhooks on Verify, Dispatch, and the handler" do
      Axn::Webhooks.inbound(:vendor) do
        verify { |_req| true }
        dispatch on: ->(e) { e["type"] }, to: { "created" => "Handlers::Created" }
      end

      body = '{"type":"created","data":{"id":99}}'
      request = Axn::Webhooks::Request.new(raw_body: body)

      events = capture_events { Axn::Webhooks::Inbound[:vendor].handle(request) }

      [Axn::Webhooks::Verify, Axn::Webhooks::Dispatch, Handlers::Created].each do |klass|
        expect(dimensions_for(klass, events)).to eq(invoked_via: "webhooks"), "expected #{klass} to be stamped"
      end
    end
  end

  # README documents #verify, #handle, and #to_response as a controller-driven alternative to
  # mounting the endpoint as a Rack app (see "drive it yourself from a controller") — each is
  # called directly, bypassing #call entirely, so each needs its own wrap rather than inheriting
  # one from #call. (Codex review, PR #31.)
  describe "#to_response (the controller-driven full-pipeline entrypoint)" do
    it "stamps invoked_via: :webhooks on Verify, Dispatch, Respond, and the handler when called directly" do
      Axn::Webhooks.inbound(:vendor) do
        verify { |_req| true }
        dispatch on: ->(e) { e["type"] }, to: { "created" => "Handlers::Created" }
        respond { |result| text(result.seen_id.to_s) }
      end

      body = '{"type":"created","data":{"id":99}}'
      request = Axn::Webhooks::Request.new(raw_body: body)

      events = capture_events { Axn::Webhooks::Inbound[:vendor].to_response(request) }

      [Axn::Webhooks::Verify, Axn::Webhooks::Dispatch, Axn::Webhooks::Respond, Handlers::Created].each do |klass|
        expect(dimensions_for(klass, events)).to eq(invoked_via: "webhooks"), "expected #{klass} to be stamped"
      end
    end
  end

  describe "#challenge_response (the controller-driven GET/challenge entrypoint)" do
    it "stamps invoked_via: :webhooks on Challenge when called directly" do
      Axn::Webhooks.inbound(:vendor) { challenge ->(req) { req.params["challenge"] } }
      request = Axn::Webhooks::Request.new(raw_body: "", params: { "challenge" => "xyz" })

      events = capture_events { Axn::Webhooks::Inbound[:vendor].challenge_response(request) }

      expect(dimensions_for(Axn::Webhooks::Inbound::Challenge, events)).to eq(invoked_via: "webhooks")
    end
  end

  describe "#verify (the standalone signature-check entrypoint)" do
    it "stamps invoked_via: :webhooks on Verify when called directly" do
      Axn::Webhooks.inbound(:vendor) { verify { |_req| true } }
      request = Axn::Webhooks::Request.new(raw_body: "{}")

      events = capture_events { Axn::Webhooks::Inbound[:vendor].verify(request) }

      expect(dimensions_for(Axn::Webhooks::Verify, events)).to eq(invoked_via: "webhooks")
    end
  end

  # DESIGN-NOTES.md documents #challenge_required? as public for controllers driving
  # #verify/#handle themselves — a third path to ChallengeRequired besides #to_response/#call.
  # (Codex review, PR #31, round 2.)
  describe "#challenge_required? (the standalone 401-challenge predicate)" do
    it "stamps invoked_via: :webhooks on ChallengeRequired when called directly" do
      Axn::Webhooks.inbound(:vendor) do
        verify { |_req| true }
        unauthorized_headers "WWW-Authenticate" => %(Basic realm="Webhook")
        challenge_required { |req| req.header("Authorization").to_s.strip.empty? }
      end
      request = Axn::Webhooks::Request.new(raw_body: "", headers: {})

      events = capture_events { Axn::Webhooks::Inbound[:vendor].challenge_required?(request) }

      expect(dimensions_for(Axn::Webhooks::Inbound::ChallengeRequired, events)).to eq(invoked_via: "webhooks")
    end
  end
end
