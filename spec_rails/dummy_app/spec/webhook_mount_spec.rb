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
end
