# frozen_string_literal: true

require "base64"

# Config#resolve_subscribers is the PRO-3214 seam: `targets_for` (the pre-existing API, still used
# by today's `Emit`) is a thin back-compat wrapper around this that drops rejections -- see its own
# doc comment in config.rb. This file covers what `targets_for` can't express: Hash-shaped rows
# (identity, not just a URL), per-row rejection instead of all-or-nothing, and the host policy.
RSpec.describe "Axn::Webhooks::Outbound::Config#resolve_subscribers" do
  after { Axn::Webhooks::Outbound.reset! }

  let(:secret) { "whsec_#{Base64.strict_encode64('s')}" }

  def outbound!(&block)
    s = secret
    Axn::Webhooks.outbound do
      sign :standard_webhooks, secret: s
      instance_eval(&block)
    end
    Axn::Webhooks::Outbound.config
  end

  describe "Hash-shaped rows" do
    it "accepts a Hash row from a static to: Array, carrying its id through" do
      config = outbound! { event :lead_signed, to: [{ url: "https://a.example/hook", id: 17 }] }
      resolution = config.resolve_subscribers(:lead_signed)

      expect(resolution.subscribers).to eq([Axn::Webhooks::Outbound::Subscriber.new(url: "https://a.example/hook", id: "17")])
      expect(resolution.rejections).to eq([])
    end

    it "accepts a Hash row from a runtime subscribers resolver" do
      config = outbound! do
        subscribers ->(_event) { [{ url: "https://a.example/hook", id: "17" }] }
        event :lead_closed
      end
      resolution = config.resolve_subscribers(:lead_closed)

      expect(resolution.subscribers.first.id).to eq("17")
    end

    it "still accepts a bare String URL alongside Hash rows (today's shape, unchanged)" do
      config = outbound! { event :lead_signed, to: ["https://a.example/hook", { url: "https://b.example/hook", id: 2 }] }
      resolution = config.resolve_subscribers(:lead_signed)

      expect(resolution.subscribers).to eq([
                                             Axn::Webhooks::Outbound::Subscriber.new(url: "https://a.example/hook", id: nil),
                                             Axn::Webhooks::Outbound::Subscriber.new(url: "https://b.example/hook", id: "2"),
                                           ])
    end

    it "copies a static Hash row instead of freezing the caller's own object (mirrors the String-row fix)" do
      # Same hazard `config_immutability_spec` already pins for a plain String `to:` entry: a Hash
      # row is caller-supplied too (`event to: SOME_CONSTANT_ARRAY`), so mutating it after boot must
      # not rewrite the already-validated config underneath it.
      app_row = { url: +"https://a.example/hook", id: "17" }
      config = outbound! { event :lead_signed, to: [app_row] }

      expect(app_row).not_to be_frozen
      expect(app_row[:url]).not_to be_frozen

      app_row[:url].replace("ftp://bad.example/hook")
      app_row[:id] = "rewritten"

      resolution = config.resolve_subscribers(:lead_signed)
      expect(resolution.subscribers.first.url).to eq("https://a.example/hook")
      expect(resolution.subscribers.first.id).to eq("17")
    end

    # Codex P2 finding, round 7: a prebuilt `Subscriber` (constructed directly, e.g.
    # `Subscriber.new(url: app_string, id: "1")`, rather than via the Hash-row path) slipped past
    # the String/Hash-row copy-on-freeze fix above -- `config_owned` returned it UNCHANGED (it
    # matched neither `String` nor `Hash`), so the SAME mutable String the app passed in stayed
    # reachable as `.url`. Worse than the String/Hash cases: `static_resolution` deliberately
    # SKIPS TargetPolicy for an already-boot-validated static entry, so a post-boot mutation here
    # would switch a boot-approved destination to an arbitrary host with NO re-validation at all.
    it "copies a static PREBUILT Subscriber's url/id too, not just a Hash/String row" do
      mutable_url = +"https://a.example/hook"
      app_subscriber = Axn::Webhooks::Outbound::Subscriber.new(url: mutable_url, id: "17")
      config = outbound! { event :lead_signed, to: [app_subscriber] }

      expect(mutable_url).not_to be_frozen

      mutable_url.replace("https://evil.example/hook")

      resolution = config.resolve_subscribers(:lead_signed)
      expect(resolution.subscribers.first.url).to eq("https://a.example/hook")
    end
  end

  describe "per-row rejection" do
    it "rejects a malformed row without discarding the good ones in the same resolution" do
      config = outbound! do
        subscribers ->(_event) { ["https://good.example/hook", { url: nil }, "not-a-url"] }
        event :lead_closed
      end
      resolution = config.resolve_subscribers(:lead_closed)

      expect(resolution.subscribers.map(&:url)).to eq(["https://good.example/hook"])
      expect(resolution.rejections.size).to eq(2)
      expect(resolution.rejections[0]).to include(reason: a_string_matching(/must be a String/))
      expect(resolution.rejections[1]).to include(reason: a_string_matching(/is not a valid URL|must be http/))
    end

    it "rejects a row carrying an unknown key (e.g. a caller trying to smuggle a secret through) rather than silently dropping it" do
      config = outbound! do
        subscribers ->(_event) { [{ url: "https://a.example/hook", secret: "shh" }] }
        event :lead_closed
      end
      resolution = config.resolve_subscribers(:lead_closed)

      expect(resolution.subscribers).to eq([])
      expect(resolution.rejections.first[:reason]).to match(/unknown key.*secret/)
    end

    # Codex P1 finding: a rejected row's raw value used to be `.inspect`ed verbatim into
    # `rejections` -- which `Emit` both exposes via `result.rejected` AND reports through
    # `Axn.config.on_exception`. A row a caller mistakenly tried to smuggle a live credential
    # through (exactly the shape the test above proves gets REJECTED) would otherwise have that
    # credential copied straight into logs/exception reporters by the rejection path itself.
    it "never leaks a rejected row's raw values (only :url/:id) into the rejection's :target" do
      config = outbound! do
        subscribers ->(_event) { [{ url: "https://a.example/hook", secret: "live-key-do-not-leak" }] }
        event :lead_closed
      end
      resolution = config.resolve_subscribers(:lead_closed)

      expect(resolution.rejections.first[:target]).not_to include("live-key-do-not-leak")
    end

    # Codex P1 finding, round 7: the Hash-row redaction above shows `:url` AS-IS (it's the one
    # field always safe to inspect for a WELL-FORMED row) -- but the URL VALUE itself commonly
    # embeds a credential (HTTP Basic userinfo, a signed/token query param), so a row rejected for
    # some OTHER reason (e.g. an unrelated unknown key) had that embedded credential shown
    # unredacted anyway.
    it "redacts a Hash row's OWN :url value too, not just its other keys" do
      config = outbound! do
        subscribers ->(_event) { [{ url: "https://user:live-key-do-not-leak@evil.example/hook?token=also-do-not-leak", unknown: "x" }] }
        event :lead_closed
      end
      resolution = config.resolve_subscribers(:lead_closed)

      target = resolution.rejections.first[:target]
      expect(target).not_to include("live-key-do-not-leak")
      expect(target).not_to include("also-do-not-leak")
      expect(target).to include("evil.example/hook")
    end

    # Codex P1 finding, round 5: the Hash-row redaction above doesn't help when a resolver
    # accidentally returns a non-Hash object entirely -- e.g. an ActiveRecord model instance,
    # whose #inspect commonly renders EVERY attribute, including a secret/token column. Fresh
    # after the Hash-row leak fix, the non-Hash fallback still rendered arbitrary target#inspect
    # output verbatim.
    it "never leaks an arbitrary non-Hash rejected target's #inspect (e.g. a model instance with a secret attribute)" do
      fake_model = Struct.new(:url, :api_token) do
        def inspect = "#<FakeSubscription url=#{url.inspect}, api_token=#{api_token.inspect}>"
      end.new("https://a.example/hook", "live-key-do-not-leak")

      config = outbound! do
        subscribers ->(_event) { [fake_model] }
        event :lead_closed
      end
      resolution = config.resolve_subscribers(:lead_closed)

      expect(resolution.rejections.first[:target]).not_to include("live-key-do-not-leak")
      expect(resolution.rejections.first[:target]).not_to include("FakeSubscription")
    end

    # Codex P1 finding, round 6: a bare String target was assumed "safe to inspect verbatim" --
    # true for most malformed cases (a typo, an empty string) but NOT for a webhook URL, which
    # commonly embeds credentials via HTTP Basic userinfo or a signed/token query param. A
    # rejected URL (e.g. its host isn't on the allowlist) had that embedded credential copied
    # straight into `result.rejected` and the `on_exception` report.
    it "redacts userinfo/query/fragment from a rejected URL String, keeping only scheme/host/path" do
      config = outbound! do
        allowed_hosts %w[good.example]
        subscribers ->(_event) { ["https://user:live-key-do-not-leak@evil.example/hook?token=also-do-not-leak#frag"] }
        event :lead_closed
      end
      resolution = config.resolve_subscribers(:lead_closed)

      target = resolution.rejections.first[:target]
      expect(target).not_to include("live-key-do-not-leak")
      expect(target).not_to include("also-do-not-leak")
      expect(target).to include("evil.example/hook")
    end

    it "falls back to a safe class/length description for an unparseable rejected URL String" do
      config = outbound! do
        subscribers ->(_event) { ["http://[::not-a-host"] }
        event :lead_closed
      end

      resolution = nil
      expect { resolution = config.resolve_subscribers(:lead_closed) }.not_to raise_error
      expect(resolution.rejections.first[:target]).to match(/unparseable/)
    end

    # Codex P1 finding: `Kernel#Array` on a bare Hash converts it to `[[k, v], ...]` pairs (Hash
    # responds to #to_a), NOT `[hash]` -- a `subscribers`/`to:` resolver that returns ONE row
    # directly, rather than wrapping it in an Array (an easy mistake: "return the row" is the
    # natural mental model when there's exactly one match), silently delivered to NOBODY: both
    # pseudo-rows failed validation and the real subscriber never got a webhook.
    it "treats a resolver's single bare Hash return value as one row, not a Hash-of-pairs to mangle" do
      config = outbound! do
        subscribers ->(_event) { { url: "https://a.example/hook", id: "17" } }
        event :lead_closed
      end
      resolution = config.resolve_subscribers(:lead_closed)

      expect(resolution.subscribers.map(&:url)).to eq(["https://a.example/hook"])
      expect(resolution.rejections).to eq([])
    end

    it "treats a per-event to: resolver's single bare Hash return value as one row too" do
      config = outbound! do
        event :lead_signed, to: ->(_event) { { url: "https://a.example/hook", id: "17" } }
      end
      resolution = config.resolve_subscribers(:lead_signed)

      expect(resolution.subscribers.map(&:url)).to eq(["https://a.example/hook"])
    end

    it "still raises loudly on an unknown EVENT (unaffected by per-row rejection)" do
      config = outbound! { event :lead_signed, to: ["https://a.example/hook"] }
      expect { config.resolve_subscribers(:nope) }.to raise_error(Axn::Webhooks::Error, /unknown outbound event/)
    end
  end

  describe "allowed_hosts / allow_url declared on the outbound block" do
    it "rejects a runtime-resolved row whose host isn't on the allowlist" do
      config = outbound! do
        allowed_hosts %w[good.example]
        subscribers ->(_event) { ["https://good.example/hook", "https://evil.example/hook"] }
        event :lead_closed
      end
      resolution = config.resolve_subscribers(:lead_closed)

      expect(resolution.subscribers.map(&:url)).to eq(["https://good.example/hook"])
      expect(resolution.rejections.first[:reason]).to match(/not allowed/)
    end

    it "rejects a STATIC to: entry the allowlist refuses, at BOOT time (ArgumentError, not a runtime rejection)" do
      expect do
        outbound! do
          allowed_hosts %w[good.example]
          event :x, to: ["https://evil.example/hook"]
        end
      end.to raise_error(ArgumentError, /not allowed/)
    end

    it "enforces a declared allow_url predicate against a runtime-resolved row" do
      config = outbound! do
        allow_url ->(uri) { uri.host == "good.example" }
        subscribers ->(_event) { ["https://good.example/hook", "https://evil.example/hook"] }
        event :lead_closed
      end
      resolution = config.resolve_subscribers(:lead_closed)

      expect(resolution.subscribers.map(&:url)).to eq(["https://good.example/hook"])
    end

    # Codex P2 finding, round 6: a static `to:` entry is validated ONCE, at boot
    # (`validate_event!`) -- documented as such in the README's "Boot-time validation" section.
    # Re-running `allow_url` again on every `resolve_subscribers`/`emit` call is wasted work for a
    # target that can never change, and genuinely BREAKS a stateful/rate-limited predicate: it
    # could reject an already-boot-validated static target later, contrary to the documented
    # once-at-boot contract.
    it "does NOT re-invoke allow_url for a STATIC to: entry on every resolution (validated once, at boot)" do
      calls = 0
      config = outbound! do
        allow_url lambda { |_uri|
          calls += 1
          true
        }
        event :lead_signed, to: ["https://a.example/hook"]
      end
      calls_after_boot = calls

      3.times { config.resolve_subscribers(:lead_signed) }

      expect(calls_after_boot).to eq(1)
      expect(calls).to eq(calls_after_boot) # unchanged across 3 more resolutions
    end

    it "STILL re-invokes allow_url for a runtime subscribers/to: resolver's row on every resolution" do
      calls = 0
      config = outbound! do
        allow_url lambda { |_uri|
          calls += 1
          true
        }
        subscribers ->(_event) { ["https://a.example/hook"] }
        event :lead_closed
      end

      3.times { config.resolve_subscribers(:lead_closed) }

      expect(calls).to eq(3)
    end

    it "rejects a non-callable allow_url at boot" do
      expect do
        outbound! do
          allow_url("not-callable")
          event :x, to: ["https://a.example/hook"]
        end
      end
        .to raise_error(ArgumentError, /allow_url got invalid value.*must be a callable/)
    end

    # Codex P1 finding: `allow_url(callable = nil, &block) = @allow_url = callable || block` turns
    # an explicit `allow_url false` into `nil` -- SILENTLY disabling the host policy entirely
    # (with no allowed_hosts either, every URL would then pass) rather than surfacing the
    # boot-time "must be a callable" error a genuinely non-callable value should raise.
    it "rejects an explicit `allow_url false` rather than silently disabling the policy" do
      expect do
        outbound! do
          allow_url false
          event :x, to: ["https://a.example/hook"]
        end
      end.to raise_error(ArgumentError, /allow_url got invalid value.*must be a callable/)
    end

    it "rejects a zero-arity allow_url at boot (it needs the parsed URI to do anything useful)" do
      expect do
        outbound! do
          allow_url(-> { true })
          event :x, to: ["https://a.example/hook"]
        end
      end
        .to raise_error(ArgumentError, /allow_url got invalid value.*must be a callable/)
    end

    # The splat-friendly DSL always wraps a single arg into an Array, so a non-String element is
    # the only way left to trip the setting's own validator.
    it "rejects a non-String element" do
      expect do
        outbound! do
          allowed_hosts(123)
          event :x, to: ["https://a.example/hook"]
        end
      end
        .to raise_error(ArgumentError, /allowed_hosts got invalid value.*must be an Array/)
    end
  end

  describe "callable-object resolvers (no #arity of their own)" do
    it "invokes a plain callable OBJECT subscribers resolver via #call, not bare #arity (Codex-style finding)" do
      store = Class.new { def call(event) = ["https://store.example/#{event}"] }.new
      config = outbound! do
        subscribers store
        event :lead_closed
      end

      expect(config.resolve_subscribers(:lead_closed).subscribers.map(&:url)).to eq(["https://store.example/lead_closed"])
    end

    it "invokes a zero-arity callable object too" do
      store = Class.new { def call = ["https://store.example/fixed"] }.new
      config = outbound! do
        subscribers store
        event :lead_closed
      end

      expect(config.resolve_subscribers(:lead_closed).subscribers.map(&:url)).to eq(["https://store.example/fixed"])
    end
  end

  describe "pre-existing Proc/lambda resolver dispatch (Codex P2 finding, pre-dates PRO-3214)" do
    # A Proc (non-lambda) with a single OPTIONAL/default param reports arity 0 -- a Ruby quirk
    # (a lambda with the identical signature reports -1 instead) -- and the ORIGINAL dispatch rule
    # (`callable.arity.zero? ? call : call(event)`) already relied on exactly that quirk to let a
    # `proc { |event = :all| ... }` resolver fall back to its own default. Switching to a
    # #parameters-based `accepts?` check would have silently started passing the event instead,
    # changing which subscribers get selected for any resolver already written this way.
    it "still uses ITS OWN default for a Proc (not lambda) subscribers resolver with an optional param" do
      seen = []
      resolver = proc { |event = :fallback_event|
        seen << event
        ["https://resolved/#{event}"]
      }
      config = outbound! do
        subscribers resolver
        event :lead_closed
      end

      config.resolve_subscribers(:lead_closed)

      expect(seen).to eq([:fallback_event])
    end

    # The flip side, also preserved: a LAMBDA with an optional/default param reports NEGATIVE
    # arity (not zero), so the original rule already passed it the event -- unaffected by this
    # fix, asserted here so the two shapes' different treatment stays intentional, not accidental.
    it "still passes the event to a LAMBDA subscribers resolver with an optional param (arity is negative, not zero)" do
      seen = []
      resolver = lambda { |event = :fallback_event|
        seen << event
        ["https://resolved/#{event}"]
      }
      config = outbound! do
        subscribers resolver
        event :lead_closed
      end

      config.resolve_subscribers(:lead_closed)

      expect(seen).to eq([:lead_closed])
    end
  end
end
