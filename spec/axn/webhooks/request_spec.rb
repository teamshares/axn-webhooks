# frozen_string_literal: true

RSpec.describe Axn::Webhooks::Request do
  subject(:request) do
    described_class.new(
      raw_body: '{"a":1}',
      headers: { "Content-Type" => "application/json", "X-Merge-Webhook-Signature" => "abc" },
      params: { "challenge" => "xyz" },
      url: "https://example.com/webhooks/merge",
      http_method: "post",
    )
  end

  it "exposes the raw body verbatim" do
    expect(request.raw_body).to eq('{"a":1}')
  end

  it "looks up headers case-insensitively" do
    expect(request.header("x-merge-webhook-signature")).to eq("abc")
    expect(request.header("X-MERGE-WEBHOOK-SIGNATURE")).to eq("abc")
    expect(request.header("Content-Type")).to eq("application/json")
  end

  it "returns nil for an unknown header" do
    expect(request.header("X-Absent")).to be_nil
  end

  it "exposes params, url, and an upcased http_method" do
    expect(request.params).to eq("challenge" => "xyz")
    expect(request.url).to eq("https://example.com/webhooks/merge")
    expect(request.http_method).to eq("POST")
  end

  it "defaults params to empty and http_method to POST" do
    bare = described_class.new(raw_body: "")
    expect(bare.params).to eq({})
    expect(bare.http_method).to eq("POST")
    expect(bare.header("anything")).to be_nil
  end

  it "does not let callers mutate internal params" do
    expect { request.params["injected"] = true }.to raise_error(FrozenError)
  end

  it "handles nil headers without raising" do
    expect(described_class.new(raw_body: "x", headers: nil).header("anything")).to be_nil
  end

  it "exposes raw_body frozen to prevent accidental mutation" do
    expect(request.raw_body).to be_frozen
    expect { request.raw_body << "!" }.to raise_error(FrozenError)
  end

  describe ".from_rack" do
    def rack_env(**overrides)
      {
        "REQUEST_METHOD" => "POST",
        "PATH_INFO" => "/webhooks/codat",
        "QUERY_STRING" => "",
        "rack.input" => StringIO.new('{"a":1}'),
        "rack.url_scheme" => "https",
        "SERVER_NAME" => "example.com",
        "HTTP_HOST" => "example.com",
        "CONTENT_TYPE" => "application/json",
        "CONTENT_LENGTH" => "7",
        "HTTP_X_SIG" => "abc123",
      }.merge(overrides)
    end

    it "extracts the raw body verbatim from rack.input" do
      request = described_class.from_rack(rack_env)
      expect(request.raw_body).to eq('{"a":1}')
    end

    it "rewinds rack.input after reading, so downstream middleware can still read it" do
      env = rack_env
      described_class.from_rack(env)
      expect(env["rack.input"].read).to eq('{"a":1}')
    end

    it "maps HTTP_* env keys to header names, case-insensitively readable" do
      request = described_class.from_rack(rack_env)
      expect(request.header("X-Sig")).to eq("abc123")
    end

    it "maps CONTENT_TYPE and CONTENT_LENGTH to headers (not HTTP_*-prefixed in Rack)" do
      request = described_class.from_rack(rack_env)
      expect(request.header("Content-Type")).to eq("application/json")
      expect(request.header("Content-Length")).to eq("7")
    end

    it "extracts query-string params" do
      request = described_class.from_rack(rack_env("QUERY_STRING" => "challenge=xyz&a=1"))
      expect(request.params).to eq("challenge" => "xyz", "a" => "1")
    end

    it "sets params to the form body fields only, NOT merged with the query (Twilio's form body)" do
      # Rack::Request#url (used for `url`) already includes the query string. If `params` also
      # merged the query in, a URL-signing verifier doing `validate(req.url, req.params, sig)`
      # would double-count query params — once via url, once via params — and reject a validly
      # signed callback. So for a form POST, params must be form fields only; the query is still
      # reachable via `url`.
      body = "From=%2B15551234567&To=%2B15557654321"
      env = rack_env(
        "rack.input" => StringIO.new(body),
        "CONTENT_TYPE" => "application/x-www-form-urlencoded",
        "QUERY_STRING" => "extra=1",
      )
      request = described_class.from_rack(env)
      expect(request.params).to eq("From" => "+15551234567", "To" => "+15557654321")
      expect(request.url).to end_with("?extra=1") # query still reachable via url, not double-counted in params
      expect(request.raw_body).to eq(body) # verify still sees the untouched raw bytes
    end

    it "does not attempt to parse a non-form body as params, falling back to the query string" do
      request = described_class.from_rack(rack_env("QUERY_STRING" => "challenge=xyz")) # application/json body
      expect(request.params).to eq("challenge" => "xyz")
    end

    it "builds the full url including scheme, host, path, and query string" do
      request = described_class.from_rack(rack_env("QUERY_STRING" => "a=1"))
      expect(request.url).to eq("https://example.com/webhooks/codat?a=1")
    end

    it "omits the query string from url when there is none" do
      request = described_class.from_rack(rack_env)
      expect(request.url).to eq("https://example.com/webhooks/codat")
    end

    it "preserves the SCRIPT_NAME mount prefix in url (Rack mount / Rails `mount ... at:`)" do
      # When mounted (e.g. `mount Inbound[:vendor], at: "/webhooks/codat"`), Rack puts the mount
      # prefix in SCRIPT_NAME and leaves only the remainder in PATH_INFO. A URL built from
      # PATH_INFO alone would drop the prefix, breaking URL-based verifiers like Twilio's.
      request = described_class.from_rack(rack_env("SCRIPT_NAME" => "/webhooks/codat", "PATH_INFO" => "/rest"))
      expect(request.url).to eq("https://example.com/webhooks/codat/rest")
    end

    it "reads the HTTP method" do
      request = described_class.from_rack(rack_env("REQUEST_METHOD" => "GET"))
      expect(request.http_method).to eq("GET")
    end

    it "tolerates a non-rewindable rack.input instead of raising (bare Rack::Builder / streaming server)" do
      # A Rack 3 stack without Rack::RewindableInput::Middleware in front may hand us an input
      # that's readable but NOT rewindable. We've already captured the full body into raw_body
      # before ever touching rewind, so a non-rewindable input shouldn't turn a valid webhook
      # into a 500 — the rewind is just best-effort courtesy for downstream middleware.
      non_rewindable_input = Class.new do
        def initialize(body) = @io = StringIO.new(body)
        def read(...) = @io.read(...)
      end.new('{"a":1}')

      expect(non_rewindable_input).not_to respond_to(:rewind)

      request = nil
      expect { request = described_class.from_rack(rack_env("rack.input" => non_rewindable_input)) }.not_to raise_error
      expect(request.raw_body).to eq('{"a":1}')
    end
  end
end
