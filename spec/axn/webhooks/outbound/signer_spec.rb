# frozen_string_literal: true

require "base64"

RSpec.describe Axn::Webhooks::Outbound::Signer do
  # whsec_ + base64("secret") so decode_secret yields the raw "secret" bytes.
  let(:secret) { "whsec_#{Base64.strict_encode64('secret')}" }

  describe ":standard_webhooks strategy" do
    subject(:signer) { described_class.build(strategy: :standard_webhooks, opts: { secret: }, block: nil) }

    it "produces webhook-id / webhook-timestamp / v1 signature headers" do
      headers = signer.call(id: "msg_1", timestamp: 1_700_000_000, body: '{"a":1}')

      expect(headers["webhook-id"]).to eq("msg_1")
      expect(headers["webhook-timestamp"]).to eq("1700000000")
      expect(headers["webhook-signature"]).to start_with("v1,")
    end

    it "signs id.timestamp.body with the decoded secret so the inbound verifier accepts it" do
      id = "msg_1"
      ts = 1_700_000_000
      body = '{"a":1}'
      headers = signer.call(id:, timestamp: ts, body:)

      expected = Axn::Webhooks::Signature.compute(
        secret: "secret", payload: "#{id}.#{ts}.#{body}", digest: :sha256, encoding: :base64,
      )
      expect(headers["webhook-signature"]).to eq("v1,#{expected}")
    end

    it "resolves a callable secret per call rather than freezing it at build time" do
      calls = 0
      resolver = lambda do
        calls += 1
        secret
      end
      signer = described_class.build(strategy: :standard_webhooks, opts: { secret: resolver }, block: nil)

      2.times { signer.call(id: "msg_1", timestamp: 1_700_000_000, body: "{}") }

      expect(calls).to eq(2)
    end

    # The broad `rescue ArgumentError` around the whole method previously caught an ArgumentError
    # raised by the resolver ITSELF (e.g. a secret-store wrapper rejecting a bad response) and
    # rewrote it as the generic invalid-secret message, discarding the resolver's own diagnostic —
    # only Base64.strict_decode64's own ArgumentError (invalid base64) is meant to be caught here
    # (Codex P2 finding).
    it "preserves an exception raised by the secret resolver itself, rather than rewriting it as an invalid-secret error" do
      resolver = -> { raise ArgumentError, "secret store returned an invalid response" }
      signer = described_class.build(strategy: :standard_webhooks, opts: { secret: resolver }, block: nil)

      expect { signer.call(id: "msg_1", timestamp: 1_700_000_000, body: "{}") }
        .to raise_error(ArgumentError, "secret store returned an invalid response")
    end

    it "raises a named error when the resolved secret isn't a decodable whsec_ value" do
      signer = described_class.build(strategy: :standard_webhooks, opts: { secret: "not-whsec" }, block: nil)

      expect { signer.call(id: "msg_1", timestamp: 1_700_000_000, body: "{}") }
        .to raise_error(Axn::Webhooks::Error, /sign :standard_webhooks secret must be a whsec_<base64> value/)
    end

    it "raises rather than silently signing with an empty key when the secret is blank" do
      signer = described_class.build(strategy: :standard_webhooks, opts: { secret: "" }, block: nil)

      expect { signer.call(id: "msg_1", timestamp: 1_700_000_000, body: "{}") }
        .to raise_error(Axn::Webhooks::Error, /sign :standard_webhooks secret must be a whsec_<base64> value/)
    end

    it "raises rather than silently signing with an empty key when the secret is whsec_ with nothing after it" do
      signer = described_class.build(strategy: :standard_webhooks, opts: { secret: "whsec_" }, block: nil)

      expect { signer.call(id: "msg_1", timestamp: 1_700_000_000, body: "{}") }
        .to raise_error(Axn::Webhooks::Error, /sign :standard_webhooks secret must be a whsec_<base64> value/)
    end

    it "raises on a bare base64 secret missing the required whsec_ prefix" do
      signer = described_class.build(
        strategy: :standard_webhooks, opts: { secret: Base64.strict_encode64("secret") }, block: nil,
      )

      expect { signer.call(id: "msg_1", timestamp: 1_700_000_000, body: "{}") }
        .to raise_error(Axn::Webhooks::Error, /sign :standard_webhooks secret must be a whsec_<base64> value/)
    end

    # The secret can be re-resolved (and re-raise this same error) on every single delivery attempt,
    # so its message must never echo the actual secret bytes into logs/exception reporters — a
    # transiently-malformed value is exactly the case where the reporter is most likely to fire
    # (Codex P1 finding).
    it "never includes the actual secret bytes in the error message" do
      %w[a-live-looking-secret-value whsec_not-valid-base64!!!].each do |bad_secret|
        signer = described_class.build(strategy: :standard_webhooks, opts: { secret: bad_secret }, block: nil)

        expect { signer.call(id: "msg_1", timestamp: 1_700_000_000, body: "{}") }
          .to raise_error(Axn::Webhooks::Error) { |e| expect(e.message).not_to include(bad_secret) }
      end
    end

    it "never includes a non-String secret's value in the error message, only its class" do
      signer = described_class.build(strategy: :standard_webhooks, opts: { secret: 12_345 }, block: nil)

      expect { signer.call(id: "msg_1", timestamp: 1_700_000_000, body: "{}") }
        .to raise_error(Axn::Webhooks::Error, /Integer/)
    end

    # `resolve_secret` calls `@secret.call` with NO arguments, or with the `Subscriber` for a
    # PRO-3214 per-subscriber secret (one required arg) — a callable needing MORE than that would
    # otherwise boot successfully and raise ArgumentError on every real signing attempt, converted
    # into an Axn::Webhooks::Error `Deliver` can't classify as retryable and left for the async
    # adapter's unbounded exception retries instead of the bounded outbound retry engine (Codex P2
    # finding, widened for the subscriber-aware case). Reject at construction (boot) instead.
    it "rejects a secret callable that needs more than the subscriber" do
      expect do
        described_class.build(strategy: :standard_webhooks, opts: { secret: ->(a, b) { "#{a}#{b}" } }, block: nil)
      end.to raise_error(ArgumentError, /secret callable must accept zero or one arguments/)
    end

    it "rejects a secret callable requiring a keyword (same arity pitfall CallableArity exists for)" do
      expect do
        described_class.build(strategy: :standard_webhooks, opts: { secret: ->(subscriber:) { subscriber } }, block: nil)
      end.to raise_error(ArgumentError, /secret callable must accept zero or one arguments/)
    end

    it "accepts a secret callable with an optional argument (zero-arg invocation still works)" do
      expect do
        described_class.build(strategy: :standard_webhooks, opts: { secret: ->(_app = nil) { secret } }, block: nil)
      end.not_to raise_error
    end

    describe "per-subscriber secret (PRO-3214)" do
      it "resolves a 1-arity secret callable with the Subscriber given to #call" do
        seen = nil
        resolver = lambda do |sub|
          seen = sub
          secret
        end
        signer = described_class.build(strategy: :standard_webhooks, opts: { secret: resolver }, block: nil)
        subscriber = Axn::Webhooks::Outbound::Subscriber.new(url: "https://a.example/hook", id: "17")

        signer.call(id: "msg_1", timestamp: 1_700_000_000, body: "{}", subscriber:)

        expect(seen).to equal(subscriber)
      end

      it "still resolves a 0-arity secret with no subscriber in scope (today's shape, unchanged)" do
        signer = described_class.build(strategy: :standard_webhooks, opts: { secret: -> { secret } }, block: nil)

        expect { signer.call(id: "msg_1", timestamp: 1_700_000_000, body: "{}") }.not_to raise_error
      end

      # Codex P1 finding: a PRE-EXISTING secret resolver with an optional positional arg for some
      # UNRELATED reason -- e.g. `->(app = Rails.application) { app.credentials.webhook_secret }` --
      # is `CallableArity.accepts?(secret, 1)` == true (it CAN take one arg), so naively preferring
      # the 1-arg call would start passing it a Subscriber where it previously always defaulted,
      # breaking every delivery after upgrading. The fix must prefer a ZERO-arg call whenever the
      # callable can accept one, and pass the subscriber ONLY when it genuinely cannot be invoked
      # with zero args (a REQUIRED single positional) -- which is exactly the shape that was
      # REJECTED at boot before subscriber-awareness existed, so there is no prior behavior to break.
      it "prefers a zero-arg call for an optional-arg secret, using ITS OWN default rather than the subscriber" do
        seen = []
        resolver = lambda { |app = :the_default|
          seen << app
          secret
        }
        signer = described_class.build(strategy: :standard_webhooks, opts: { secret: resolver }, block: nil)
        subscriber = Axn::Webhooks::Outbound::Subscriber.new(url: "https://a.example/hook", id: "17")

        signer.call(id: "msg_1", timestamp: 1_700_000_000, body: "{}", subscriber:)

        expect(seen).to eq([:the_default])
      end

      # Codex P1 finding, round 2: a plain `proc { |subscriber| ... }` (no default -- NOT a
      # lambda) reports its single param as `:opt` via #parameters, the SAME label a genuine
      # default gets -- so a #parameters-based "prefer zero-arg" check can't tell them apart, and
      # would silently call this with ZERO args, passing `nil` in place of the subscriber (Ruby
      # procs fill a missing arg with nil rather than raising). Raw arity does NOT have this
      # ambiguity: a no-default proc's arity is still the correct positive 1.
      it "still passes the subscriber to a plain Proc (not a lambda) with one param and no default" do
        seen = nil
        resolver = proc { |sub|
          seen = sub
          secret
        }
        signer = described_class.build(strategy: :standard_webhooks, opts: { secret: resolver }, block: nil)
        subscriber = Axn::Webhooks::Outbound::Subscriber.new(url: "https://a.example/hook", id: "17")

        signer.call(id: "msg_1", timestamp: 1_700_000_000, body: "{}", subscriber:)

        expect(seen).to equal(subscriber)
      end
    end
  end

  describe "custom block" do
    it "uses the block verbatim and returns its header hash" do
      signer = described_class.build(
        strategy: nil, opts: {},
        block: ->(id:, timestamp:, body:) { { "x-sig" => "#{id}:#{timestamp}:#{body.bytesize}" } }
      )
      expect(signer.call(id: "m", timestamp: 5, body: "abc")).to eq("x-sig" => "m:5:3")
    end

    describe "subscriber-awareness (PRO-3214)" do
      it "keeps working byte-for-byte for a block declaring only the original (id:, timestamp:, body:)" do
        # The kwarg set widens (subscriber: is now always passed) but a block that never asked for
        # it must not see an unexpected-keyword ArgumentError -- CustomSigner filters down to what
        # the block actually declares.
        signer = described_class.build(
          strategy: nil, opts: {},
          block: ->(id:, timestamp:, body:) { { "x-sig" => "#{id}:#{timestamp}:#{body}" } }
        )
        subscriber = Axn::Webhooks::Outbound::Subscriber.new(url: "https://a.example/hook", id: "17")

        expect(signer.call(id: "m", timestamp: 5, body: "abc", subscriber:)).to eq("x-sig" => "m:5:abc")
      end

      it "passes the Subscriber through to a block that declares subscriber:" do
        seen = nil
        signer = described_class.build(
          strategy: nil, opts: {},
          block: lambda { |id:, timestamp:, body:, subscriber:|
            seen = subscriber
            { "x-sig" => "#{id}:#{timestamp}:#{body}" }
          }
        )
        subscriber = Axn::Webhooks::Outbound::Subscriber.new(url: "https://a.example/hook", id: "17")

        signer.call(id: "m", timestamp: 5, body: "abc", subscriber:)

        expect(seen).to equal(subscriber)
      end

      it "passes everything through unfiltered to a block that double-splats" do
        received = nil
        signer = described_class.build(strategy: nil, opts: {}, block: lambda { |**kw|
          received = kw
          {}
        })
        subscriber = Axn::Webhooks::Outbound::Subscriber.new(url: "https://a.example/hook", id: "17")

        signer.call(id: "m", timestamp: 5, body: "abc", subscriber:)

        expect(received).to eq(id: "m", timestamp: 5, body: "abc", subscriber:)
      end

      # Codex P1 finding, round 3: `sign { { "X-API-Key" => key } }` -- a ZERO-param block that
      # ignores id:/timestamp:/body: entirely -- is a legitimate, PRE-EXISTING pattern: a Ruby
      # block (always a non-lambda Proc, never a lambda) silently tolerates being called with
      # kwargs it never declared. The original boot check demanded the block declare ALL of
      # id:/timestamp:/body:, rejecting this working configuration at declaration time even though
      # it was never actually broken.
      it "accepts a zero-param block that ignores id:/timestamp:/body: entirely (a legitimate static-header signer)" do
        expect do
          described_class.build(strategy: nil, opts: {}, block: -> { { "x-api-key" => "static-key" } })
        end.not_to raise_error
      end

      it "the accepted zero-param block still works at call time, receiving nothing" do
        signer = described_class.build(strategy: nil, opts: {}, block: -> { { "x-api-key" => "static-key" } })
        expect(signer.call(id: "m", timestamp: 5, body: "abc")).to eq("x-api-key" => "static-key")
      end

      # A block that only wants the subscriber (ignoring id:/timestamp:/body:) is the identical
      # legitimate shape -- there's nothing broken about a custom signer that keys its header
      # purely off subscriber identity.
      it "accepts (and correctly calls) a block that declares only subscriber:, ignoring id:/timestamp:/body:" do
        seen = nil
        signer = described_class.build(strategy: nil, opts: {}, block: lambda { |subscriber:|
          seen = subscriber
          { "x-subscriber" => subscriber&.id.to_s }
        })
        subscriber = Axn::Webhooks::Outbound::Subscriber.new(url: "https://a.example/hook", id: "17")

        result = signer.call(id: "m", timestamp: 5, body: "abc", subscriber:)

        expect(seen).to equal(subscriber)
        expect(result).to eq("x-subscriber" => "17")
      end

      # What SHOULD still be caught at boot: a block requiring a keyword this gem can never
      # supply (outside id:/timestamp:/body:/subscriber:) -- that genuinely fails on every call.
      it "still rejects at boot a block requiring a keyword this gem never supplies" do
        expect do
          described_class.build(strategy: nil, opts: {}, block: ->(id:, vendor:) { "#{id}#{vendor}" })
        end.to raise_error(ArgumentError, /requires.*vendor:.*never supplies/)
      end
    end
  end

  it "raises (ArgumentError: a boot-time declaration mistake, not a runtime condition) on an unknown strategy" do
    expect { described_class.build(strategy: :nope, opts: {}, block: nil) }
      .to raise_error(ArgumentError, /unknown sign strategy/)
  end
end
