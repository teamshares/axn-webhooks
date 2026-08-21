# frozen_string_literal: true

module Axn
  module Webhooks
    module Outbound
      # Whether `callable.call(*args)` actually works for exactly `count` positional arguments — via
      # `#parameters`, which correctly distinguishes required/optional/rest/keyword params uniformly
      # across a lambda, a non-strict Proc, and a plain object's `#call` Method. `#arity` alone can't
      # tell "one required positional" apart from "one required KEYWORD" (same arity, one raises) or
      # "needs 2+ positional, has a splat" (negative arity, but still too few args at `count == 1`) —
      # both boot-time-valid under a bare arity check, both raising `ArgumentError` on the very first
      # real invocation (Codex P2 findings, on `backoff`, `user_agent`, and the signing `secret`).
      module CallableArity
        module_function

        def accepts?(callable, count)
          params = callable.respond_to?(:parameters) ? callable.parameters : callable.method(:call).parameters
          return false if params.any? { |(type, _)| type == :keyreq }

          required = params.count { |(type, _)| type == :req }
          return false if required > count

          optional = params.count { |(type, _)| type == :opt }
          rest = params.any? { |(type, _)| type == :rest }
          required + optional + (rest ? 1 : 0) >= count
        end

        # Which keyword names `callable.call(**kwargs)` actually accepts: `:all` for a callable that
        # double-splats (accepts anything), else the Array of Symbol names it declares (required and
        # optional alike). Used to filter a fixed kwarg set down to what a caller-supplied signing
        # block declares (`CustomSigner`), so a block written against today's `(id:, timestamp:,
        # body:)` contract keeps working byte-for-byte when a widened caller starts also offering
        # `url:`/`subscriber:` — those become a plain ArgumentError from a *filtered* call, not a
        # silent widening the block didn't ask for.
        def accepted_keywords(callable)
          params = callable.respond_to?(:parameters) ? callable.parameters : callable.method(:call).parameters
          return :all if params.any? { |(type, _)| type == :keyrest }

          params.select { |(type, _)| %i[key keyreq].include?(type) }.map { |(_, name)| name }
        end

        # Which keyword names `callable.call(**kwargs)` REQUIRES — a strict subset of
        # `accepted_keywords` (excludes optional `:key` params). Used to catch a callable that
        # needs a keyword outside a fixed supplied set (e.g. `sign { |id:, vendor:| … }`, where
        # `vendor:` is never one of the kwargs this gem passes a signer) — the one shape that
        # genuinely fails on every call, as opposed to a callable that simply ignores some/all of
        # what it's offered (which Ruby's own Proc/block semantics already tolerate fine).
        def required_keywords(callable)
          params = callable.respond_to?(:parameters) ? callable.parameters : callable.method(:call).parameters
          params.select { |(type, _)| type == :keyreq }.map { |(_, name)| name }
        end

        # The ORIGINAL `subscribers`/`to:` resolver dispatch rule, preserved byte-for-byte (Codex P2
        # finding): "pass the event unless the callable's raw arity is EXACTLY zero." Deliberately
        # raw #arity, not #parameters-based: a Proc (non-lambda) with a single OPTIONAL/default
        # param reports arity `0` (a Ruby quirk -- lambda-with-default reports NEGATIVE instead),
        # and that quirk is exactly what a pre-existing `proc { |event = :all| … }` resolver already
        # relied on to keep using its own default. Only made callable-object-safe here (falls back
        # to `Method#arity` via `#call`) -- the dispatch RULE itself is unchanged.
        def zero_arity?(callable)
          raw_arity(callable).zero?
        end

        # For a newly-introduced 0-OR-1-arity callable (PRO-3214's per-subscriber `secret`/
        # `headers`): prefer a zero-arg call whenever genuinely possible. Raw arity, not
        # `#parameters`-based `accepts?`: a plain `proc { |subscriber| … }` (NO default) reports its
        # param as `:opt` via `#parameters` -- indistinguishable from a genuine default by that
        # API -- but its raw arity is still the correct POSITIVE `1`, so this is the one signal that
        # tells "has a real default/rest" (arity <= 0) apart from "merely tolerates a missing arg,
        # Proc-style, but was never given one to default from" (Codex P1 finding: passing `nil` in
        # place of the subscriber for exactly this shape).
        def prefers_zero_args?(callable)
          raw_arity(callable) <= 0
        end

        # Shared by `zero_arity?`/`prefers_zero_args?`: raw `#arity`, falling back to
        # `Method#arity` via `#call` for a plain callable object with none of its own.
        def raw_arity(callable)
          callable.respond_to?(:arity) ? callable.arity : callable.method(:call).arity
        end
      end
    end
  end
end
