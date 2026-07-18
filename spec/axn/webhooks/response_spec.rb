# frozen_string_literal: true

RSpec.describe Axn::Webhooks::Response do
  it "defaults to a bare 200 ack with no body and no headers" do
    response = described_class.ack
    expect(response.status).to eq(200)
    expect(response.body).to eq("")
    expect(response.headers).to eq({})
  end

  it "supports a custom status on ack" do
    expect(described_class.ack(status: 201).status).to eq(201)
  end

  it "builds a text/plain body" do
    response = described_class.text("Hello API Event Received")
    expect(response.status).to eq(200)
    expect(response.body).to eq("Hello API Event Received")
    expect(response.headers).to eq("content-type" => "text/plain")
  end

  it "builds an xml body" do
    response = described_class.xml("<Response></Response>")
    expect(response.body).to eq("<Response></Response>")
    expect(response.headers).to eq("content-type" => "application/xml")
  end

  it "lets a caller override the default Content-Type header (case-insensitively; emitted lowercase)" do
    response = described_class.text("hi", headers: { "Content-Type" => "text/csv" })
    expect(response.headers).to eq("content-type" => "text/csv")
  end

  it "lower-cases header keys for Rack 3 compliance" do
    response = described_class.new(headers: { "X-Custom-Header" => "v" })
    expect(response.headers.keys).to eq(["x-custom-header"])
  end

  it "stringifies a non-String body" do
    expect(described_class.new(body: 200).body).to eq("200")
  end

  it "is frozen" do
    expect(described_class.ack).to be_frozen
  end

  it "has deeply frozen headers" do
    response = described_class.new(headers: { "X-Custom" => "value" })
    expect { response.headers["X"] = "y" }.to raise_error(FrozenError)
  end

  it "freezes header values so a caller's mutable value can't mutate the response" do
    response = described_class.new(headers: { "X-Custom" => +"value" })
    expect(response.headers["x-custom"]).to be_frozen
    expect { response.headers["x-custom"] << "!" }.to raise_error(FrozenError)
  end

  it "deep-freezes Array (multi-value) header values including their elements" do
    response = described_class.new(headers: { "Set-Cookie" => [+"a=1", +"b=2"] })
    expect(response.headers["set-cookie"]).to be_frozen
    expect(response.headers["set-cookie"].first).to be_frozen
    expect { response.headers["set-cookie"].first << "; Secure" }.to raise_error(FrozenError)
  end

  it "has deeply frozen body" do
    response = described_class.text("hello")
    expect { response.body << " world" }.to raise_error(FrozenError)
  end

  it "does not freeze the caller's own body string (copies before freezing)" do
    caller_body = +"caller owned"
    described_class.new(body: caller_body)
    expect(caller_body).not_to be_frozen
    expect { caller_body << "!" }.not_to raise_error
  end

  it "supports value equality" do
    expect(described_class.text("hi")).to eq(described_class.text("hi"))
    expect(described_class.text("hi")).not_to eq(described_class.text("bye"))
  end

  it "renders as a Rack triple" do
    response = described_class.text("hi", status: 201)
    expect(response.to_rack).to eq([201, { "content-type" => "text/plain" }, ["hi"]])
  end

  it "returns mutable headers from to_rack so Rails/Rack middleware can set headers" do
    response = described_class.text("hi")
    rack_headers = response.to_rack[1]
    expect(rack_headers).not_to be_frozen
    expect(rack_headers).not_to equal(response.headers)
    rack_headers["x-custom"] = "value"
    expect(rack_headers["x-custom"]).to eq("value")
  end

  it "passes Array (multi-value) header values through unchanged in to_rack for Rack 3" do
    response = described_class.new(headers: { "Set-Cookie" => ["a=1", "b=2"] })
    rack_headers = response.to_rack[1]
    expect(rack_headers["set-cookie"]).to eq(["a=1", "b=2"])
    expect(rack_headers["set-cookie"]).to be_a(Array)
    # Response#headers still holds the frozen Array internally
    expect(response.headers["set-cookie"]).to be_a(Array)
  end

  it "returns mutable Array header values from to_rack so middleware can append (e.g., Rack::Utils.set_cookie_header!)" do
    response = described_class.new(headers: { "Set-Cookie" => ["a=1", "b=2"] })
    rack_headers = response.to_rack[1]
    expect(rack_headers["set-cookie"]).not_to be_frozen
    expect { rack_headers["set-cookie"] << "c=3" }.not_to raise_error
    expect(rack_headers["set-cookie"]).to eq(["a=1", "b=2", "c=3"])
  end

  it "keeps Response's own header Array values frozen for immutability" do
    response = described_class.new(headers: { "Set-Cookie" => ["a=1", "b=2"] })
    expect(response.headers["set-cookie"]).to be_frozen
    expect { response.headers["set-cookie"] << "c=3" }.to raise_error(FrozenError)
  end

  it "produces Rack::Lint-valid multi-value (Array) headers" do
    require "rack/lint"
    response = described_class.new(headers: { "Set-Cookie" => ["a=1", "b=2"] })
    triple = response.to_rack
    app = Rack::Lint.new(->(_env) { triple })
    expect { app.call(Rack::MockRequest.env_for("/")) }.not_to raise_error
  end
end
