# frozen_string_literal: true

RSpec.describe Axn::Webhooks::Outbound::Transport do
  it "exposes a Data Response value" do
    resp = described_class::Response.new(status: 204, headers: { "x" => "y" })
    expect(resp.status).to eq(204)
    expect(resp.headers).to eq("x" => "y")
  end

  it "declares a retryable-network-error set including Timeout::Error" do
    expect(described_class::RETRYABLE_NETWORK_ERRORS).to include(Timeout::Error)
  end

  # No `webrick` dev dependency is available in this Ruby (removed from default gems in 3.0+, and
  # not declared in the Gemfile), so — per the task brief's fallback — this exercises `.post`
  # against a stubbed `Net::HTTP#request` rather than a real server.
  describe ".post" do
    let(:received_request) { {} }
    let(:fake_response) do
      instance_double(Net::HTTPResponse, code: "202", to_hash: { "retry-after" => ["30"] })
    end

    before do
      allow_any_instance_of(Net::HTTP).to receive(:request) do |_http, request|
        received_request[:body] = request.body
        received_request[:headers] = request.each_header.to_h
        fake_response
      end
    end

    it "POSTs the body + headers and returns status + response headers" do
      resp = described_class.post(
        url: "http://127.0.0.1:9999/hook",
        body: '{"a":1}',
        headers: { "content-type" => "application/json", "webhook-signature" => "v1,x" },
      )

      expect(resp.status).to eq(202)
      expect(resp.headers["retry-after"]).to eq("30")
      expect(received_request[:body]).to eq('{"a":1}')
      expect(received_request[:headers]["webhook-signature"]).to eq("v1,x")
    end

    it "defaults open_timeout to 5 and read_timeout to 10 seconds" do
      captured_http = nil
      allow(Net::HTTP).to receive(:new).and_wrap_original do |original, *args|
        captured_http = original.call(*args)
        captured_http
      end

      described_class.post(url: "http://127.0.0.1:9999/hook", body: "{}", headers: {})

      expect(captured_http.open_timeout).to eq(5)
      expect(captured_http.read_timeout).to eq(10)
    end

    it "honors explicit open_timeout/read_timeout overrides" do
      captured_http = nil
      allow(Net::HTTP).to receive(:new).and_wrap_original do |original, *args|
        captured_http = original.call(*args)
        captured_http
      end

      described_class.post(url: "http://127.0.0.1:9999/hook", body: "{}", headers: {}, open_timeout: 1, read_timeout: 2)

      expect(captured_http.open_timeout).to eq(1)
      expect(captured_http.read_timeout).to eq(2)
    end
  end
end
