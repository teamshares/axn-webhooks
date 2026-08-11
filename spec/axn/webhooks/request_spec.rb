# frozen_string_literal: true

require "pp"

RSpec.describe Axn::Webhooks::Request do
  subject(:request) do
    described_class.new(
      raw_body: '{"a":1}',
      headers: { "Content-Type" => "application/json", "X-Merge-Webhook-Signature" => "abc" },
      params: { "challenge" => "xyz" },
      url: "https://example.com/webhooks/merge",
      http_method: "post",
    )
  end

  it "exposes the raw body verbatim" do
    expect(request.raw_body).to eq('{"a":1}')
  end

  it "looks up headers case-insensitively" do
    expect(request.header("x-merge-webhook-signature")).to eq("abc")
    expect(request.header("X-MERGE-WEBHOOK-SIGNATURE")).to eq("abc")
    expect(request.header("Content-Type")).to eq("application/json")
  end

  it "returns nil for an unknown header" do
    expect(request.header("X-Absent")).to be_nil
  end

  it "exposes params, url, and an upcased http_method" do
    expect(request.params).to eq("challenge" => "xyz")
    expect(request.url).to eq("https://example.com/webhooks/merge")
    expect(request.http_method).to eq("POST")
  end

  it "defaults params to empty and http_method to POST" do
    bare = described_class.new(raw_body: "")
    expect(bare.params).to eq({})
    expect(bare.http_method).to eq("POST")
    expect(bare.header("anything")).to be_nil
  end

  it "does not let callers mutate internal params" do
    expect { request.params["injected"] = true }.to raise_error(FrozenError)
  end

  it "handles nil headers without raising" do
    expect(described_class.new(raw_body: "x", headers: nil).header("anything")).to be_nil
  end

  it "exposes raw_body frozen to prevent accidental mutation" do
    expect(request.raw_body).to be_frozen
    expect { request.raw_body << "!" }.to raise_error(FrozenError)
  end

  describe "#inspect" do
    # PRO-3091: Request#inspect (Object's default) rendered raw_body and headers in full, so every
    # log line / exception report that inspects a Request — not just this pipeline's own log
    # lines — leaked attacker-controlled webhook payloads (bank account numbers, API credentials,
    # mailing addresses) into production logs. This is the durable fix: redact at the source.
    it "never renders raw_body or header values" do
      expect(request.inspect).not_to include('{"a":1}')
      expect(request.inspect).not_to include("abc")
    end

    it "still identifies the request (method, url, body size)" do
      expect(request.inspect).to include("POST", "https://example.com/webhooks/merge", "7")
    end
  end

  describe "#pretty_print" do
    # `pp`/PP does NOT go through #inspect by default — it walks instance variables directly via
    # Kernel#pretty_print — so redacting #inspect alone leaves `pp request` (and anything that
    # calls it, e.g. some exception reporters) leaking the same fields.
    it "never renders raw_body or header values" do
      io = StringIO.new
      PP.pp(request, io)
      expect(io.string).not_to include('{"a":1}')
      expect(io.string).not_to include("abc")
    end
  end

  describe ".from_rack" do
    def rack_env(**overrides)
      {
        "REQUEST_METHOD" => "POST",
        "PATH_INFO" => "/webhooks/codat",
        "QUERY_STRING" => "",
        "rack.input" => StringIO.new('{"a":1}'),
        "rack.url_scheme" => "https",
        "SERVER_NAME" => "example.com",
        "HTTP_HOST" => "example.com",
        "CONTENT_TYPE" => "application/json",
        "CONTENT_LENGTH" => "7",
        "HTTP_X_SIG" => "abc123",
      }.merge(overrides)
    end

    it "extracts the raw body verbatim from rack.input" do
      request = described_class.from_rack(rack_env)
      expect(request.raw_body).to eq('{"a":1}')
    end

    it "rewinds rack.input after reading, so downstream middleware can still read it" do
      env = rack_env
      described_class.from_rack(env)
      expect(env["rack.input"].read).to eq('{"a":1}')
    end

    it "maps HTTP_* env keys to header names, case-insensitively readable" do
      request = described_class.from_rack(rack_env)
      expect(request.header("X-Sig")).to eq("abc123")
    end

    it "maps CONTENT_TYPE and CONTENT_LENGTH to headers (not HTTP_*-prefixed in Rack)" do
      request = described_class.from_rack(rack_env)
      expect(request.header("Content-Type")).to eq("application/json")
      expect(request.header("Content-Length")).to eq("7")
    end

    it "extracts query-string params" do
      request = described_class.from_rack(rack_env("QUERY_STRING" => "challenge=xyz&a=1"))
      expect(request.params).to eq("challenge" => "xyz", "a" => "1")
    end

    it "sets params to the form body fields only, NOT merged with the query (Twilio's form body)" do
      # Rack::Request#url (used for `url`) already includes the query string. If `params` also
      # merged the query in, a URL-signing verifier doing `validate(req.url, req.params, sig)`
      # would double-count query params — once via url, once via params — and reject a validly
      # signed callback. So for a form POST, params must be form fields only; the query is still
      # reachable via `url`.
      body = "From=%2B15551234567&To=%2B15557654321"
      env = rack_env(
        "rack.input" => StringIO.new(body),
        "CONTENT_TYPE" => "application/x-www-form-urlencoded",
        "QUERY_STRING" => "extra=1",
      )
      request = described_class.from_rack(env)
      expect(request.params).to eq("From" => "+15551234567", "To" => "+15557654321")
      expect(request.url).to end_with("?extra=1") # query still reachable via url, not double-counted in params
      expect(request.raw_body).to eq(body) # verify still sees the untouched raw bytes
    end

    it "does not attempt to parse a non-form body as params, falling back to the query string" do
      request = described_class.from_rack(rack_env("QUERY_STRING" => "challenge=xyz")) # application/json body
      expect(request.params).to eq("challenge" => "xyz")
    end

    it "builds the full url including scheme, host, path, and query string" do
      request = described_class.from_rack(rack_env("QUERY_STRING" => "a=1"))
      expect(request.url).to eq("https://example.com/webhooks/codat?a=1")
    end

    it "omits the query string from url when there is none" do
      request = described_class.from_rack(rack_env)
      expect(request.url).to eq("https://example.com/webhooks/codat")
    end

    it "preserves the SCRIPT_NAME mount prefix in url (Rack mount / Rails `mount ... at:`)" do
      # When mounted (e.g. `mount Inbound[:vendor], at: "/webhooks/codat"`), Rack puts the mount
      # prefix in SCRIPT_NAME and leaves only the remainder in PATH_INFO. A URL built from
      # PATH_INFO alone would drop the prefix, breaking URL-based verifiers like Twilio's.
      request = described_class.from_rack(rack_env("SCRIPT_NAME" => "/webhooks/codat", "PATH_INFO" => "/rest"))
      expect(request.url).to eq("https://example.com/webhooks/codat/rest")
    end

    it "reads the HTTP method" do
      request = described_class.from_rack(rack_env("REQUEST_METHOD" => "GET"))
      expect(request.http_method).to eq("GET")
    end

    it "tolerates a non-rewindable rack.input instead of raising (bare Rack::Builder / streaming server)" do
      # A Rack 3 stack without Rack::RewindableInput::Middleware in front may hand us an input
      # that's readable but NOT rewindable. We've already captured the full body into raw_body
      # before ever touching rewind, so a non-rewindable input shouldn't turn a valid webhook
      # into a 500 — the rewind is just best-effort courtesy for downstream middleware.
      non_rewindable_input = Class.new do
        def initialize(body) = @io = StringIO.new(body)
        def read(...) = @io.read(...)
      end.new('{"a":1}')

      expect(non_rewindable_input).not_to respond_to(:rewind)

      request = nil
      expect { request = described_class.from_rack(rack_env("rack.input" => non_rewindable_input)) }.not_to raise_error
      expect(request.raw_body).to eq('{"a":1}')
    end

    it "rewinds a rack.input an upstream middleware already consumed (Rack 3 + Rack::MethodOverride)" do
      # Rack 3's Rack::Request#POST no longer rewinds after parsing a form-urlencoded body, and
      # Rails runs Rack::MethodOverride (which calls #POST) ahead of the router. So a mounted
      # endpoint receives an input positioned at EOF for every form POST — Twilio and Slack, i.e.
      # precisely the vendors whose signature is computed over params/body.
      body = "From=%2B15551234567&Body=hi"
      input = StringIO.new(body)
      input.read # simulate the upstream consumer leaving it at EOF
      expect(input.eof?).to be(true)

      request = described_class.from_rack(
        rack_env("rack.input" => input, "CONTENT_TYPE" => "application/x-www-form-urlencoded"),
      )

      expect(request.raw_body).to eq(body)
      expect(request.params).to eq("From" => "+15551234567", "Body" => "hi")
    end

    it "treats a MISSING rack.input as an empty body (Rack 3 makes it optional)" do
      # Rack 2 required rack.input on every request; Rack 3 does not, so a bodyless request may
      # omit it entirely — Rack::MockRequest.env_for (and therefore every Rails request spec) does.
      # Fetching it would 500 the bodyless GET challenge handshake that `challenge` exists to serve.
      env = rack_env("REQUEST_METHOD" => "GET", "QUERY_STRING" => "challenge=xyz")
      env.delete("rack.input")

      request = nil
      expect { request = described_class.from_rack(env) }.not_to raise_error
      expect(request.raw_body).to eq("")
      expect(request.params).to eq("challenge" => "xyz")
    end

    it "tolerates a rack.input whose #rewind responds but RAISES (non-seekable pipe/socket)" do
      # Some rack.input-like streams (e.g. a pipe or socket) DO respond_to?(:rewind) but raise
      # Errno::ESPIPE (or similar) when actually called, because the underlying descriptor isn't
      # seekable. respond_to? alone can't catch this — only rescuing the call itself does. We've
      # already captured raw_body before ever touching rewind, so this must not raise/500.
      raising_input = Class.new do
        def initialize(body) = @io = StringIO.new(body)
        def read(...) = @io.read(...)
        def rewind = raise(Errno::ESPIPE, "illegal seek")
      end.new('{"a":1}')

      request = nil
      expect { request = described_class.from_rack(rack_env("rack.input" => raising_input)) }.not_to raise_error
      expect(request.raw_body).to eq('{"a":1}')
    end

    describe "multipart/form-data bodies" do
      # PRO-3111: `extract_params` only recognized application/x-www-form-urlencoded as a form body,
      # so a multipart POST fell through to the QUERY_STRING branch and `params` came back empty.
      # Dropbox Sign posts the entire event as a single multipart `json` field and its verification
      # reads that field twice (Content-MD5 over it, then JSON.parse of it) — so every live delivery
      # 401'd. Invisible to a spec that posts the same fields urlencoded, hence these.
      let(:boundary) { "----AxnWebhooksBoundary9dK3" }

      def multipart_body(fields)
        fields.map do |name, value|
          "--#{boundary}\r\nContent-Disposition: form-data; name=\"#{name}\"\r\n\r\n#{value}\r\n"
        end.join + "--#{boundary}--\r\n"
      end

      def multipart_env(body, **overrides)
        rack_env(
          "rack.input" => StringIO.new(body),
          "CONTENT_TYPE" => "multipart/form-data; boundary=#{boundary}",
          "CONTENT_LENGTH" => body.bytesize.to_s,
          **overrides,
        )
      end

      it "exposes the form fields on params (Dropbox Sign's single `json` field)" do
        body = multipart_body("json" => '{"a":1}')
        request = described_class.from_rack(multipart_env(body))

        expect(request.params).to eq("json" => '{"a":1}')
        expect(request.raw_body).to eq(body) # verify still sees the untouched raw bytes
      end

      it "sets params to the form fields only, NOT merged with the query" do
        # Same invariant as the urlencoded branch: `url` already carries the query string, so
        # merging it into params would double-count it for URL-signing verifiers.
        body = multipart_body("json" => '{"a":1}')
        request = described_class.from_rack(multipart_env(body, "QUERY_STRING" => "extra=1"))

        expect(request.params).to eq("json" => '{"a":1}')
        expect(request.url).to end_with("?extra=1")
      end

      it "leaves rack.input rewound for downstream middleware" do
        # Rack::Request#POST reads rack.input to parse the body; leaving it at EOF would break
        # anything downstream of the mount that reads the body again.
        body = multipart_body("json" => '{"a":1}')
        env = multipart_env(body)
        described_class.from_rack(env)
        expect(env["rack.input"].read).to eq(body)
      end

      it "yields {} for a malformed/truncated body instead of raising" do
        # A hostile *unverified* request must not be able to crash the pipeline before `verify`
        # runs — Rack's multipart parser raises (EmptyContentError and friends) on garbage.
        truncated = "--#{boundary}\r\nContent-Disposition: form-data; name=\"json\""

        request = nil
        expect { request = described_class.from_rack(multipart_env(truncated)) }.not_to raise_error
        expect(request.params).to eq({})
        expect(request.raw_body).to eq(truncated)
      end

      it "yields {} for an empty body" do
        request = described_class.from_rack(multipart_env(""))
        expect(request.params).to eq({})
      end

      it "uses QUERY_STRING for a GET with a multipart Content-Type" do
        env = multipart_env("", "REQUEST_METHOD" => "GET", "QUERY_STRING" => "challenge=xyz")
        request = described_class.from_rack(env)
        expect(request.params).to eq("challenge" => "xyz")
      end
    end

    it "uses QUERY_STRING for a GET with a form-urlencoded Content-Type and empty body (challenge regression)" do
      # GET challenge requests (Nylas/Meta-style) often carry a default
      # application/x-www-form-urlencoded Content-Type header alongside an empty body and the
      # real payload in the query string. extract_params must not parse the empty body as form
      # params for a GET/HEAD — that would silently lose the query-string challenge param.
      env = rack_env(
        "REQUEST_METHOD" => "GET",
        "rack.input" => StringIO.new(""),
        "CONTENT_TYPE" => "application/x-www-form-urlencoded",
        "QUERY_STRING" => "challenge=xyz",
      )
      request = described_class.from_rack(env)
      expect(request.params).to eq("challenge" => "xyz")
    end
  end
end
