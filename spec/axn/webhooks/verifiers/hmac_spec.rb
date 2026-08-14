# frozen_string_literal: true

require "openssl"

RSpec.describe "verify :hmac strategy" do
  after { Axn::Webhooks::Inbound.reset! }

  let(:secret) { "shh" }
  let(:body)   { '{"ok":true}' }

  def request(headers:, body: '{"ok":true}')
    Axn::Webhooks::Request.new(raw_body: body, headers:)
  end

  it "verifies a hex sha256 signature over the raw body (Merge/MT-style)" do
    sig = OpenSSL::HMAC.hexdigest("SHA256", secret, body)
    Axn::Webhooks.inbound(:merge) { verify :hmac, secret: "shh", signature: header("X-Sig") }

    expect(Axn::Webhooks::Inbound[:merge].verify(request(headers: { "X-Sig" => sig }))).to be_ok
    expect(Axn::Webhooks::Inbound[:merge].verify(request(headers: { "X-Sig" => "deadbeef" }))).not_to be_ok
  end

  it "supports base64_urlsafe encoding" do
    raw = OpenSSL::HMAC.digest("SHA256", secret, body)
    sig = [raw].pack("m0").tr("+/", "-_") # urlsafe base64, no padding stripped by pack
    Axn::Webhooks.inbound(:merge) do
      verify :hmac, secret: "shh", signature: header("X-Sig"), encoding: :base64_urlsafe
    end
    expect(Axn::Webhooks::Inbound[:merge].verify(request(headers: { "X-Sig" => sig }))).to be_ok
  end

  it "supports a custom signing_string and a v0= prefix (Slack-style)" do
    ts = "1700000000"
    signed = "v0:#{ts}:#{body}"
    sig = "v0=#{OpenSSL::HMAC.hexdigest('SHA256', secret, signed)}"
    Axn::Webhooks.inbound(:slack) do
      verify(
        :hmac,
        secret: "shh",
        signing_string: ->(r) { "v0:#{r.header('X-Ts')}:#{r.raw_body}" },
        signature: header("X-Slack-Sig"),
        prefix: "v0=",
      )
    end
    req = request(headers: { "X-Ts" => ts, "X-Slack-Sig" => sig })
    expect(Axn::Webhooks::Inbound[:slack].verify(req)).to be_ok
  end

  it "rejects a stale timestamp when replay protection is configured" do
    stale = (Time.now - 10_000).to_i.to_s
    sig = OpenSSL::HMAC.hexdigest("SHA256", secret, body)
    Axn::Webhooks.inbound(:lob) do
      verify :hmac, secret: "shh", signature: header("X-Sig"),
                    replay: { timestamp: header("X-Ts"), within: 300 }
    end
    req = request(headers: { "X-Sig" => sig, "X-Ts" => stale })
    expect(Axn::Webhooks::Inbound[:lob].verify(req)).not_to be_ok
  end

  it "accepts a fresh timestamp when replay protection is configured" do
    fresh = Time.now.to_i.to_s
    sig = OpenSSL::HMAC.hexdigest("SHA256", secret, body)
    Axn::Webhooks.inbound(:webhook) do
      verify :hmac, secret: "shh", signature: header("X-Sig"),
                    replay: { timestamp: header("X-Ts"), within: 300 }
    end
    req = request(headers: { "X-Sig" => sig, "X-Ts" => fresh })
    expect(Axn::Webhooks::Inbound[:webhook].verify(req)).to be_ok
  end

  it "accepts a fresh epoch-ms timestamp when replay protection specifies unit: :ms (Lob-style)" do
    fresh_ms = (Time.now.to_i * 1_000).to_s
    sig = OpenSSL::HMAC.hexdigest("SHA256", secret, body)
    Axn::Webhooks.inbound(:lob_ms) do
      verify :hmac, secret: "shh", signature: header("X-Sig"),
                    replay: { timestamp: header("X-Ts"), within: 300, unit: :ms }
    end
    req = request(headers: { "X-Sig" => sig, "X-Ts" => fresh_ms })
    expect(Axn::Webhooks::Inbound[:lob_ms].verify(req)).to be_ok
  end

  it "rejects an epoch-ms timestamp just outside tolerance, proving the ms->s conversion is applied " \
     "before the comparison (not merely stale under any interpretation)" do
    # 301s ago is only rejected under a `within: 300` tolerance if the ms->s conversion actually ran;
    # a far-stale timestamp (e.g. 10_000s) would fail regardless of whether `unit:` was wired correctly.
    just_stale_ms = ((Time.now - 301).to_i * 1_000).to_s
    sig = OpenSSL::HMAC.hexdigest("SHA256", secret, body)
    Axn::Webhooks.inbound(:lob_ms_stale) do
      verify :hmac, secret: "shh", signature: header("X-Sig"),
                    replay: { timestamp: header("X-Ts"), within: 300, unit: :ms }
    end
    req = request(headers: { "X-Sig" => sig, "X-Ts" => just_stale_ms })
    expect(Axn::Webhooks::Inbound[:lob_ms_stale].verify(req)).not_to be_ok
  end

  it "accepts both of Lob's senders under one replay: config, with no unit: at all (PRO-3142)" do
    # Lob delivers through two senders that disagree on the unit: Svix sends 10-digit seconds,
    # the dashboard's debug send sends 13-digit ms. No static unit: is correct for that vendor.
    fresh_s  = Time.now.to_i.to_s
    fresh_ms = (Time.now.to_i * 1_000).to_s
    sig = OpenSSL::HMAC.hexdigest("SHA256", secret, body)
    Axn::Webhooks.inbound(:lob_two_senders) do
      verify :hmac, secret: "shh", signature: header("X-Sig"),
                    replay: { timestamp: header("X-Ts"), within: 300 }
    end

    %w[seconds ms].zip([fresh_s, fresh_ms]).each do |_label, ts|
      req = request(headers: { "X-Sig" => sig, "X-Ts" => ts })
      expect(Axn::Webhooks::Inbound[:lob_two_senders].verify(req)).to be_ok
    end
  end

  it "honours an explicit unit: as a lockdown, rejecting the other sender's scale" do
    fresh_ms = (Time.now.to_i * 1_000).to_s
    sig = OpenSSL::HMAC.hexdigest("SHA256", secret, body)
    Axn::Webhooks.inbound(:pinned_seconds) do
      verify :hmac, secret: "shh", signature: header("X-Sig"),
                    replay: { timestamp: header("X-Ts"), within: 300, unit: :seconds }
    end
    req = request(headers: { "X-Sig" => sig, "X-Ts" => fresh_ms })
    expect(Axn::Webhooks::Inbound[:pinned_seconds].verify(req)).not_to be_ok
  end

  # PRO-3141 — the end-to-end version of the Lob outage: two 401s that used to be identical.
  describe "rejection reasons" do
    it "reports :replay_window (with the skew), not :signature_mismatch, for a validly-signed stale request" do
      stale = (Time.now - 10_000).to_i.to_s
      sig = OpenSSL::HMAC.hexdigest("SHA256", secret, body)
      Axn::Webhooks.inbound(:lob) do
        verify :hmac, secret: "shh", signature: header("X-Sig"),
                      replay: { timestamp: header("X-Ts"), within: 300 }
      end

      result = Axn::Webhooks::Inbound[:lob].verify(request(headers: { "X-Sig" => sig, "X-Ts" => stale }))

      expect(result.reason).to eq(:replay_window)
      expect(result.skew).to be_within(5).of(10_000)
      expect(result.error).to include("replay window")
    end

    it "reports :signature_mismatch for a freshly-timestamped request with a bad signature" do
      fresh = Time.now.to_i.to_s
      Axn::Webhooks.inbound(:lob) do
        verify :hmac, secret: "shh", signature: header("X-Sig"),
                      replay: { timestamp: header("X-Ts"), within: 300 }
      end

      result = Axn::Webhooks::Inbound[:lob].verify(request(headers: { "X-Sig" => "deadbeef", "X-Ts" => fresh }))

      expect(result.reason).to eq(:signature_mismatch)
    end

    it "reports :replay_timestamp_invalid when the configured timestamp header is absent (typo'd header name)" do
      sig = OpenSSL::HMAC.hexdigest("SHA256", secret, body)
      Axn::Webhooks.inbound(:lob) do
        verify :hmac, secret: "shh", signature: header("X-Sig"),
                      replay: { timestamp: header("X-Typo"), within: 300 }
      end

      result = Axn::Webhooks::Inbound[:lob].verify(request(headers: { "X-Sig" => sig, "X-Ts" => Time.now.to_i.to_s }))

      expect(result.reason).to eq(:replay_timestamp_invalid)
    end

    it "reports :signature_missing when the vendor sent no signature header" do
      Axn::Webhooks.inbound(:merge) { verify :hmac, secret: "shh", signature: header("X-Sig") }

      expect(Axn::Webhooks::Inbound[:merge].verify(request(headers: {})).reason).to eq(:signature_missing)
    end

    it "names a PINNED unit: as the cause, distinguishing it from a genuine replay" do
      # The Lob outage, as it can still happen post-PRO-3142: epoch-ms read as epoch-s, which only
      # occurs now if someone explicitly pinned unit: :seconds. Same :replay_window reason as
      # ordinary staleness, but suggested_unit names the fix outright.
      fresh_ms = (Time.now.to_i * 1_000).to_s
      sig = OpenSSL::HMAC.hexdigest("SHA256", secret, body)
      Axn::Webhooks.inbound(:pinned_wrong) do
        verify :hmac, secret: "shh", signature: header("X-Sig"),
                      replay: { timestamp: header("X-Ts"), within: 300, unit: :seconds }
      end

      result = Axn::Webhooks::Inbound[:pinned_wrong].verify(request(headers: { "X-Sig" => sig, "X-Ts" => fresh_ms }))

      expect(result.reason).to eq(:replay_window)
      expect(result.suggested_unit).to eq(:ms)
      expect(result.skew).to be < -1_000_000_000_000
      expect(result.error).to include("would fit as unit: :ms")
    end

    it "leaves suggested_unit nil for a genuine replay, so the two are separable" do
      stale = (Time.now - 10_000).to_i.to_s
      sig = OpenSSL::HMAC.hexdigest("SHA256", secret, body)
      Axn::Webhooks.inbound(:lob) do
        verify :hmac, secret: "shh", signature: header("X-Sig"),
                      replay: { timestamp: header("X-Ts"), within: 300 }
      end

      result = Axn::Webhooks::Inbound[:lob].verify(request(headers: { "X-Sig" => sig, "X-Ts" => stale }))

      expect(result.reason).to eq(:replay_window)
      expect(result.suggested_unit).to be_nil
      expect(result.error).not_to include("would fit")
    end
  end

  it "raises a loud developer error when a required option is missing" do
    expect { Axn::Webhooks.inbound(:x) { verify :hmac, secret: "s" } } # no signature:
      .to raise_error(ArgumentError, /signature/)
  end

  it "raises a loud developer error for an unrecognized key in replay: (e.g. a typo'd unit:)" do
    expect do
      Axn::Webhooks.inbound(:y) do
        verify :hmac, secret: "s", signature: header("X-Sig"),
                      replay: { timestamp: header("X-Ts"), within: 300, unti: :ms }
      end
    end.to raise_error(ArgumentError, /unti/)
  end

  it "accepts a replay: hash with indifferent (string) access, not just symbol keys" do
    fresh = Time.now.to_i.to_s
    sig = OpenSSL::HMAC.hexdigest("SHA256", secret, body)
    Axn::Webhooks.inbound(:indifferent) do
      replay = ActiveSupport::HashWithIndifferentAccess.new(timestamp: header("X-Ts"), within: 300, unit: :seconds)
      verify :hmac, secret: "shh", signature: header("X-Sig"), replay:
    end
    req = request(headers: { "X-Sig" => sig, "X-Ts" => fresh })
    expect(Axn::Webhooks::Inbound[:indifferent].verify(req)).to be_ok
  end

  it "surfaces a loud exception when replay: explicitly sets an invalid unit: (e.g. nil from an unset env var)" do
    fresh = Time.now.to_i.to_s
    sig = OpenSSL::HMAC.hexdigest("SHA256", secret, body)
    Axn::Webhooks.inbound(:explicit_nil_unit) do
      verify :hmac, secret: "shh", signature: header("X-Sig"),
                    replay: { timestamp: header("X-Ts"), within: 300, unit: nil }
    end
    req = request(headers: { "X-Sig" => sig, "X-Ts" => fresh })

    result = Axn::Webhooks::Inbound[:explicit_nil_unit].verify(req)

    expect(result).not_to be_ok
    expect(result.outcome).to be_exception
    expect(result.exception).to be_a(ArgumentError)
    expect(result.exception.message).to match(/unsupported unit/)
  end
end
