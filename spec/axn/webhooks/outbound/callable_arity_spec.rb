# frozen_string_literal: true

RSpec.describe Axn::Webhooks::Outbound::CallableArity do
  describe ".accepted_keywords" do
    it "lists required keyword params" do
      callable = ->(id:, timestamp:, body:) { [id, timestamp, body] }
      expect(described_class.accepted_keywords(callable)).to contain_exactly(:id, :timestamp, :body)
    end

    it "lists optional keyword params alongside required ones" do
      callable = ->(id:, timestamp: nil) { [id, timestamp] }
      expect(described_class.accepted_keywords(callable)).to contain_exactly(:id, :timestamp)
    end

    it "returns :all for a callable that double-splats (accepts any keyword)" do
      callable = ->(id:, **) { id }
      expect(described_class.accepted_keywords(callable)).to eq(:all)
    end

    it "ignores positional params entirely" do
      callable = ->(pos, id:) { [pos, id] }
      expect(described_class.accepted_keywords(callable)).to contain_exactly(:id)
    end

    it "returns an empty Array for a callable that accepts no keywords at all" do
      callable = -> {}
      expect(described_class.accepted_keywords(callable)).to eq([])
    end

    it "works via #parameters on a plain callable OBJECT, not just a Proc/lambda" do
      obj = Class.new { def call(id:, body:) = [id, body] }.new
      expect(described_class.accepted_keywords(obj)).to contain_exactly(:id, :body)
    end
  end

  # Codex P2 finding (config.rb's subscribers/to: resolver dispatch, pre-dating PRO-3214): the
  # ORIGINAL bare `callable.arity.zero?` rule must survive exactly, just made safe for a plain
  # callable object with no #arity of its own (falls back to Method#arity via #call).
  describe ".zero_arity?" do
    it "is true for a truly empty signature" do
      expect(described_class.zero_arity?(-> {})).to be(true)
    end

    it "is false for a lambda with a required positional (arity 1)" do
      expect(described_class.zero_arity?(->(event) { event })).to be(false)
    end

    it "is false for a lambda with an OPTIONAL positional (arity -1, not 0)" do
      # This is the crux of the resolver-preservation finding: a lambda's optional/default param
      # makes arity NEGATIVE, not zero -- so the ORIGINAL dispatch already passed the event to it,
      # and that must not change.
      expect(described_class.zero_arity?(->(event = nil) { event })).to be(false)
    end

    it "is true for a Proc (non-lambda) with an optional positional -- arity is 0, a Ruby quirk" do
      expect(described_class.zero_arity?(proc { |event = :all| event })).to be(true)
    end

    it "is false for a Proc (non-lambda) with a positional and NO default -- arity is 1" do
      expect(described_class.zero_arity?(proc { |event| event })).to be(false)
    end

    it "works via Method#arity on a plain callable OBJECT with no #arity of its own" do
      obj = Class.new { def call(event) = event }.new
      expect(described_class.zero_arity?(obj)).to be(false)
    end
  end

  # Codex P1 finding (signer.rb's per-subscriber secret / Deliver's headers resolver, both new in
  # PRO-3214): must prefer a zero-arg call whenever genuinely possible (an explicit default or
  # rest param), but NOT be fooled by Ruby's Proc-specific #parameters quirk -- a plain
  # `proc { |subscriber| ... }` (no default) reports its param as `:opt` (same label a REAL
  # default gets), so a `#parameters`-based check can't tell them apart; raw arity can (a
  # no-default proc's arity is still the correct positive 1).
  describe ".prefers_zero_args?" do
    it "is true for a truly empty signature" do
      expect(described_class.prefers_zero_args?(-> {})).to be(true)
    end

    it "is true for a lambda with an optional positional (a genuine default)" do
      expect(described_class.prefers_zero_args?(->(x = 1) { x })).to be(true)
    end

    it "is true for a splat-only lambda" do
      expect(described_class.prefers_zero_args?(->(*x) { x })).to be(true)
    end

    it "is false for a lambda with a required positional (arity 1)" do
      expect(described_class.prefers_zero_args?(->(x) { x })).to be(false)
    end

    it "is false for a Proc (non-lambda) with a positional and NO default, despite #parameters labeling it :opt" do
      expect(described_class.prefers_zero_args?(proc { |x| x })).to be(false)
    end

    it "is true for a Proc (non-lambda) with a genuine default (arity 0)" do
      expect(described_class.prefers_zero_args?(proc { |x = 1| x })).to be(true)
    end

    it "works via Method#arity on a plain callable OBJECT with a required arg" do
      obj = Class.new { def call(val) = val }.new
      expect(described_class.prefers_zero_args?(obj)).to be(false)
    end

    it "works via Method#arity on a plain callable OBJECT with an optional arg" do
      obj = Class.new { def call(val = 1) = val }.new
      expect(described_class.prefers_zero_args?(obj)).to be(true)
    end
  end

  describe ".accepts_positional?" do
    it "is true for a single required positional param" do
      expect(described_class.accepts_positional?(->(x) { x })).to be(true)
    end

    it "is true for a single optional positional param" do
      expect(described_class.accepts_positional?(proc { |x = 1| x })).to be(true)
    end

    it "is true for a splat" do
      expect(described_class.accepts_positional?(->(*x) { x })).to be(true)
    end

    it "is false for a purely keyword signature" do
      expect(described_class.accepts_positional?(->(id:) { id })).to be(false)
    end

    it "is false for a truly empty signature" do
      expect(described_class.accepts_positional?(-> {})).to be(false)
    end
  end
end
