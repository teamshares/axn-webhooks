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

    it "merges form-urlencoded body params into params (Twilio's form body)" do
      body = "From=%2B15551234567&To=%2B15557654321"
      env = rack_env(
        "rack.input" => StringIO.new(body),
        "CONTENT_TYPE" => "application/x-www-form-urlencoded",
        "QUERY_STRING" => "extra=1",
      )
      request = described_class.from_rack(env)
      expect(request.params).to eq("From" => "+15551234567", "To" => "+15557654321", "extra" => "1")
      expect(request.raw_body).to eq(body) # verify still sees the untouched raw bytes
    end

    it "does not attempt to parse a non-form body as params" do
      request = described_class.from_rack(rack_env) # application/json body
      expect(request.params).to eq({})
    end

    it "builds the full url including scheme, host, path, and query string" do
      request = described_class.from_rack(rack_env("QUERY_STRING" => "a=1"))
      expect(request.url).to eq("https://example.com/webhooks/codat?a=1")
    end

    it "omits the query string from url when there is none" do
      request = described_class.from_rack(rack_env)
      expect(request.url).to eq("https://example.com/webhooks/codat")
    end

    it "reads the HTTP method" do
      request = described_class.from_rack(rack_env("REQUEST_METHOD" => "GET"))
      expect(request.http_method).to eq("GET")
    end
  end
end
