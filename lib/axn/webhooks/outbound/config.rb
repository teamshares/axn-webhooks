# frozen_string_literal: true

require "uri"

module Axn
  module Webhooks
    module Outbound
      # The resolved, immutable outbound declaration. One per process (a single `outbound` block).
      class Config
        # Validated settings via the upstream Axn::Configurable DSL (class flavor) — max_attempts/
        # backoff/transport/vendor/user_agent/timeouts are simple, independently valid-or-not values.
        # `events` (and its `to:`/URL structure) stays hand-written below: it's a Hash built and
        # cross-validated as a whole from one DSL block, not a flat setting.
        extend Axn::Configurable::Settings

        DEFAULT_MAX_ATTEMPTS = 8
        # Equal jitter (half fixed, half random): a fan-out event whose receiver is down would
        # otherwise have every failing target retry in lockstep, converging on the same instant.
        DEFAULT_BACKOFF = lambda do |attempt|
          base = [30 * (3**(attempt - 1)), 6 * 3600].min
          ((base / 2.0) + (rand * base / 2.0)).round
        end
        DEFAULT_OPEN_TIMEOUT = 5
        DEFAULT_READ_TIMEOUT = 10

        # Every Configurable setting declared below. Read once in `initialize` before freezing:
        # Configurable memoizes a STATIC default into an ivar on first read, so a frozen Config
        # would otherwise raise FrozenError from the reader of any setting the `outbound` block
        # never explicitly assigned. `backoff`/`transport` escape only because their defaults are
        # dynamic (`-> { … }`) and recomputed per read — an inconsistency to design around, not
        # rely on.
        SETTING_NAMES = %i[max_attempts backoff transport vendor user_agent open_timeout read_timeout].freeze

        setting :max_attempts, default: DEFAULT_MAX_ATTEMPTS,
                               validate: ->(v) { (v.is_a?(Integer) && v.positive?) || "must be a positive Integer" }
        # The default itself IS a callable (not a value computed BY one) — a bare Proc default would
        # otherwise be read as "call this with no args to derive the default" (Configurable's dynamic-
        # default convention) and blow up on DEFAULT_BACKOFF's required `attempt` arg. A zero-arity
        # wrapper resolves to the lambda itself instead.
        # `arity == 1 || arity.negative?` alone can't tell "one required positional" apart from "one
        # required KEYWORD" (same arity, one raises on `.call(attempt)`) or "needs 2+ positional, has
        # a splat" (negative arity, still too few args) — see CallableArity.
        setting :backoff, default: -> { DEFAULT_BACKOFF },
                          validate: lambda { |v|
                            next "must be a callable accepting the attempt number" unless v.respond_to?(:call)

                            CallableArity.accepts?(v, 1) || "must be a callable accepting the attempt number"
                          }
        # Same reasoning as `backoff`: `Transport` is a Module, and Configurable's non-dynamic default
        # path calls `.dup` on it — silently swapping in an anonymous copy that fails every `== Transport`
        # identity check downstream (e.g. Deliver's timeout-forwarding guard).
        setting :transport, default: -> { Transport }
        setting :vendor
        # Deliver's `resolve_user_agent_suffix` calls a callable value with NO arguments (a zero-arg
        # invocation is the documented contract) — one that requires an argument would otherwise boot
        # successfully and raise ArgumentError on every real delivery (Codex P2 finding).
        setting :user_agent,
                validate: lambda { |v|
                  next true unless v.respond_to?(:call)

                  CallableArity.accepts?(v, 0) || "callable must accept zero arguments (resolved with no args per delivery attempt)"
                }
        # Forwarded straight to Net::HTTP (see Transport), which calls `.zero?`/compares on whatever
        # it's given — an unvalidated non-Numeric (e.g. a String from `ENV.fetch("OPEN_TIMEOUT")`)
        # would otherwise raise NoMethodError mid-delivery instead of failing at boot (Codex P2
        # finding).
        TIMEOUT_VALIDATE = ->(v) { (v.is_a?(Numeric) && v.positive?) || "must be a positive Numeric" }
        setting :open_timeout, default: DEFAULT_OPEN_TIMEOUT, validate: TIMEOUT_VALIDATE
        setting :read_timeout, default: DEFAULT_READ_TIMEOUT, validate: TIMEOUT_VALIDATE

        # The problem with `url` as an outbound target, or nil when there is none. A predicate
        # rather than a raiser, because its two callers disagree on the error class: a declaration
        # mistake at boot is an ArgumentError (see validate_url!), while a bad one-off `emit(to:)`
        # URL is an Axn::Webhooks::Error a caller may rescue at runtime (see Outbound::Emit).
        def self.url_problem(url)
          # A non-String (e.g. a `URI`) would parse fine via `#to_s`, but the ORIGINAL object is
          # what reaches `Deliver`, which `expects :url, type: String` and rejects. Require a
          # String outright rather than normalizing.
          return "must be a String (got #{url.class})" unless url.is_a?(String)

          uri = URI.parse(url)
          return nil if %w[http https].include?(uri.scheme) && !uri.host.to_s.empty?

          "#{url.inspect} must be http(s)"
        rescue URI::InvalidURIError
          "#{url.inspect} is not a valid URL"
        end

        def initialize(signer:, events:, default_subscribers:, max_attempts:, backoff:, transport:,
                       vendor: nil, user_agent: nil, open_timeout: nil, read_timeout: nil)
          @signer = signer
          @events = events # { Symbol => { to:, type:, vendor: } }
          @default_subscribers = default_subscribers

          self.max_attempts = max_attempts unless max_attempts.nil?
          self.backoff = backoff unless backoff.nil?
          self.transport = transport unless transport.nil?
          self.vendor = vendor unless vendor.nil?
          self.user_agent = user_agent unless user_agent.nil?
          self.open_timeout = open_timeout unless open_timeout.nil?
          self.read_timeout = read_timeout unless read_timeout.nil?

          @events.each { |name, spec| validate_event!(name, spec) }

          deep_freeze!
        end

        attr_reader :signer

        def events = @events.keys

        def wire_type(event)
          (fetch(event)[:type] || event).to_s
        end

        # A per-event `vendor:` overrides the block-level default; same precedence as `type:`.
        def vendor_for(event)
          fetch(event)[:vendor] || vendor
        end

        # A DECLARED per-event `to:` always wins, even when it resolves to zero targets — a static
        # Array as-is (including `[]`), or a lambda `->(event){…}` invoked (arity-aware, matching
        # Resolvers.resolve) and its result wrapped in Array (nil -> []). The block-level
        # `subscribers` resolver is ONLY consulted when the event declared no `to:` at all
        # (spec[:to].nil?) — never as a fallback for a declared resolver returning nil.
        def targets_for(event)
          spec = fetch(event)
          return Array(resolve_to(spec[:to], event)) unless spec[:to].nil?

          Array(call_resolver(@default_subscribers, event))
        end

        private

        # Freezes the CONTAINERS we own, never the caller's objects: a `to:` resolver, the signer,
        # an injected transport and a `user_agent` callable all stay mutable — they belong to the
        # app, and freezing them could break a memoizing resolver. A statically-declared `to:`
        # Array is ours once validated, so it freezes.
        def deep_freeze!
          SETTING_NAMES.each { |name| public_send(name) }
          @events.each_value do |spec|
            spec[:to].freeze if spec[:to].is_a?(Array)
            spec.freeze
          end
          @events.freeze
          freeze
        end

        def fetch(event)
          @events.fetch(event.to_sym) do
            raise Axn::Webhooks::Error,
                  "unknown outbound event #{event.inspect} (known: #{events.map(&:inspect).join(', ')})"
          end
        end

        def call_resolver(callable, event)
          return nil if callable.nil?

          callable.arity.zero? ? callable.call : callable.call(event)
        end

        # `to:` is "declared" whenever spec[:to] is non-nil — a static value (Array, including
        # `[]`) is returned as-is; a callable is invoked (arity-aware, via call_resolver).
        def resolve_to(raw, event)
          raw.respond_to?(:call) ? call_resolver(raw, event) : raw
        end

        # Boot-time validation, so a malformed declaration fails loudly here rather than as an
        # unexpected exception mid-delivery (which the async adapter would retry as if it were a
        # network failure). A pure declaration mistake — never triggered by runtime/user data, and
        # nothing a running app would want to rescue-and-continue past — so this raises plain
        # ArgumentError, same as `max_attempts`/`backoff` above, rather than the gem's own
        # `Axn::Webhooks::Error` (reserved for conditions a caller might legitimately rescue at
        # runtime, e.g. `fetch`'s unknown-event error below, raised on every `emit`/`targets_for`
        # call rather than once at boot).
        def validate_event!(name, spec)
          return if spec[:to].nil? || spec[:to].respond_to?(:call)

          unless spec[:to].is_a?(Array)
            raise ArgumentError,
                  "outbound event #{name.inspect} `to:` must be an Array of URLs or a callable (got #{spec[:to].class})"
          end

          spec[:to].each { |url| validate_url!(name, url) }
        end

        def validate_url!(name, url)
          problem = self.class.url_problem(url)
          return if problem.nil?

          raise ArgumentError, "outbound event #{name.inspect} `to:` URL #{problem}"
        end
      end
    end
  end
end
