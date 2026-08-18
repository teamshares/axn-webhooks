# frozen_string_literal: true

require "openssl"
require "base64"

RSpec.describe Axn::Webhooks::Signature do
  # RFC 4231 Test Case 2 — a published, independent HMAC-SHA256 vector.
  let(:secret)  { "Jefe" }
  let(:payload) { "what do ya want for nothing?" }
  let(:hex)     { "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843" }

  # The verdicts a custom `verify` block returns rather than computing. Each has to be a Check (so
  # Verify reads its `reason` instead of falling back to :signature_mismatch), frozen (so a caller
  # can't mutate a shared verdict), and carry the reason its name claims.
  describe "the exported verdicts" do
    {
      OK: [true, nil],
      MISMATCH: [false, :signature_mismatch],
      SIGNATURE_MISSING: [false, :signature_missing],
      CREDENTIALS_MISSING: [false, :credentials_missing],
      CREDENTIALS_MISMATCH: [false, :credentials_mismatch],
    }.each do |name, (ok, reason)|
      it "#{name} is a frozen Check reporting ok?=#{ok} / #{reason.inspect}" do
        verdict = described_class.const_get(name)

        expect(verdict).to be_a(described_class::Check)
        expect(verdict).to be_frozen
        expect(verdict.ok?).to be(ok)
        expect(verdict.reason).to eq(reason)
        expect(verdict.skew).to be_nil
        expect(verdict.suggested_unit).to be_nil
      end
    end

    it "names a reason that Verify knows how to report" do
      %i[MISMATCH SIGNATURE_MISSING CREDENTIALS_MISSING CREDENTIALS_MISMATCH].each do |name|
        reason = described_class.const_get(name).reason

        expect(described_class::REASONS).to include(reason)
        expect(Axn::Webhooks::Verify::MESSAGES).to have_key(reason)
      end
    end
  end

  describe ".compute" do
    it "produces the RFC 4231 hex vector for sha256" do
      expect(described_class.compute(secret:, payload:, digest: :sha256, encoding: :hex)).to eq(hex)
    end

    it "encodes as standard and url-safe base64 of the same digest bytes" do
      raw = OpenSSL::HMAC.digest("SHA256", secret, payload)
      expect(described_class.compute(secret:, payload:, encoding: :base64)).to eq(Base64.strict_encode64(raw))
      expect(described_class.compute(secret:, payload:, encoding: :base64_urlsafe)).to eq(Base64.urlsafe_encode64(raw))
    end

    it "supports sha1 and md5 digests" do
      expect(described_class.compute(secret:, payload:, digest: :sha1))
        .to eq(OpenSSL::HMAC.hexdigest("SHA1", secret, payload))
      expect(described_class.compute(secret:, payload:, digest: :md5))
        .to eq(OpenSSL::HMAC.hexdigest("MD5", secret, payload))
    end
  end

  describe ".hmac" do
    it "accepts a matching signature" do
      expect(described_class.hmac(secret:, payload:, signature: hex)).to be(true)
    end

    it "rejects a tampered signature" do
      bad = hex.sub(/.\z/, hex[-1] == "0" ? "1" : "0")
      expect(described_class.hmac(secret:, payload:, signature: bad)).to be(false)
    end

    it "rejects a wrong secret" do
      expect(described_class.hmac(secret: "wrong", payload:, signature: hex)).to be(false)
    end

    it "rejects nil / empty signatures without raising" do
      expect(described_class.hmac(secret:, payload:, signature: nil)).to be(false)
      expect(described_class.hmac(secret:, payload:, signature: "")).to be(false)
    end

    it "strips a prefix before comparing (Slack-style v0=)" do
      expect(described_class.hmac(secret:, payload:, signature: "v0=#{hex}", prefix: "v0=")).to be(true)
      expect(described_class.hmac(secret:, payload:, signature: hex, prefix: "v0=")).to be(false)
    end

    it "passes if ANY candidate in a multi-signature header matches (key rotation)" do
      expect(described_class.hmac(secret:, payload:, signature: "deadbeef #{hex}")).to be(true)
      expect(described_class.hmac(secret:, payload:, signature: "deadbeef,#{hex}")).to be(true)
      expect(described_class.hmac(secret:, payload:, signature: "deadbeef cafebabe")).to be(false)
    end

    it "verifies a base64-urlsafe signature (Merge-style)" do
      raw = OpenSSL::HMAC.digest("SHA256", secret, payload)
      sig = Base64.urlsafe_encode64(raw)
      expect(described_class.hmac(secret:, payload:, signature: sig, encoding: :base64_urlsafe)).to be(true)
    end
  end

  describe ".hmac_check" do
    let(:now) { Time.at(1_700_000_000) }

    it "accepts, with no reason and no skew" do
      check = described_class.hmac_check(secret:, payload:, signature: hex)
      expect(check).to be_ok
      expect(check.reason).to be_nil
      expect(check.skew).to be_nil
    end

    it "names a tampered signature :signature_mismatch" do
      bad = hex.sub(/.\z/, hex[-1] == "0" ? "1" : "0")
      check = described_class.hmac_check(secret:, payload:, signature: bad)
      expect(check).not_to be_ok
      expect(check.reason).to eq(:signature_mismatch)
    end

    it "names a nil / empty signature :signature_missing, distinctly from a mismatch" do
      expect(described_class.hmac_check(secret:, payload:, signature: nil).reason).to eq(:signature_missing)
      expect(described_class.hmac_check(secret:, payload:, signature: "").reason).to eq(:signature_missing)
    end

    it "names a stale-but-validly-signed request :replay_window, carrying the signed skew" do
      check = described_class.hmac_check(secret:, payload:, signature: hex, timestamp: (now - 600).to_i,
                                         tolerance: 300, now:)
      expect(check).not_to be_ok
      expect(check.reason).to eq(:replay_window)
      expect(check.skew).to eq(600)
    end

    it "signs skew negative for a future-dated timestamp" do
      check = described_class.hmac_check(secret:, payload:, signature: hex, timestamp: (now + 600).to_i,
                                         tolerance: 300, now:)
      expect(check.reason).to eq(:replay_window)
      expect(check.skew).to eq(-600)
    end

    it "names a pinned unit: that doesn't fit via suggested_unit, alongside the skew it produced" do
      # An epoch-ms timestamp read as seconds dates the request ~1.8 TRILLION seconds in the FUTURE
      # (hence a negative skew). Post-PRO-3142 this only happens under an explicitly pinned unit:,
      # since the AUTO default would infer :ms — so suggested_unit names the misconfiguration.
      check = described_class.hmac_check(secret:, payload:, signature: hex, timestamp: now.to_i * 1_000,
                                         tolerance: 300, now:, unit: :seconds)
      expect(check.reason).to eq(:replay_window)
      expect(check.skew).to be < -1_000_000_000_000
      expect(check.suggested_unit).to eq(:ms)
    end

    it "leaves suggested_unit nil for a genuine replay (no scale rescues it)" do
      check = described_class.hmac_check(secret:, payload:, signature: hex, timestamp: (now - 600).to_i,
                                         tolerance: 300, now:)
      expect(check.reason).to eq(:replay_window)
      expect(check.suggested_unit).to be_nil
    end

    it "infers the unit by default, so a fresh epoch-ms timestamp is not a replay at all" do
      check = described_class.hmac_check(secret:, payload:, signature: hex, timestamp: now.to_i * 1_000,
                                         tolerance: 300, now:)
      expect(check).to be_ok
    end

    it "names a missing / unparseable timestamp :replay_timestamp_invalid, not :replay_window" do
      expect(described_class.hmac_check(secret:, payload:, signature: hex, timestamp: nil, tolerance: 300, now:).reason)
        .to eq(:replay_timestamp_invalid)
      expect(described_class.hmac_check(secret:, payload:, signature: hex, timestamp: "nope", tolerance: 300,
                                        now:).reason)
        .to eq(:replay_timestamp_invalid)
    end

    it "checks the replay window before the signature, so a stale request reports the replay cause" do
      check = described_class.hmac_check(secret:, payload:, signature: "deadbeef", timestamp: (now - 600).to_i,
                                         tolerance: 300, now:)
      expect(check.reason).to eq(:replay_window)
    end

    it "raises ArgumentError for an unsupported unit, like .hmac" do
      expect { described_class.hmac_check(secret:, payload:, signature: hex, unit: :fortnights) }
        .to raise_error(ArgumentError, /unsupported unit/)
    end
  end

  describe ".skew" do
    let(:now) { Time.at(1_700_000_000) }

    it "is positive for a past timestamp and negative for a future one" do
      expect(described_class.skew(timestamp: (now - 90).to_i, now:)).to eq(90)
      expect(described_class.skew(timestamp: (now + 90).to_i, now:)).to eq(-90)
    end

    it "applies unit: before subtracting" do
      expect(described_class.skew(timestamp: (now - 90).to_i * 1_000, now:, unit: :ms)).to eq(90)
    end

    it "is nil for a missing or unparseable timestamp" do
      expect(described_class.skew(timestamp: nil, now:)).to be_nil
      expect(described_class.skew(timestamp: "nope", now:)).to be_nil
    end
  end

  describe ".secure_compare" do
    it "is true only for identical strings" do
      expect(described_class.secure_compare("abc", "abc")).to be(true)
      expect(described_class.secure_compare("abc", "abd")).to be(false)
    end

    it "is false (never raises) for length mismatch or nil" do
      expect(described_class.secure_compare("abc", "abcd")).to be(false)
      expect(described_class.secure_compare(nil, "abc")).to be(false)
      expect(described_class.secure_compare("abc", nil)).to be(false)
    end
  end

  describe "replay window" do
    let(:secret)  { "Jefe" }
    let(:payload) { "what do ya want for nothing?" }
    let(:hex)     { "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843" }
    let(:now)     { Time.at(1_700_000_000) }

    it "accepts a signature whose timestamp is within tolerance" do
      ts = (now - 60).to_i
      expect(described_class.hmac(secret:, payload:, signature: hex, timestamp: ts, tolerance: 300, now:)).to be(true)
    end

    it "rejects a signature whose timestamp is outside tolerance (replay)" do
      ts = (now - 600).to_i
      expect(described_class.hmac(secret:, payload:, signature: hex, timestamp: ts, tolerance: 300, now:)).to be(false)
    end

    it "rejects future timestamps beyond tolerance (bidirectional)" do
      ts = (now + 600).to_i
      expect(described_class.hmac(secret:, payload:, signature: hex, timestamp: ts, tolerance: 300, now:)).to be(false)
    end

    it "rejects a missing or unparseable timestamp when tolerance is set" do
      expect(described_class.hmac(secret:, payload:, signature: hex, timestamp: nil, tolerance: 300, now:)).to be(false)
      expect(described_class.hmac(secret:, payload:, signature: hex, timestamp: "not-a-time", tolerance: 300, now:)).to be(false)
    end

    it "accepts a String epoch and a Time" do
      expect(described_class.within_tolerance?(timestamp: (now - 10).to_i.to_s, tolerance: 300, now:)).to be(true)
      expect(described_class.within_tolerance?(timestamp: now - 10, tolerance: 300, now:)).to be(true)
    end

    it "ignores the window entirely when tolerance is nil" do
      expect(described_class.hmac(secret:, payload:, signature: hex, timestamp: nil, tolerance: nil, now:)).to be(true)
    end

    it "pins the inclusive boundary: exactly at tolerance is accepted" do
      ts = (now - 300).to_i
      expect(described_class.hmac(secret:, payload:, signature: hex, timestamp: ts, tolerance: 300, now:)).to be(true)
    end

    it "rejects timestamps just outside the inclusive boundary" do
      ts = (now - 301).to_i
      expect(described_class.hmac(secret:, payload:, signature: hex, timestamp: ts, tolerance: 300, now:)).to be(false)
    end

    it "accepts an epoch-ms timestamp within tolerance when unit: :ms" do
      ts_ms = (now - 60).to_i * 1_000
      expect(described_class.hmac(secret:, payload:, signature: hex, timestamp: ts_ms, tolerance: 300, now:, unit: :ms)).to be(true)
    end

    it "rejects an epoch-ms timestamp outside tolerance when unit: :ms" do
      ts_ms = (now - 600).to_i * 1_000
      expect(described_class.hmac(secret:, payload:, signature: hex, timestamp: ts_ms, tolerance: 300, now:, unit: :ms)).to be(false)
    end

    it "treats :ms and :milliseconds identically" do
      ts_ms = ((now - 60).to_i * 1_000).to_s
      expect(described_class.within_tolerance?(timestamp: ts_ms, tolerance: 300, now:, unit: :ms)).to be(true)
      expect(described_class.within_tolerance?(timestamp: ts_ms, tolerance: 300, now:, unit: :milliseconds)).to be(true)
    end

    it "supports :microseconds" do
      ts_us = (now - 60).to_i * 1_000_000
      expect(described_class.within_tolerance?(timestamp: ts_us, tolerance: 300, now:, unit: :microseconds)).to be(true)
    end

    it "floors (does not round) the sub-second remainder when converting ms->s" do
      # 299.999s ago is still within tolerance: 300 -- accepted.
      ts_ms_within = (now.to_i * 1_000) - 299_999
      expect(described_class.hmac(secret:, payload:, signature: hex, timestamp: ts_ms_within, tolerance: 300, now:,
                                  unit: :ms)).to be(true)

      # 300.001s ago -- a mere 1ms past the boundary -- floors up to a full 301s and is rejected.
      # Rounding (rather than flooring) would incorrectly round this down to 300s and accept it.
      ts_ms_outside = (now.to_i * 1_000) - 300_001
      expect(described_class.hmac(secret:, payload:, signature: hex, timestamp: ts_ms_outside, tolerance: 300, now:,
                                  unit: :ms)).to be(false)
    end

    it "accepts a plain epoch-seconds timestamp when unit: is omitted (regression)" do
      ts = (now - 60).to_i
      expect(described_class.within_tolerance?(timestamp: ts, tolerance: 300, now:)).to be(true)
    end

    it "ignores unit for a Time timestamp (already unambiguous)" do
      expect(described_class.within_tolerance?(timestamp: now - 60, tolerance: 300, now:, unit: :ms)).to be(true)
    end

    it "raises ArgumentError for an unsupported unit" do
      expect do
        described_class.within_tolerance?(timestamp: (now - 60).to_i, tolerance: 300, now:, unit: :fortnights)
      end.to raise_error(ArgumentError, /unsupported unit/)
    end

    it "raises ArgumentError for an unsupported unit via .hmac even when the signature is nil/empty" do
      expect do
        described_class.hmac(secret:, payload:, signature: nil, timestamp: (now - 60).to_i, tolerance: 300, now:,
                             unit: :fortnights)
      end.to raise_error(ArgumentError, /unsupported unit/)

      expect do
        described_class.hmac(secret:, payload:, signature: "", timestamp: (now - 60).to_i, tolerance: 300, now:,
                             unit: :fortnights)
      end.to raise_error(ArgumentError, /unsupported unit/)
    end

    it "raises ArgumentError for an unsupported unit via .hmac even when tolerance is absent" do
      expect do
        described_class.hmac(secret:, payload:, signature: hex, unit: :fortnights)
      end.to raise_error(ArgumentError, /unsupported unit/)
    end
  end

  describe "unit: :auto" do
    let(:secret)  { "Jefe" }
    let(:payload) { "what do ya want for nothing?" }
    let(:hex)     { "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843" }

    # The two Lob senders from PRO-3142, captured off the wire. Same vendor, same endpoint,
    # same second -- one sends 10-digit seconds, the other 13-digit milliseconds.
    let(:now)       { Time.at(1_786_679_195) }
    let(:lob_svix)  { "1786679195" }        # Svix, real deliveries
    let(:lob_debug) { "1786679195123" }     # dashboard debug send

    it "accepts both Lob senders under one configuration" do
      expect(described_class.within_tolerance?(timestamp: lob_svix, tolerance: 300, now:, unit: :auto)).to be(true)
      expect(described_class.within_tolerance?(timestamp: lob_debug, tolerance: 300, now:, unit: :auto)).to be(true)
    end

    it "is the default when unit: is omitted, so neither Lob sender needs configuring" do
      expect(described_class.hmac(secret:, payload:, signature: hex, timestamp: lob_svix, tolerance: 300, now:)).to be(true)
      expect(described_class.hmac(secret:, payload:, signature: hex, timestamp: lob_debug, tolerance: 300, now:)).to be(true)
    end

    it "infers each supported scale from magnitude" do
      seconds = (now - 60).to_i
      expect(described_class.within_tolerance?(timestamp: seconds, tolerance: 300, now:, unit: :auto)).to be(true)
      expect(described_class.within_tolerance?(timestamp: seconds * 1_000, tolerance: 300, now:, unit: :auto)).to be(true)
      expect(described_class.within_tolerance?(timestamp: seconds * 1_000_000, tolerance: 300, now:, unit: :auto)).to be(true)
    end

    it "accepts Integer and String forms identically" do
      ts = (now - 60).to_i * 1_000
      expect(described_class.within_tolerance?(timestamp: ts, tolerance: 300, now:, unit: :auto)).to be(true)
      expect(described_class.within_tolerance?(timestamp: ts.to_s, tolerance: 300, now:, unit: :auto)).to be(true)
    end

    it "still rejects a genuinely stale timestamp at every scale (inference is not a rescue)" do
      stale = (now - 10_000).to_i
      expect(described_class.within_tolerance?(timestamp: stale, tolerance: 300, now:, unit: :auto)).to be(false)
      expect(described_class.within_tolerance?(timestamp: stale * 1_000, tolerance: 300, now:, unit: :auto)).to be(false)
      expect(described_class.within_tolerance?(timestamp: stale * 1_000_000, tolerance: 300, now:, unit: :auto)).to be(false)
    end

    it "pins the band boundaries: 1e11 is the year 5138 in seconds, so it reads as ms" do
      # Below the floor -> seconds. At/above it -> ms. Both are ~56 years from `now` and rejected;
      # what this pins is the branch, via which side of the window each lands on.
      just_under = 99_999_999_999            # seconds -> year 5138
      just_over  = 100_000_000_000           # ms      -> 1973
      expect(described_class.within_tolerance?(timestamp: just_under, tolerance: 300, now:, unit: :auto)).to be(false)
      expect(described_class.within_tolerance?(timestamp: just_over, tolerance: 300, now:, unit: :auto)).to be(false)
      expect(described_class.mismatched_unit(timestamp: just_under, tolerance: 300, now:, unit: :auto)).to be_nil
    end

    it "leaves an explicit unit: as a hard lockdown -- no inference, no rescue" do
      expect(described_class.within_tolerance?(timestamp: lob_debug, tolerance: 300, now:, unit: :seconds)).to be(false)
      expect(described_class.within_tolerance?(timestamp: lob_svix, tolerance: 300, now:, unit: :ms)).to be(false)
    end

    it "ignores :auto for a Time timestamp (already unambiguous)" do
      expect(described_class.within_tolerance?(timestamp: now - 60, tolerance: 300, now:, unit: :auto)).to be(true)
    end

    it "handles zero, negative and unparseable values without raising" do
      expect(described_class.within_tolerance?(timestamp: 0, tolerance: 300, now:, unit: :auto)).to be(false)
      expect(described_class.within_tolerance?(timestamp: -1_786_679_195, tolerance: 300, now:, unit: :auto)).to be(false)
      expect(described_class.within_tolerance?(timestamp: "not-a-time", tolerance: 300, now:, unit: :auto)).to be(false)
    end

    it "still raises ArgumentError for an unsupported unit" do
      expect do
        described_class.within_tolerance?(timestamp: lob_svix, tolerance: 300, now:, unit: :fortnights)
      end.to raise_error(ArgumentError, /unsupported unit/)
    end
  end

  # Diagnostic surface for PRO-3141, which turns a bare 401 into a classified failure reason.
  # Pure and side-effect-free: it names the unit that WOULD have fit, and logs nothing itself.
  describe ".mismatched_unit" do
    let(:now)       { Time.at(1_786_679_195) }
    let(:lob_svix)  { "1786679195" }
    let(:lob_debug) { "1786679195123" }

    it "names the unit that would have fit when the configured one is wrong" do
      expect(described_class.mismatched_unit(timestamp: lob_debug, tolerance: 300, now:, unit: :seconds)).to eq(:ms)
      expect(described_class.mismatched_unit(timestamp: lob_svix, tolerance: 300, now:, unit: :ms)).to eq(:seconds)
    end

    it "returns nil when the configured unit already fits" do
      expect(described_class.mismatched_unit(timestamp: lob_svix, tolerance: 300, now:, unit: :seconds)).to be_nil
      expect(described_class.mismatched_unit(timestamp: lob_debug, tolerance: 300, now:, unit: :ms)).to be_nil
    end

    it "returns nil for a genuine replay -- no unit rescues a stale timestamp" do
      stale = (now - 10_000).to_i
      expect(described_class.mismatched_unit(timestamp: stale, tolerance: 300, now:, unit: :seconds)).to be_nil
    end

    it "returns nil for a missing or unparseable timestamp" do
      expect(described_class.mismatched_unit(timestamp: nil, tolerance: 300, now:, unit: :seconds)).to be_nil
      expect(described_class.mismatched_unit(timestamp: "not-a-time", tolerance: 300, now:, unit: :seconds)).to be_nil
    end

    it "treats the :milliseconds alias as :ms rather than reporting it as the mismatch" do
      expect(described_class.mismatched_unit(timestamp: lob_svix, tolerance: 300, now:, unit: :milliseconds)).to eq(:seconds)
    end

    it "raises ArgumentError for an unsupported unit, like the rest of the unit surface" do
      expect do
        described_class.mismatched_unit(timestamp: lob_svix, tolerance: 300, now:, unit: :fortnights)
      end.to raise_error(ArgumentError, /unsupported unit/)
    end
  end
end
