# frozen_string_literal: true

module Axn
  module Webhooks
    module Inbound
      # instance_exec context for a `respond` block: exposes `ack`/`text`/`xml`/`json` as bare calls,
      # so a respond proc reads `text("...")` rather than `Axn::Webhooks::Response.text("...")` —
      # mirrors how the `verify` custom block gets `header`/`params`/etc. as bare calls from DSL.
      class RespondContext
        def ack(**) = Response.ack(**)
        def text(body, **) = Response.text(body, **)
        def xml(body, **) = Response.xml(body, **)
        def json(body, **) = Response.json(body, **)
      end
    end
  end
end
