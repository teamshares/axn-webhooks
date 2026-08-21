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
          subscriber
        end

        def parse_url!(url)
          # A non-String (e.g. a `URI` object) would parse fine here via `#to_s`, but the ORIGINAL
          # object is what a static `to:` entry keeps in `@events` and what `Deliver` is later handed
          # as `url:` (`expects :url, type: String`) -- accepted here, rejected at delivery time
          # instead. Require a String outright rather than normalizing.
          raise Axn::Webhooks::InvalidTarget, "URL must be a String (got #{url.class})" unless url.is_a?(String)

          uri = URI.parse(url)
          raise Axn::Webhooks::InvalidTarget, "URL #{url.inspect} must be http(s)" unless http_uri?(uri)

          uri
        rescue URI::InvalidURIError
          raise Axn::Webhooks::InvalidTarget, "URL #{url.inspect} is not a valid URL"
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

          raise Axn::Webhooks::InvalidTarget, "URL #{uri} was rejected by allow_url" unless allow_url.call(uri)
        end
      end
    end
  end
end
