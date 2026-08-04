# frozen_string_literal: true

RSpec.describe "Axn::Webhooks.retry_later!" do
  it "raises RetryLater carrying the retry-after seconds" do
    expect { Axn::Webhooks.retry_later!(after: 120) }
      .to raise_error(Axn::Webhooks::RetryLater) { |e| expect(e.retry_after).to eq(120) }
  end

  it "RetryLater is an Axn::Webhooks::Error" do
    expect(Axn::Webhooks::RetryLater.new).to be_a(Axn::Webhooks::Error)
  end
end

# PRO-2997: Axn::Error is core's public-error boundary — a MODULE, so tagging costs this gem's
# hierarchy no ancestry (Error stays a StandardError) while making `rescue Axn::Error` in a consuming
# app catch webhook errors alongside core's own.
RSpec.describe "Axn::Webhooks::Error as part of the Axn::Error boundary" do
  it "is rescuable as Axn::Error" do
    expect { raise Axn::Webhooks::Error, "boom" }.to raise_error(Axn::Error, "boom")
  end

  it "keeps StandardError as its superclass (the tag adds no base class)" do
    expect(Axn::Webhooks::Error.superclass).to eq(StandardError)
  end

  it "extends the tag to subclasses, so RetryLater is rescuable as Axn::Error too" do
    expect { Axn::Webhooks.retry_later! }.to raise_error(Axn::Error)
  end
end
