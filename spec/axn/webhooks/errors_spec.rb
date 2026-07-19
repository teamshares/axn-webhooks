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
