# frozen_string_literal: true

RSpec.describe Axn::Webhooks::Outbound::TargetPolicy do
  let(:subscriber_class) { Axn::Webhooks::Outbound::Subscriber }

  def check!(raw, allowed_hosts: nil, allow_url: nil)
    described_class.check!(raw, allowed_hosts:, allow_url:)
  end

  describe "URL shape (moved verbatim from Config#validate_url!)" do
    it "accepts a plain http(s) String URL, with or without a host allowlist" do
      expect(check!("https://x.example/hook")).to eq(subscriber_class.new(url: "https://x.example/hook", id: nil))
    end

    it "accepts a Hash row and returns the coerced Subscriber" do
      expect(check!({ url: "https://x.example/hook", id: 17 }))
        .to eq(subscriber_class.new(url: "https://x.example/hook", id: "17"))
    end

    it "rejects a non-String URL (e.g. a URI object) instead of letting it through via #to_s" do
      expect { check!(URI("https://x.example/hook")) }
        .to raise_error(Axn::Webhooks::InvalidTarget, /must be a String URL or a Hash/)
    end

    it "rejects a non-http(s) scheme" do
      expect { check!("file:///etc/passwd") }
        .to raise_error(Axn::Webhooks::InvalidTarget, /must be http\(s\)/)
    end

    it "rejects an unparseable URL" do
      expect { check!("http://[::not-a-host") }
        .to raise_error(Axn::Webhooks::InvalidTarget, /is not a valid URL/)
    end

    it "rejects an http(s) scheme with no host" do
      %w[https:foo https: https:///hook].each do |url|
        expect { check!(url) }.to raise_error(Axn::Webhooks::InvalidTarget, /must be http\(s\)/), "expected #{url.inspect} to be rejected"
      end
    end
  end

  describe "allowed_hosts" do
    it "passes an exact host match" do
      expect(check!("https://hooks.partner.example/x", allowed_hosts: %w[hooks.partner.example]).url)
        .to eq("https://hooks.partner.example/x")
    end

    it "rejects a host not on the list" do
      expect { check!("https://evil.example/x", allowed_hosts: %w[hooks.partner.example]) }
        .to raise_error(Axn::Webhooks::InvalidTarget, /host.*not allowed/i)
    end

    it "matches a case-insensitive host" do
      expect(check!("https://HOOKS.PARTNER.EXAMPLE/x", allowed_hosts: %w[hooks.partner.example]).url)
        .to eq("https://HOOKS.PARTNER.EXAMPLE/x")
    end

    it "matches a leading-wildcard entry against any subdomain, but not the bare suffix itself" do
      expect(check!("https://a.customer.example/x", allowed_hosts: %w[*.customer.example]).url)
        .to eq("https://a.customer.example/x")
      expect { check!("https://customer.example/x", allowed_hosts: %w[*.customer.example]) }
        .to raise_error(Axn::Webhooks::InvalidTarget, /host.*not allowed/i)
    end

    it "is not consulted when nil (any http(s) URL passes, today's behavior)" do
      expect(check!("https://anything.example/x", allowed_hosts: nil).url).to eq("https://anything.example/x")
    end
  end

  describe "allow_url" do
    it "passes a URL the predicate approves, and receives the parsed URI" do
      seen = nil
      check!("https://x.example/hook", allow_url: lambda { |uri|
        seen = uri
        true
      })
      expect(seen).to be_a(URI)
      expect(seen.host).to eq("x.example")
    end

    it "rejects a URL the predicate refuses" do
      expect { check!("https://x.example/hook", allow_url: ->(_uri) { false }) }
        .to raise_error(Axn::Webhooks::InvalidTarget, /rejected by allow_url/)
    end
  end

  describe "conjunction of both guards" do
    it "requires BOTH allowed_hosts and allow_url to pass" do
      expect do
        check!("https://hooks.partner.example/x", allowed_hosts: %w[hooks.partner.example], allow_url: ->(_uri) { false })
      end.to raise_error(Axn::Webhooks::InvalidTarget, /rejected by allow_url/)
    end
  end

  # Codex P2 finding, round 11: a runtime `subscribers`/`to:` resolver may hand back a `Subscriber`
  # it keeps its OWN reference to (unlike a Hash/String row, which `coerce` always turns into a
  # brand-new object) -- `coerce_subscriber` returns that SAME object when its `id` is already
  # normalized. Config's `deep_freeze!`/`config_owned` only ever runs at BOOT, over a static `to:`
  # Array; nothing freezes a RUNTIME-resolved Subscriber's `url`/`id` Strings. Between `check!`
  # validating a row and `Emit`'s fan-out actually reading `subscriber.url` to deliver, a caller
  # holding that same reference could mutate the String IN PLACE (`subscriber.url << "..."`) --
  # swapping in a URL that was never validated at all, after the fact.
  describe "mutation safety" do
    it "returns a Subscriber whose url/id are frozen, even when the caller mutates its own original strings" do
      url = +"https://hooks.partner.example/hook"
      id = +"17"
      sub = subscriber_class.new(url:, id:)

      checked = check!(sub, allowed_hosts: %w[hooks.partner.example])

      expect(checked.url).to be_frozen
      expect(checked.id).to be_frozen

      url << "-mutated-after-validation"
      id << "-mutated"

      expect(checked.url).to eq("https://hooks.partner.example/hook")
      expect(checked.id).to eq("17")
    end
  end

  describe ".redact_url" do
    it "strips userinfo, path, query, and fragment, keeping only the origin (scheme/host/port)" do
      redacted = described_class.redact_url("https://user:secret@evil.example/hook?token=live-key#frag")

      expect(redacted).to eq("https://evil.example")
    end

    # Codex P1 finding, round 8: a webhook URL commonly encodes its credential IN THE PATH itself
    # -- Slack/Discord/Teams incoming-webhook URLs are exactly `https://host/services/T00/B00/
    # <secret-token>`, no userinfo or query string involved at all. There's no general way to tell
    # a "meaningful, harmless" path apart from a "the path IS the secret" one, so the only safe
    # default is to drop the path unconditionally, same as userinfo/query/fragment.
    it "strips a credential embedded in the PATH (the common Slack/Discord/Teams webhook-URL shape)" do
      redacted = described_class.redact_url("https://hooks.example/services/T00/B00/live-secret-do-not-leak")

      expect(redacted).to eq("https://hooks.example")
    end

    it "preserves a non-default port" do
      expect(described_class.redact_url("https://a.example:8443/hook")).to eq("https://a.example:8443")
    end

    it "leaves a bare origin (no path/query/etc. to strip) unchanged" do
      expect(described_class.redact_url("https://a.example")).to eq("https://a.example")
    end

    it "falls back to a safe class/size description for an unparseable String" do
      expect(described_class.redact_url("http://[::not-a-host")).to match(/unparseable/)
    end
  end

  # Codex P1 finding, round 7: sanitizing ONLY `Config#redact_target`'s representation of a
  # rejected row wasn't enough -- every InvalidTarget MESSAGE that echoes a URL back (the http(s)
  # check, and allow_url's rejection message) embedded the raw, unredacted URL, and that message
  # is exactly what `Config#resolve_subscribers` stores as `reason:` in `result.rejected` and
  # reports via `on_exception`.
  describe "error messages never echo a raw credential-bearing URL" do
    it "redacts the URL in the http(s)-scheme rejection message" do
      expect { check!("ftp://user:live-key-do-not-leak@evil.example/hook?token=also-do-not-leak") }
        .to raise_error(Axn::Webhooks::InvalidTarget) { |e| expect(e.message).not_to include("live-key-do-not-leak", "also-do-not-leak") }
    end

    it "redacts the URL in the allow_url rejection message" do
      expect { check!("https://user:live-key-do-not-leak@evil.example/hook?token=also-do-not-leak", allow_url: ->(_uri) { false }) }
        .to raise_error(Axn::Webhooks::InvalidTarget) { |e| expect(e.message).not_to include("live-key-do-not-leak", "also-do-not-leak") }
    end
  end
end
