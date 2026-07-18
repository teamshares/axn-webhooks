# frozen_string_literal: true

RSpec.describe "Axn::Webhooks::Inbound::Endpoint#challenge_response" do
  after { Axn::Webhooks::Inbound.reset! }

  def get(params) = Axn::Webhooks::Request.new(raw_body: "", params:, http_method: "GET")

  it "echoes verbatim as a 200 text/plain response (Nylas-style, no guard)" do
    Axn::Webhooks.inbound(:nylas) do
      verify { |_req| true }
      challenge ->(req) { req.params["challenge"] }
    end
    response = Axn::Webhooks::Inbound[:nylas].challenge_response(get("challenge" => "xyz"))
    expect(response.status).to eq(200)
    expect(response.body).to eq("xyz")
    expect(response.headers).to eq("content-type" => "text/plain")
  end

  it "returns 400 when the challenge param is missing" do
    Axn::Webhooks.inbound(:nylas) { challenge ->(req) { req.params["challenge"] } }
    expect(Axn::Webhooks::Inbound[:nylas].challenge_response(get({})).status).to eq(400)
  end

  it "returns 403 when a guard (Meta's hub.verify_token) rejects the request" do
    Axn::Webhooks.inbound(:meta) do
      challenge ->(req) { req.params["hub.challenge"] }, if: ->(req) { req.params["hub.verify_token"] == "expected" }
    end
    response = Axn::Webhooks::Inbound[:meta].challenge_response(
      get("hub.challenge" => "xyz", "hub.verify_token" => "wrong"),
    )
    expect(response.status).to eq(403)
  end

  it "returns 200 when the guard accepts the request (Meta)" do
    Axn::Webhooks.inbound(:meta) do
      challenge ->(req) { req.params["hub.challenge"] }, if: ->(req) { req.params["hub.verify_token"] == "expected" }
    end
    response = Axn::Webhooks::Inbound[:meta].challenge_response(
      get("hub.challenge" => "xyz", "hub.verify_token" => "expected"),
    )
    expect(response.status).to eq(200)
    expect(response.body).to eq("xyz")
  end

  it "returns 405 when no challenge is declared" do
    Axn::Webhooks.inbound(:codat) { verify { |_req| true } }
    expect(Axn::Webhooks::Inbound[:codat].challenge_response(get({})).status).to eq(405)
  end

  it "returns 500 (reported) when the resolver crashes" do
    Axn::Webhooks.inbound(:broken) { challenge ->(_req) { raise "boom" } }
    expect(Axn::Webhooks::Inbound[:broken].challenge_response(get({})).status).to eq(500)
  end
end
