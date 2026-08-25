# frozen_string_literal: true

# Two LOW findings from the lib/ security audit, both "fails open where everything else fails
# closed" shapes.
RSpec.describe "security audit — LOW findings" do
  describe "replay tolerance must not silently disable itself" do
    let(:secret) { "k" }
    let(:payload) { "body" }
    let(:signature) { OpenSSL::HMAC.hexdigest("sha256", "k", "body") }
    let(:ancient) { (Time.now - (5 * 365 * 24 * 3600)).to_i }

    # Omitting tolerance: means "no replay check" and is the documented default — that must keep
    # working. Explicitly PASSING nil/false is different: it's a value that arrived from somewhere
    # (`ENV["TOLERANCE"]&.to_i`) and silently turned the guard off.
    it "still allows omitting tolerance entirely (documented default)" do
      expect(Axn::Webhooks::Signature.hmac(secret:, payload:, signature:)).to be(true)
    end

    it "rejects an explicitly nil tolerance rather than disabling replay protection" do
      expect { Axn::Webhooks::Signature.hmac(secret:, payload:, signature:, timestamp: ancient, tolerance: nil) }
        .to raise_error(ArgumentError, /tolerance/)
    end

    it "rejects an explicitly false tolerance" do
      expect { Axn::Webhooks::Signature.hmac(secret:, payload:, signature:, timestamp: ancient, tolerance: false) }
        .to raise_error(ArgumentError, /tolerance/)
    end

    it "still enforces a real tolerance (positive control both ways)" do
      expect(Axn::Webhooks::Signature.hmac(secret:, payload:, signature:, timestamp: ancient, tolerance: 300)).to be(false)
      expect(Axn::Webhooks::Signature.hmac(secret:, payload:, signature:, timestamp: Time.now.to_i, tolerance: 300)).to be(true)
    end

    # Declaring `replay:` at all is an explicit request FOR replay protection, so a blank `within:`
    # is unambiguously a mistake — caught at boot, like every other declaration error.
    it "rejects `replay: { within: nil }` at declaration" do
      expect do
        Axn::Webhooks::Inbound.reset!
        Axn::Webhooks.inbound(:v) do
          verify :hmac, secret: "k", signature: header("X-Sig"), replay: { timestamp: header("X-Ts"), within: nil }
        end
      end.to raise_error(ArgumentError, /within/)
    end

    it "rejects a non-positive `within:` at declaration" do
      expect do
        Axn::Webhooks::Inbound.reset!
        Axn::Webhooks.inbound(:v) do
          verify :hmac, secret: "k", signature: header("X-Sig"), replay: { timestamp: header("X-Ts"), within: 0 }
        end
      end.to raise_error(ArgumentError, /within/)
    end

    it "accepts a valid replay declaration, and still verifies with it (positive control)" do
      Axn::Webhooks::Inbound.reset!
      Axn::Webhooks.inbound(:v) do
        verify :hmac, secret: "k", signature: header("X-Sig"), replay: { timestamp: header("X-Ts"), within: 300 }
      end
      ts = Time.now.to_i.to_s
      request = Axn::Webhooks::Request.new(
        raw_body: "body",
        headers: { "X-Sig" => OpenSSL::HMAC.hexdigest("sha256", "k", "body"), "X-Ts" => ts },
      )
      expect(Axn::Webhooks::Inbound[:v].verify(request)).to be_ok
    end

    it "rejects an explicitly nil tolerance on verify :standard_webhooks at declaration" do
      expect do
        Axn::Webhooks::Inbound.reset!
        Axn::Webhooks.inbound(:v) { verify :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('k')}", tolerance: nil }
      end.to raise_error(ArgumentError, /tolerance/)
    end
  end

  describe "Response rejects CR/LF (and other control bytes) in header values" do
    it "drops a header whose value carries a CRLF response-splitting payload" do
      response = Axn::Webhooks::Response.new(headers: { "x-echo" => "a\r\nSet-Cookie: evil=1" })
      expect(response.headers).not_to have_key("x-echo")
      expect(response.to_rack[1]).not_to have_key("x-echo")
    end

    it "drops a value containing any other forbidden control byte" do
      expect(Axn::Webhooks::Response.new(headers: { "x-echo" => "a\x00b" }).headers).not_to have_key("x-echo")
    end

    it "drops the bad element from an Array multi-value header but keeps the good ones" do
      response = Axn::Webhooks::Response.new(headers: { "set-cookie" => ["a=1", "b=2\r\nevil: 1"] })
      expect(response.headers["set-cookie"]).to eq(["a=1"])
    end

    it "keeps ordinary values, including HTAB which RFC 7230 permits (positive control)" do
      response = Axn::Webhooks::Response.new(headers: { "content-type" => "text/plain", "x-tab" => "a\tb" })
      expect(response.headers["content-type"]).to eq("text/plain")
      expect(response.headers["x-tab"]).to eq("a\tb")
    end

    it "does not blow up on a value with an invalid encoding" do
      expect { Axn::Webhooks::Response.new(headers: { "x-bin" => (+"\xC3\x28").force_encoding("UTF-8") }) }
        .not_to raise_error
    end
  end
end
