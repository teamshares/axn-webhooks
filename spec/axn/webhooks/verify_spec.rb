# frozen_string_literal: true

RSpec.describe Axn::Webhooks::Verify do
  let(:request) { Axn::Webhooks::Request.new(raw_body: "body", headers: { "X-Token" => "ok" }) }

  it "succeeds when the verifier returns truthy" do
    result = described_class.call(request:, verifier: ->(req) { req.header("X-Token") == "ok" })
    expect(result).to be_ok
  end

  it "fails quietly (failure, not exception) on a signature mismatch" do
    result = described_class.call(request:, verifier: ->(_req) { false })
    expect(result).not_to be_ok
    expect(result.outcome).to be_failure
    expect(result.outcome).not_to be_exception
    expect(result.error).to include("verification failed")
  end

  # PRO-3141: a replay-window miss and an HMAC mismatch were both a bare `false` -> both
  # "signature mismatch" -> indistinguishable in the logs, and actively wrong for the replay case.
  describe "rejection reasons" do
    def rejected(reason, skew: nil, suggested_unit: nil)
      Axn::Webhooks::Signature::Check.new(ok: false, reason:, skew:, suggested_unit:)
    end

    def verify(check) = described_class.call(request:, verifier: ->(_req) { check })

    it "exposes the reason and stamps it as a bounded :reason dimension" do
      result = verify(rejected(:replay_window, skew: 600))
      expect(result.reason).to eq(:replay_window)
      expect(result.skew).to eq(600)
    end

    it "distinguishes a replay-window miss from an HMAC mismatch (the whole point)" do
      expect(verify(rejected(:replay_window, skew: 600)).reason).to eq(:replay_window)
      expect(verify(rejected(:signature_mismatch)).reason).to eq(:signature_mismatch)
    end

    it "names the replay cause in the message, with the skew, instead of claiming a mismatch" do
      result = verify(rejected(:replay_window, skew: 600))
      expect(result.error).to include("replay window")
      expect(result.error).to include("600")
      expect(result.error).not_to include("mismatch")
    end

    it "carries each remaining reason through with its own message" do
      expect(verify(rejected(:replay_timestamp_invalid)).error).to match(/timestamp/)
      expect(verify(rejected(:signature_missing)).error).to match(/missing/)
      expect(verify(rejected(:signature_mismatch)).error).to match(/mismatch/)
    end

    it "defaults a bare `false` from a custom verifier to :signature_mismatch" do
      result = described_class.call(request:, verifier: ->(_req) { false })
      expect(result.reason).to eq(:signature_mismatch)
      expect(result.skew).to be_nil
    end

    it "treats an ok Check as verified, not as a truthy object" do
      expect(described_class.call(request:, verifier: ->(_req) { Axn::Webhooks::Signature::OK })).to be_ok
    end

    it "leaves reason and skew unset on success" do
      result = described_class.call(request:, verifier: ->(_req) { true })
      expect(result).to be_ok
      expect(result.reason).to be_nil
      expect(result.skew).to be_nil
    end

    it "stamps :reason as a dimension on the settled call, alongside :vendor" do
      events = []
      callback = ->(*, payload) { events << payload }
      ActiveSupport::Notifications.subscribed(callback, "axn.call") do
        described_class.call(request:, verifier: ->(_req) { rejected(:replay_window, skew: 600) })
      end
      payload = events.find { |e| e[:action].instance_of?(described_class) }
      expect(payload[:dimensions]).to include(reason: "replay_window")
    end

    it "stamps :suggested_unit as its own dimension, splitting a misconfigured unit: from a real replay" do
      events = []
      callback = ->(*, payload) { events << payload }
      ActiveSupport::Notifications.subscribed(callback, "axn.call") do
        described_class.call(request:, verifier: ->(_req) { rejected(:replay_window, skew: -1, suggested_unit: :ms) })
        described_class.call(request:, verifier: ->(_req) { rejected(:replay_window, skew: 600) })
      end
      misconfigured, genuine = events.select { |e| e[:action].instance_of?(described_class) }.map { |e| e[:dimensions] }

      expect(misconfigured).to include(reason: "replay_window", suggested_unit: "ms")
      expect(genuine).to include(reason: "replay_window")
      expect(genuine).not_to have_key(:suggested_unit)
    end

    it "appends the suggested unit to the message, and omits it when there is none" do
      expect(verify(rejected(:replay_window, skew: -1, suggested_unit: :ms)).error).to include("would fit as unit: :ms")
      expect(verify(rejected(:replay_window, skew: 600)).error).not_to include("would fit")
    end

    it "omits the :reason dimension entirely on a verified request" do
      events = []
      callback = ->(*, payload) { events << payload }
      ActiveSupport::Notifications.subscribed(callback, "axn.call") do
        described_class.call(request:, verifier: ->(_req) { true })
      end
      payload = events.find { |e| e[:action].instance_of?(described_class) }
      expect(payload[:dimensions] || {}).not_to have_key(:reason)
    end
  end

  it "surfaces a verifier crash as an exception (loud), preserving the error" do
    boom = Class.new(StandardError)
    result = described_class.call(request:, verifier: ->(_req) { raise boom, "bad header" })
    expect(result).not_to be_ok
    expect(result.outcome).to be_exception
    expect(result.exception).to be_a(boom)
  end
end
