# frozen_string_literal: true

RSpec.describe Axn::Webhooks do
  it "has a version number" do
    expect(Axn::Webhooks::VERSION).not_to be_nil
  end
end
