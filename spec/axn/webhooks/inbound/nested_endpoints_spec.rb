# frozen_string_literal: true

RSpec.describe "nested inbound endpoints" do
  after { Axn::Webhooks::Inbound.reset! }

  it "registers one endpoint per child, named parent_child, and NOT the parent" do
    Axn::Webhooks.inbound :slack do
      verify :hmac, secret: "s", signature: header("X-Sig")

      endpoint(:interactivity) { dispatch to: "HandlerA" }
      endpoint(:events) { dispatch to: "HandlerB" }
    end

    expect(Axn::Webhooks::Inbound.registered).to contain_exactly(:slack_interactivity, :slack_events)
    expect { Axn::Webhooks::Inbound[:slack] }.to raise_error(KeyError)
  end

  it "gives every child the parent's declarations" do
    Axn::Webhooks.inbound :slack do
      verify :hmac, secret: "parent-secret", signature: header("X-Sig")
      unauthorized_headers "WWW-Authenticate" => 'Basic realm="Webhook"'

      endpoint(:events) { dispatch to: "HandlerB" }
    end

    endpoint = Axn::Webhooks::Inbound[:slack_events]
    expect(endpoint.unauthorized_headers).to eq("WWW-Authenticate" => 'Basic realm="Webhook"')

    # Endpoint exposes no `verifier` reader -- `verify(request)` is the public seam, returning an
    # Axn::Result (ok? when verified).
    body = "{}"
    sig = Axn::Webhooks::Signature.compute(secret: "parent-secret", payload: body)
    request = Axn::Webhooks::Request.new(raw_body: body, headers: { "X-Sig" => sig })
    expect(endpoint.verify(request)).to be_ok
  end

  it "lets a child override an inherited declaration by re-declaring it" do
    Axn::Webhooks.inbound :slack do
      verify :hmac, secret: "parent-secret", signature: header("X-Sig")

      endpoint(:events) do
        dispatch to: "HandlerB"
        verify :hmac, secret: "child-secret", signature: header("X-Sig")
      end
    end

    body = "{}"
    request = lambda do |secret|
      Axn::Webhooks::Request.new(
        raw_body: body,
        headers: { "X-Sig" => Axn::Webhooks::Signature.compute(secret:, payload: body) },
      )
    end

    endpoint = Axn::Webhooks::Inbound[:slack_events]
    expect(endpoint.verify(request.call("child-secret"))).to be_ok
    expect(endpoint.verify(request.call("parent-secret"))).not_to be_ok
  end

  it "isolates siblings -- a declaration in one child does not leak into another" do
    Axn::Webhooks.inbound :slack do
      verify :hmac, secret: "s", signature: header("X-Sig")

      endpoint(:interactivity) do
        dispatch to: "HandlerA"
        respond { |result| text(result.to_s) }
      end
      endpoint(:events) { dispatch to: "HandlerB" }
    end

    # Endpoint exposes no `respond` reader; read the ivar rather than adding one for a test's sake.
    expect(Axn::Webhooks::Inbound[:slack_interactivity].instance_variable_get(:@respond)).not_to be_nil
    expect(Axn::Webhooks::Inbound[:slack_events].instance_variable_get(:@respond)).to be_nil
  end

  it "inherits a parent `respond` into every child — the shared-renderer case nesting exists for" do
    Axn::Webhooks.inbound :slack do
      verify :hmac, secret: "s", signature: header("X-Sig")
      respond { |result| text(result.to_s) }

      endpoint(:interactivity) { dispatch to: "HandlerA" }
      endpoint(:events) { dispatch to: "HandlerB" }
    end

    expect(Axn::Webhooks::Inbound[:slack_interactivity].instance_variable_get(:@respond)).not_to be_nil
    expect(Axn::Webhooks::Inbound[:slack_events].instance_variable_get(:@respond)).not_to be_nil
  end

  it "inherits a parent `static_respond` too" do
    Axn::Webhooks.inbound :slack do
      verify :hmac, secret: "s", signature: header("X-Sig")
      static_respond { text("ok") }

      endpoint(:events) { dispatch to: "HandlerB" }
    end

    expect(Axn::Webhooks::Inbound[:slack_events].instance_variable_get(:@static_respond)).not_to be_nil
  end

  it "lets a child override an inherited `respond` with a `static_respond` (and the reverse)" do
    # Both renderer ivars are inherited, but Endpoint rejects having both set — so a cross-form
    # override has to clear the inherited one or it raises (Codex review).
    Axn::Webhooks.inbound :slack do
      verify :hmac, secret: "s", signature: header("X-Sig")
      respond { |result| text(result.to_s) }

      endpoint(:events) do
        dispatch to: "HandlerB"
        static_respond { text("ok") }
      end
    end

    endpoint = Axn::Webhooks::Inbound[:slack_events]
    expect(endpoint.instance_variable_get(:@static_respond)).not_to be_nil
    expect(endpoint.instance_variable_get(:@respond)).to be_nil
  end

  it "lets a child override an inherited `static_respond` with a `respond`" do
    Axn::Webhooks.inbound :slack do
      verify :hmac, secret: "s", signature: header("X-Sig")
      static_respond { text("ok") }

      endpoint(:events) do
        dispatch to: "HandlerB"
        respond { |result| text(result.to_s) }
      end
    end

    endpoint = Axn::Webhooks::Inbound[:slack_events]
    expect(endpoint.instance_variable_get(:@respond)).not_to be_nil
    expect(endpoint.instance_variable_get(:@static_respond)).to be_nil
  end

  it "still rejects declaring BOTH renderers in the same block — clearing only applies to inherited" do
    expect do
      Axn::Webhooks.inbound :slack do
        verify :hmac, secret: "s", signature: header("X-Sig")

        endpoint(:events) do
          dispatch to: "HandlerB"
          respond { |result| text(result.to_s) }
          static_respond { text("ok") }
        end
      end
    end.to raise_error(Axn::Webhooks::Error, /declares both/)
  end

  it "still rejects both renderers in a child even when the parent declared one of them" do
    # The round-2 fix cleared the inherited alternative but left the re-declared one marked
    # inherited, so the SECOND declaration cleared the child's OWN first one and the pair was
    # accepted — silently dropping a renderer the child explicitly asked for (Codex review).
    expect do
      Axn::Webhooks.inbound :slack do
        verify :hmac, secret: "s", signature: header("X-Sig")
        respond { |_result| text("parent") }

        endpoint(:events) do
          dispatch to: "HandlerB"
          respond { |_result| text("child") }
          static_respond { text("also child") }
        end
      end
    end.to raise_error(Axn::Webhooks::Error, /declares both/)
  end

  it "registers NOTHING when a later child fails to build" do
    # Registration is process-global; publishing children one at a time left earlier ones live
    # after a later one raised, mixing endpoints from different declarations (Codex review).
    expect do
      Axn::Webhooks.inbound :vendor do
        verify :hmac, secret: "s", signature: header("X-Sig")

        endpoint(:good) { dispatch to: "HandlerA" }
        endpoint(:bad) do
          dispatch to: "HandlerB"
          respond { |_result| text("x") }
          static_respond { text("y") }
        end
      end
    end.to raise_error(Axn::Webhooks::Error)

    expect(Axn::Webhooks::Inbound.registered).to be_empty
  end

  describe "re-declaring a vendor replaces its whole registered set" do
    # A declaration owns a SET of registry keys once nesting exists, so re-declaring has to be able
    # to REMOVE keys, not just overwrite them. Otherwise a route the new declaration doesn't define
    # stays mounted with its old verifier and handler (Codex review).
    def declare_two
      Axn::Webhooks.inbound(:slack) do
        verify :hmac, secret: "s", signature: header("X-Sig")
        endpoint(:events) { dispatch to: "HandlerA" }
        endpoint(:interactivity) { dispatch to: "HandlerB" }
      end
    end

    def declare_one
      Axn::Webhooks.inbound(:slack) do
        verify :hmac, secret: "s", signature: header("X-Sig")
        endpoint(:events) { dispatch to: "HandlerA" }
      end
    end

    def declare_plain
      Axn::Webhooks.inbound(:slack) do
        verify :hmac, secret: "s", signature: header("X-Sig")
        dispatch to: "HandlerA"
      end
    end

    it "drops a child the new declaration no longer defines" do
      declare_two
      declare_one

      expect(Axn::Webhooks::Inbound.registered).to eq([:slack_events])
    end

    it "drops every child when the vendor becomes a plain endpoint" do
      declare_two
      declare_plain

      expect(Axn::Webhooks::Inbound.registered).to eq([:slack])
    end

    it "never deletes a key another declaration has since taken over" do
      # Replacement reclaims only what this declaration STILL owns. Otherwise reloading :slack
      # deleted a live :slack_events route belonging to an unrelated plain declaration — a failure
      # created by the ownership bookkeeping itself, since before it nothing was ever deleted
      # (Codex review).
      Axn::Webhooks.inbound(:slack) do
        verify :hmac, secret: "nested", signature: header("X-Sig")
        endpoint(:events) { dispatch to: "HandlerA" }
      end

      allow(Axn.config.logger).to receive(:warn) # takeover warning, asserted separately below
      Axn::Webhooks.inbound(:slack_events) do
        verify :hmac, secret: "plain", signature: header("X-Sig")
        dispatch to: "HandlerB"
      end

      Axn::Webhooks.inbound(:slack) do
        verify :hmac, secret: "nested", signature: header("X-Sig")
        endpoint(:other) { dispatch to: "HandlerC" }
      end

      expect(Axn::Webhooks::Inbound.registered).to contain_exactly(:slack_events, :slack_other)

      body = "{}"
      sig = Axn::Webhooks::Signature.compute(secret: "plain", payload: body)
      request = Axn::Webhooks::Request.new(raw_body: body, headers: { "X-Sig" => sig })
      expect(Axn::Webhooks::Inbound[:slack_events].verify(request)).to be_ok # still the PLAIN one
    end

    it "warns when one declaration takes over a name another already registered" do
      Axn::Webhooks.inbound(:slack) do
        verify :hmac, secret: "s", signature: header("X-Sig")
        endpoint(:events) { dispatch to: "HandlerA" }
      end

      expect(Axn.config.logger).to receive(:warn).with(/slack_events.*two declarations/m)

      Axn::Webhooks.inbound(:slack_events) do
        verify :hmac, secret: "s", signature: header("X-Sig")
        dispatch to: "HandlerB"
      end
    end

    it "drops the plain endpoint when the vendor gains children" do
      declare_plain
      declare_two

      expect(Axn::Webhooks::Inbound.registered).to contain_exactly(:slack_events, :slack_interactivity)
    end
  end

  it "rejects a bare `respond` rather than silently un-declaring the inherited renderer" do
    # Without a block, the override logic cleared the inherited alternative and then stored nil —
    # booting an endpoint with NO renderer. That is both an undocumented way to un-declare a
    # parent's renderer (the README says there isn't one) and a typo that silently downgrades
    # responses to bare acks (Codex review).
    expect do
      Axn::Webhooks.inbound :slack do
        verify :hmac, secret: "s", signature: header("X-Sig")
        static_respond { text("parent") }

        endpoint(:events) do
          dispatch to: "HandlerB"
          respond
        end
      end
    end.to raise_error(Axn::Webhooks::Error, /`respond` requires a block/)
  end

  it "rejects a bare `static_respond` the same way" do
    expect do
      Axn::Webhooks.inbound :slack do
        verify :hmac, secret: "s", signature: header("X-Sig")
        respond { |_result| text("parent") }

        endpoint(:events) do
          dispatch to: "HandlerB"
          static_respond
        end
      end
    end.to raise_error(Axn::Webhooks::Error, /`static_respond` requires a block/)
  end

  it "rejects a bare renderer on a plain, unnested endpoint too" do
    expect do
      Axn::Webhooks.inbound :vendor do
        verify :hmac, secret: "s", signature: header("X-Sig")
        dispatch to: "HandlerA"
        respond
      end
    end.to raise_error(Axn::Webhooks::Error, /`respond` requires a block/)
  end

  it "rejects a parent that both declares endpoints and dispatches itself" do
    expect do
      Axn::Webhooks.inbound :slack do
        verify :hmac, secret: "s", signature: header("X-Sig")
        dispatch to: "HandlerA"

        endpoint(:events) { dispatch to: "HandlerB" }
      end
    end.to raise_error(ArgumentError, /registers nothing itself/)
  end

  it "rejects an endpoint nested inside an endpoint" do
    expect do
      Axn::Webhooks.inbound :slack do
        verify :hmac, secret: "s", signature: header("X-Sig")

        endpoint(:events) do
          dispatch to: "HandlerB"
          endpoint(:deeper) { dispatch to: "HandlerC" }
        end
      end
    end.to raise_error(ArgumentError, /cannot be nested/)
  end

  it "rejects a duplicate child name" do
    expect do
      Axn::Webhooks.inbound :slack do
        verify :hmac, secret: "s", signature: header("X-Sig")

        endpoint(:events) { dispatch to: "HandlerB" }
        endpoint(:events) { dispatch to: "HandlerC" }
      end
    end.to raise_error(ArgumentError, /duplicate/)
  end

  it "requires a block" do
    expect do
      Axn::Webhooks.inbound(:slack) { endpoint(:events) }
    end.to raise_error(ArgumentError, /requires a block/)
  end

  it "still runs each child through the existing per-endpoint validation" do
    # `verify` is required whenever `dispatch` is declared -- that check lives in __verifier__ and
    # must run per child, not once for the parent.
    expect do
      Axn::Webhooks.inbound :slack do
        endpoint(:events) { dispatch to: "HandlerB" }
      end
    end.to raise_error(Axn::Webhooks::Error, /must declare `verify`/)
  end

  it "leaves a plain (unnested) inbound block registering exactly as before" do
    Axn::Webhooks.inbound :codat do
      verify :hmac, secret: "s", signature: header("X-Sig")
      dispatch to: "HandlerA"
    end

    expect(Axn::Webhooks::Inbound.registered).to eq([:codat])
  end
end
