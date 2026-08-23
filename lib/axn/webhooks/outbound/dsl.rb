# frozen_string_literal: true

module Axn
  module Webhooks
    module Outbound
      # Receiver for the `Axn::Webhooks.outbound do … end` block.
      class DSL
        # Distinguishes "argument omitted" from "an explicit falsy value was passed" for
        # `allow_url`/`headers` below -- `callable = nil` as the default can't tell `allow_url`
        # (nothing given) apart from `allow_url false` (a caller-supplied, non-callable value that
        # must be rejected at boot). `callable || block` treated both identically, silently
        # DISABLING the host policy / header resolver for an explicit `false` rather than
        # surfacing the setting's own "must be a callable" validation error (Codex P1 finding).
        UNSET = Object.new.freeze
        private_constant :UNSET

        def initialize
          @events = {}
          @sign_spec = nil
          @default_subscribers = nil
          @max_attempts = nil
          @backoff = nil
          @transport = nil
          @vendor = nil
          @user_agent = nil
          @open_timeout = nil
          @read_timeout = nil
          @allowed_hosts = nil
          @allow_url = nil
          @headers = nil
        end

        def sign(strategy = nil, **opts, &block)
          @sign_spec = { strategy:, opts:, block: }
        end

        def subscribers(resolver = nil, &block)
          @default_subscribers = resolver || block
        end

        def max_attempts(value) = @max_attempts = value
        def backoff(callable = nil, &block) = @backoff = callable || block
        def transport(obj) = @transport = obj

        # The observability facet (Axn::Webhooks.config.vendor_facet) stamped on every Emit/Deliver
        # for events with no per-event override — see `event`'s `vendor:`.
        def vendor(value) = @vendor = value

        # A suffix identifying the sending app/deploy, appended to the fixed
        # "axn-webhooks/<version>" User-Agent as "axn-webhooks/<version> (<value>)". Plain value or
        # a zero-arity callable, resolved per delivery attempt.
        def user_agent(value = nil, &block) = @user_agent = value || block

        def timeouts(open: nil, read: nil)
          @open_timeout = open
          @read_timeout = read
        end

        # A host policy for resolved targets (both a static `to:` Array and a runtime
        # `subscribers`/`to:` lambda's return value go through the same check) -- see TargetPolicy
        # for exact matching semantics. Splat-friendly: `allowed_hosts "a.example", "b.example"` and
        # `allowed_hosts %w[a.example b.example]` both work.
        def allowed_hosts(*values) = @allowed_hosts = values.flatten

        # A general escape hatch alongside `allowed_hosts` -- called with the parsed URI, must
        # return truthy to allow the target through. Both nil by default (no host policy at all).
        def allow_url(callable = UNSET, &block) = @allow_url = resolve_settable(callable, block)

        # Per-destination extra headers (e.g. a subscriber's bearer token) -- resolved fresh per
        # DELIVERY ATTEMPT from the Subscriber, never stored, same convention `sign`'s `secret:`
        # follows. 0-arity (ignores the subscriber) or 1-arity (receives it). nil by default.
        def headers(callable = UNSET, &block) = @headers = resolve_settable(callable, block)

        # rubocop:disable Naming/MethodParameterName
        def event(name, to: nil, type: nil, vendor: nil)
          @events[name.to_sym] = { to:, type:, vendor: }
        end
        # rubocop:enable Naming/MethodParameterName

        # Internal: build the resolved Config, validating declarations.
        def __config__
          # A pure declaration mistake (decided once at boot, never at runtime) — ArgumentError, not
          # Axn::Webhooks::Error, matching Config's own misconfiguration-vs-runtime split.
          raise ArgumentError, "outbound block must declare `sign`" if @sign_spec.nil?

          @events.each do |name, spec|
            next unless spec[:to].is_a?(Array) && spec[:to].empty?

            Axn.config.logger.warn("[axn-webhooks] outbound event #{name.inspect} declares an empty `to:` — it will deliver nowhere")
          end

          Config.new(
            signer: Signer.build(**@sign_spec),
            events: @events,
            default_subscribers: @default_subscribers,
            max_attempts: @max_attempts,
            backoff: @backoff,
            transport: @transport,
            vendor: @vendor,
            user_agent: @user_agent,
            open_timeout: @open_timeout,
            read_timeout: @read_timeout,
            allowed_hosts: @allowed_hosts,
            allow_url: @allow_url,
            headers: @headers,
          )
        end

        private

        # `callable` is UNSET only when the method was called with no positional argument at
        # all -- an explicit non-callable value (including `false`) must survive to `Config`'s
        # own setting validator rather than being silently coerced into "not set".
        def resolve_settable(callable, block)
          return block if block

          UNSET.equal?(callable) ? nil : callable
        end
      end
    end
  end
end
