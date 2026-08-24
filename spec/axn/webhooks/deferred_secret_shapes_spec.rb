# frozen_string_literal: true

# `Resolvers.resolve` defers only a Resolver, a Symbol, or a Proc — anything else is used as a
# literal. The boot-time secret checks must exempt exactly that set: exempting every
# `respond_to?(:call)` object let a credential-provider object or a Method declare cleanly and then
# fail EVERY request, because resolve never called it (Codex review).
RSpec.describe "which secret shapes are deferred to request time" do
  let(:provider) do
    Class.new do
      def call = "s3cret"
    end.new
  end

  before { Axn::Webhooks::Inbound.reset! }

  it "rejects a non-Proc #call responder at declaration, rather than every request" do
    # Captured to a local: `inbound` blocks are instance_exec'd, so a `let` is not in scope.
    secret = provider
    expect do
      Axn::Webhooks.inbound(:h) { verify :hmac, secret:, signature: header("X-Sig") }
    end.to raise_error(ArgumentError, /non-empty String/)
  end

  it "rejects a Method object at declaration" do
    expect do
      Axn::Webhooks.inbound(:h) { verify :hmac, secret: "x".method(:to_s), signature: header("X-Sig") }
    end.to raise_error(ArgumentError, /non-empty String/)
  end

  it "rejects a non-Proc #call responder for :standard_webhooks at declaration" do
    secret = provider
    expect do
      Axn::Webhooks.inbound(:s) { verify :standard_webhooks, secret: }
    end.to raise_error(ArgumentError, /whsec_<base64>/)
  end

  # Positive controls: the three shapes resolve actually defers must still be accepted.
  it "still defers a lambda" do
    expect { Axn::Webhooks.inbound(:h) { verify :hmac, secret: -> { "s" }, signature: header("X-Sig") } }
      .not_to raise_error
  end

  it "still defers a proc" do
    expect { Axn::Webhooks.inbound(:h) { verify :hmac, secret: proc { "s" }, signature: header("X-Sig") } }
      .not_to raise_error
  end

  it "still defers a Resolver" do
    expect do
      Axn::Webhooks.inbound(:h) { verify :hmac, secret: header("X-Secret"), signature: header("X-Sig") }
    end.not_to raise_error
  end
end
