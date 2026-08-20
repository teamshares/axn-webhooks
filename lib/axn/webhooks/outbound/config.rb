# frozen_string_literal: true

require "uri"

module Axn
  module Webhooks
    module Outbound
      # The resolved, immutable outbound declaration. One per process (a single `outbound` block).
      class Config
        DEFAULT_MAX_ATTEMPTS = 8
        # Equal jitter (half fixed, half random): a fan-out event whose receiver is down would
        # otherwise have every failing target retry in lockstep, converging on the same instant.
        DEFAULT_BACKOFF = lambda do |attempt|
          base = [30 * (3**(attempt - 1)), 6 * 3600].min
          ((base / 2.0) + (rand * base / 2.0)).round
        end
        DEFAULT_OPEN_TIMEOUT = 5
        DEFAULT_READ_TIMEOUT = 10

        def initialize(signer:, events:, default_subscribers:, max_attempts:, backoff:, transport:,
                       vendor: nil, user_agent: nil, open_timeout: nil, read_timeout: nil)
          @signer = signer
          @events = events # { Symbol => { to:, type:, vendor: } }
          @default_subscribers = default_subscribers
          @max_attempts = max_attempts || DEFAULT_MAX_ATTEMPTS
          @backoff = backoff || DEFAULT_BACKOFF
          @transport = transport || Transport
          @vendor = vendor
          @user_agent = user_agent
          @open_timeout = open_timeout || DEFAULT_OPEN_TIMEOUT
          @read_timeout = read_timeout || DEFAULT_READ_TIMEOUT

          validate!
        end

        attr_reader :signer, :max_attempts, :backoff, :transport, :user_agent, :open_timeout, :read_timeout

        def events = @events.keys

        def wire_type(event)
          (fetch(event)[:type] || event).to_s
        end

        # A per-event `vendor:` overrides the block-level default; same precedence as `type:`.
        def vendor_for(event)
          fetch(event)[:vendor] || @vendor
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
        # network failure).
        def validate!
          unless @max_attempts.is_a?(Integer) && @max_attempts.positive?
            raise Axn::Webhooks::Error, "outbound max_attempts must be a positive Integer (got #{@max_attempts.inspect})"
          end

          unless @backoff.respond_to?(:call) && backoff_accepts_attempt?
            raise Axn::Webhooks::Error, "outbound backoff must be a callable accepting the attempt number"
          end

          @events.each { |name, spec| validate_event!(name, spec) }
        end

        def backoff_accepts_attempt?
          arity = @backoff.arity
          arity == 1 || arity.negative?
        end

        def validate_event!(name, spec)
          return if spec[:to].nil? || spec[:to].respond_to?(:call)

          unless spec[:to].is_a?(Array)
            raise Axn::Webhooks::Error,
                  "outbound event #{name.inspect} `to:` must be an Array of URLs or a callable (got #{spec[:to].class})"
          end

          spec[:to].each { |url| validate_url!(name, url) }
        end

        def validate_url!(name, url)
          uri = URI.parse(url.to_s)
          return if %w[http https].include?(uri.scheme)

          raise Axn::Webhooks::Error, "outbound event #{name.inspect} `to:` URL #{url.inspect} must be http(s)"
        rescue URI::InvalidURIError
          raise Axn::Webhooks::Error, "outbound event #{name.inspect} `to:` URL #{url.inspect} is not a valid URL"
        end
      end
    end
  end
end
