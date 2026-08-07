# frozen_string_literal: true

require "spec_helper"
require "rack/test"

RSpec.describe "Axn::Webhooks mounted in a real Rails app" do
  include Rack::Test::Methods

  def app
    Rails.application
  end

  before do
    stub_const("Handlers", Module.new) unless defined?(Handlers)
    stub_const("Handlers::Created", Class.new do
      include Axn

      expects :event
      exposes :seen_id
      def call = expose(seen_id: event.dig("data", "id"))
    end)
    Axn::Webhooks.inbound(:test_vendor) do
      verify :hmac, secret: "shh", signature: header("X-Sig")
      dispatch on: ->(e) { e["type"] }, to: { "created" => "Handlers::Created" }
    end
    Rails.application.reload_routes!
  end

  after { Axn::Webhooks::Inbound.reset! }

  it "verifies and dispatches a real signed POST through the full middleware stack" do
    body = '{"type":"created","data":{"id":42}}'
    sig = OpenSSL::HMAC.hexdigest("SHA256", "shh", body)
    header "X-Sig", sig
    header "Content-Type", "application/json"
    post "/webhooks/test_vendor", body
    expect(last_response.status).to eq(200)
    expect(last_response.body).to eq("")
  end

  it "401s a real request with a bad signature (rack.input stayed pristine through Rails' stack)" do
    header "X-Sig", "wrong"
    header "Content-Type", "application/json"
    post "/webhooks/test_vendor", '{"type":"created"}'
    expect(last_response.status).to eq(401)
  end

  context "with a form-urlencoded body (the Twilio/Slack shape)" do
    # Re-registers :test_vendor rather than adding an endpoint, since the dummy app's routes.rb
    # mounts that one name.
    before do
      stub_const("Handlers::Form", Class.new do
        include Axn

        expects :event
        exposes :seen
        def call = expose(seen: event["Body"])
      end)
      Axn::Webhooks.inbound(:test_vendor) do
        verify :hmac, secret: "shh", signature: header("X-Sig")
        dispatch to: "Handlers::Form", parse: :params.to_proc
      end
      Rails.application.reload_routes!
    end

    # Regression: Rails runs Rack::MethodOverride ahead of the router, and under Rack 3 its
    # Rack::Request#POST call consumes rack.input WITHOUT rewinding for form-urlencoded bodies. The
    # mount then saw an empty body, silently emptying both raw_body and params for exactly the
    # vendors that post forms. The JSON cases above can't catch it — MethodOverride only parses forms.
    it "still sees the raw body after Rack::MethodOverride has already parsed it" do
      body = "Body=hi&From=%2B15551234567"
      header "X-Sig", OpenSSL::HMAC.hexdigest("SHA256", "shh", body)
      header "Content-Type", "application/x-www-form-urlencoded"

      post "/webhooks/test_vendor", body

      expect(last_response.status).to eq(200)
    end

    it "401s a form POST whose signature does not match the (still intact) raw body" do
      header "X-Sig", "wrong"
      header "Content-Type", "application/x-www-form-urlencoded"

      post "/webhooks/test_vendor", "Body=hi"

      expect(last_response.status).to eq(401)
    end
  end
end
