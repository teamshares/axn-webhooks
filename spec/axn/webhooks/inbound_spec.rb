# frozen_string_literal: true

RSpec.describe "Axn::Webhooks.inbound (registration + custom verify)" do
  after { Axn::Webhooks::Inbound.reset! }

  def request(token)
    Axn::Webhooks::Request.new(raw_body: "b", headers: { "X-Token" => token })
  end

  it "registers an endpoint verified by a custom block" do
    Axn::Webhooks.inbound(:demo) { verify { |req| req.header("X-Token") == "sekret" } }

    expect(Axn::Webhooks::Inbound.registered).to include(:demo)
    expect(Axn::Webhooks::Inbound[:demo].verify(request("sekret"))).to be_ok
    expect(Axn::Webhooks::Inbound[:demo].verify(request("nope"))).not_to be_ok
  end

  it "exposes the endpoint name" do
    Axn::Webhooks.inbound(:demo) { verify { |_req| true } }
    expect(Axn::Webhooks::Inbound[:demo].name).to eq(:demo)
  end

  it "raises a clear error looking up an unregistered vendor" do
    expect { Axn::Webhooks::Inbound[:missing] }.to raise_error(KeyError, /missing/)
  end

  it "requires a block" do
    expect { Axn::Webhooks.inbound(:x) }.to raise_error(ArgumentError, /block/)
  end

  it "requires a verify declaration inside the block" do
    expect { Axn::Webhooks.inbound(:x) { nil } }.to raise_error(Axn::Webhooks::Error, /verify/)
  end

  it "raises on an unknown strategy" do
    expect { Axn::Webhooks.inbound(:x) { verify :nope, secret: "s" } }
      .to raise_error(Axn::Webhooks::Error, /unknown verify strategy/)
  end

  it "requires a strategy or a block in verify" do
    expect { Axn::Webhooks.inbound(:x) { verify } }.to raise_error(Axn::Webhooks::Error, /strategy or a block/)
  end
end
