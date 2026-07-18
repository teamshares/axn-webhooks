# frozen_string_literal: true

RSpec.describe "Axn::Webhooks vendor_facet" do
  after { Axn::Webhooks.reset_config! }

  it "defaults to false" do
    expect(Axn::Webhooks.config.vendor_facet).to eq(false)
  end

  it "rejects an unknown value" do
    expect { Axn::Webhooks.configure { |c| c.vendor_facet = :bogus } }.to raise_error(ArgumentError)
  end

  %i[dimension tag].each do |value|
    it "accepts #{value.inspect}" do
      expect { Axn::Webhooks.configure { |c| c.vendor_facet = value } }.not_to raise_error
    end
  end

  describe "Verify (representative pipeline axn — Dispatch/Respond/Challenge share the mixin)" do
    def verified_result(vendor:)
      Axn::Webhooks::Verify.call(
        request: Axn::Webhooks::Request.new(raw_body: "{}"),
        verifier: ->(_req) { true },
        vendor:,
      )
    end

    it "declares both a :vendor dimension and a :vendor tag unconditionally" do
      expect(Axn::Webhooks::Verify._dimensions.keys).to include(:vendor)
      expect(Axn::Webhooks::Verify._tags.keys).to include(:vendor)
    end

    it "stamps :vendor as a dimension, not a tag, when vendor_facet: :dimension" do
      Axn::Webhooks.configure { |c| c.vendor_facet = :dimension }
      events = []
      callback = ->(*, payload) { events << payload }
      ActiveSupport::Notifications.subscribed(callback, "axn.call") { verified_result(vendor: :codat) }
      payload = events.find { |e| e[:action].instance_of?(Axn::Webhooks::Verify) }
      expect(payload[:dimensions]).to eq(vendor: "codat")
      expect(payload[:tags]).to be_nil.or eq({})
    end

    it "stamps :vendor as a tag, not a dimension, when vendor_facet: :tag" do
      Axn::Webhooks.configure { |c| c.vendor_facet = :tag }
      events = []
      callback = ->(*, payload) { events << payload }
      ActiveSupport::Notifications.subscribed(callback, "axn.call") { verified_result(vendor: :codat) }
      payload = events.find { |e| e[:action].instance_of?(Axn::Webhooks::Verify) }
      expect(payload[:tags]).to eq(vendor: "codat")
      expect(payload[:dimensions]).to be_nil.or eq({})
    end

    it "stamps neither facet when vendor_facet: false (the default)" do
      events = []
      callback = ->(*, payload) { events << payload }
      ActiveSupport::Notifications.subscribed(callback, "axn.call") { verified_result(vendor: :codat) }
      payload = events.find { |e| e[:action].instance_of?(Axn::Webhooks::Verify) }
      expect(payload[:dimensions]).to be_nil.or eq({})
      expect(payload[:tags]).to be_nil.or eq({})
    end

    it "works with vendor: nil (a direct call outside an Endpoint) and stamps nothing" do
      Axn::Webhooks.configure { |c| c.vendor_facet = :dimension }
      expect { verified_result(vendor: nil) }.not_to raise_error
    end
  end

  describe "Endpoint threading vendor: through the pipeline" do
    after { Axn::Webhooks::Inbound.reset! }

    it "passes the registered endpoint name as vendor: into Verify" do
      Axn::Webhooks.configure { |c| c.vendor_facet = :dimension }
      Axn::Webhooks.inbound(:codat) { verify { |_req| true } }
      events = []
      callback = ->(*, payload) { events << payload }
      ActiveSupport::Notifications.subscribed(callback, "axn.call") do
        Axn::Webhooks::Inbound[:codat].verify(Axn::Webhooks::Request.new(raw_body: "{}"))
      end
      payload = events.find { |e| e[:action].instance_of?(Axn::Webhooks::Verify) }
      expect(payload[:dimensions]).to eq(vendor: "codat")
    end
  end
end
