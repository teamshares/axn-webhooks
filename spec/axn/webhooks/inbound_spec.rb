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

  it "requires a verify declaration when dispatch is declared (unverified dispatch is unsafe)" do
    expect { Axn::Webhooks.inbound(:x) { dispatch to: "SomeHandler" } }.to raise_error(Axn::Webhooks::Error, /verify/)
  end

  it "requires a verify declaration when both dispatch and challenge are declared" do
    expect do
      Axn::Webhooks.inbound(:x) do
        challenge ->(req) { req.params["challenge"] }
        dispatch to: "SomeHandler"
      end
    end.to raise_error(Axn::Webhooks::Error, /verify/)
  end

  it "registers fine with only a challenge declared and no verify (challenge-only endpoint)" do
    Axn::Webhooks.inbound(:x) { challenge ->(req) { req.params["challenge"] } }
    expect(Axn::Webhooks::Inbound.registered).to include(:x)
  end
end
