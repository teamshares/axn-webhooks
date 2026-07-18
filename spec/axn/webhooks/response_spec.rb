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

  it "supports value equality" do
    expect(described_class.text("hi")).to eq(described_class.text("hi"))
    expect(described_class.text("hi")).not_to eq(described_class.text("bye"))
  end
end
