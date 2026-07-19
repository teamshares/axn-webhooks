# frozen_string_literal: true

RSpec.describe Axn::Webhooks::Inbound::RespondContext do
  subject(:context) { described_class.new }

  it "builds a bare ack" do
    expect(context.ack).to eq(Axn::Webhooks::Response.ack)
  end

  it "builds a text response" do
    expect(context.text("hi")).to eq(Axn::Webhooks::Response.text("hi"))
  end

  it "builds an xml response" do
    expect(context.xml("<a/>")).to eq(Axn::Webhooks::Response.xml("<a/>"))
  end

  it "builds a json response" do
    expect(context.json({ ok: true })).to eq(Axn::Webhooks::Response.json({ ok: true }))
  end

  it "instance_execs a respond block so its bare helper calls resolve against this context" do
    block = ->(result) { text("seen: #{result}") }
    expect(context.instance_exec("ok", &block)).to eq(Axn::Webhooks::Response.text("seen: ok"))
  end
end
