# frozen_string_literal: true

RSpec.describe Axn::Webhooks::Handler do
  it "includes Axn" do
    klass = Class.new { include Axn::Webhooks::Handler }
    expect(klass.ancestors).to include(Axn)
  end

  it "registers RetryLater as a fails_on match, so it's NOT reported via on_exception" do
    klass = Class.new do
      include Axn::Webhooks::Handler

      expects :event, allow_blank: true
      def call = Axn::Webhooks.retry_later!(after: 30)
    end

    expect(Axn.config).not_to receive(:on_exception)

    result = klass.call(event: {})
    expect(result).not_to be_ok # RetryLater lands in the failure bucket
    expect(result.outcome).not_to be_exception
    expect(result.outcome).to be_failure
    expect(result.exception).to be_a(Axn::Webhooks::RetryLater)
    expect(result.exception.retry_after).to eq(30)
  end

  it "contrasts with a plain include Axn handler, where the same RetryLater IS reported via on_exception" do
    klass = Class.new do
      include Axn

      expects :event, allow_blank: true
      def call = Axn::Webhooks.retry_later!(after: 30)
    end

    expect(Axn.config).to receive(:on_exception).once

    result = klass.call(event: {})
    expect(result).not_to be_ok
    expect(result.outcome).to be_exception # unhandled -> exception bucket -> paged
  end

  it "does not disturb a handler's normal success/failure paths" do
    ok_klass = Class.new do
      include Axn::Webhooks::Handler

      expects :event, allow_blank: true
      def call = nil
    end
    expect(ok_klass.call(event: {})).to be_ok

    fail_klass = Class.new do
      include Axn::Webhooks::Handler

      expects :event, allow_blank: true
      def call = fail!("nope")
    end
    result = fail_klass.call(event: {})
    expect(result).not_to be_ok
    expect(result.outcome).to be_failure
    expect(result.outcome).not_to be_exception
  end
end
