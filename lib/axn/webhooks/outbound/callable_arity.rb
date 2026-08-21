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
      end
    end
  end
end
