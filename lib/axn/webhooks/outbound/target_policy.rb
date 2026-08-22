# frozen_string_literal: true

require "uri"

module Axn
  module Webhooks
    module Outbound
      # The single place a resolved subscriber row is validated -- shared by `Config`'s boot-time
      # check of a static `to:` Array and `Config#resolve_subscribers`'s per-emission check of
      # whatever `subscribers`/`to:` resolved to at runtime, so the two paths can never drift apart
      # (they used to: only the static path was checked; see this file's origin,
      # `Config#validate_url!`).
      #
      # `allowed_hosts`/`allow_url` are a HOST policy, not a network one: neither resolves DNS, so
      # neither is proof against DNS rebinding or a hostname that resolves to a private IP at request
      # time. `allow_url` is handed the parsed URI so an app that needs that guarantee can add its
      # own resolution check there.
      module TargetPolicy
        module_function

        def check!(raw, allowed_hosts: nil, allow_url: nil)
          subscriber = Subscriber.coerce(raw)
          uri = parse_url!(subscriber.url)
          check_host_allowlist!(uri, allowed_hosts)
          check_allow_url!(uri, allow_url)
          snapshot(subscriber)
        end

        # A runtime `subscribers`/`to:` resolver may hand back a `Subscriber` it keeps its own
        # reference to -- `Subscriber.coerce`'s Subscriber branch returns that SAME object when its
        # `id` is already normalized, unlike a Hash/String row (which always produces a fresh one).
        # Config's boot-time `deep_freeze!`/`config_owned` never runs over this path (it only covers
        # a static `to:` Array), so nothing stops the caller from mutating `url`/`id` IN PLACE after
        # this method has already validated them but before `Emit`'s fan-out reads them to actually
        # deliver -- swapping in a URL that was never checked at all (Codex P2 finding, round 11).
        # Dup+freezing fresh copies here closes that window regardless of what the caller does next.
        #
        # Called LAST, only once `parse_url!` has already confirmed `url` is a String -- calling
        # this BEFORE that check (as an earlier version did) ran `.dup` on whatever a malformed row
        # handed back verbatim; a non-duplicable object there (`Thread.current` -- anything without
        # an allocator behaves the same) raises a bare TypeError, which `Config#check_targets`'s
        # `rescue Axn::Webhooks::InvalidTarget` never catches -- aborting the WHOLE fan-out instead
        # of rejecting just the one malformed row (Codex P2 finding, round 16). `id` needs no such
        # ordering care: `Subscriber.coerce` already stringifies it (or leaves it nil) in every
        # branch, so it's always dup-safe by the time ANY code here runs.
        def snapshot(subscriber)
          Subscriber.new(url: subscriber.url.dup.freeze, id: subscriber.id&.dup&.freeze)
        end

        def parse_url!(url)
          # A non-String (e.g. a `URI` object) would parse fine here via `#to_s`, but the ORIGINAL
          # object is what a static `to:` entry keeps in `@events` and what `Deliver` is later handed
          # as `url:` (`expects :url, type: String`) -- accepted here, rejected at delivery time
          # instead. Require a String outright rather than normalizing.
          raise Axn::Webhooks::InvalidTarget, "URL must be a String (got #{url.class})" unless url.is_a?(String)

          uri = URI.parse(url)
          raise Axn::Webhooks::InvalidTarget, "URL #{redact_url(url)} must be http(s)" unless http_uri?(uri)

          uri
        rescue URI::Error
          # `URI.parse` doesn't raise ONLY `URI::InvalidURIError` for a malformed URL -- a
          # scheme-specific parser can raise a SIBLING class instead (e.g.
          # `URI::InvalidComponentError` for `"mailto:foo"`, which has no `@`); that class is NOT a
          # subclass of `InvalidURIError`, so rescuing only the latter let it escape uncaught past
          # `Config#check_targets`'s `rescue Axn::Webhooks::InvalidTarget`, aborting the WHOLE
          # fan-out instead of rejecting just the one malformed row (Codex P2 finding, round 17).
          # `URI::Error` is the common ancestor of every URI parse failure.
          raise Axn::Webhooks::InvalidTarget, "URL #{redact_url(url)} is not a valid URL"
        end

        def http_uri?(uri) = %w[http https].include?(uri.scheme) && !uri.host.to_s.empty?

        def check_host_allowlist!(uri, allowed_hosts)
          return if allowed_hosts.nil?

          return if allowed_hosts.any? { |pattern| host_matches?(pattern, uri.host) }

          raise Axn::Webhooks::InvalidTarget, "host #{uri.host.inspect} is not allowed (allowed_hosts: #{allowed_hosts.inspect})"
        end

        # A bare entry is an exact (case-insensitive) host match; a `*.suffix` entry matches any
        # subdomain of `suffix` but NOT the bare suffix itself -- standard wildcard-cert semantics,
        # so `*.customer.example` doesn't accidentally also allow the apex domain.
        def host_matches?(pattern, host)
          return false if host.nil?

          if pattern.start_with?("*.")
            host.downcase.end_with?(".#{pattern[2..].downcase}")
          else
            host.casecmp?(pattern)
          end
        end

        # `allow_url` is always called with the parsed URI (arity 1 required at boot — see Config's
        # setting validator — matching the same "the callable's whole purpose is examining its
        # argument" precedent `backoff` already sets, rather than the zero-OR-one tolerance
        # `user_agent`/a signing `secret` get).
        def check_allow_url!(uri, allow_url)
          return if allow_url.nil?

          raise Axn::Webhooks::InvalidTarget, "URL #{redact_url(uri.to_s)} was rejected by allow_url" unless allow_url.call(uri)
        end

        # A webhook URL commonly carries a credential ITSELF -- HTTP Basic userinfo
        # (`https://user:pass@host/...`), a signed/token query param, or -- the most common real
        # shape (Slack/Discord/Teams incoming webhooks are exactly this) -- a secret token AS THE
        # PATH, e.g. `https://hooks.example/services/T00/B00/<secret>`. There's no general way to
        # tell a "meaningful, harmless" path apart from a "the path IS the secret" one, so no
        # InvalidTarget message may echo more than the ORIGIN verbatim (Codex P1 finding, rounds 6
        # and 8): every message above that would otherwise interpolate a URL routes through here
        # first. Strips userinfo/PATH/query/fragment, keeping only scheme/host/port -- enough to
        # debug which HOST was rejected and why, without ever risking a credential. Also used by
        # `Config#redact_target`'s Hash-row `:url` handling, so a rejected `{ url:, id: }` row's
        # own url gets the identical treatment.
        def redact_url(url)
          uri = URI.parse(url)
          uri.user = nil
          uri.password = nil
          uri.path = ""
          uri.query = nil
          uri.fragment = nil
          uri.to_s
        rescue URI::Error, ArgumentError
          # Same reasoning as `parse_url!`'s rescue (round 17): a scheme-specific parser can raise
          # a `URI::Error` SIBLING of `InvalidURIError` (e.g. `InvalidComponentError`) that isn't
          # caught by name -- and this method is called from INSIDE `parse_url!`'s own rescue
          # handler to build the redacted message, so a narrower rescue here would raise a SECOND,
          # uncaught exception in place of the `InvalidTarget` that call is trying to construct.
          "<unparseable URL, #{url.to_s.bytesize} bytes>"
        end
      end
    end
  end
end
