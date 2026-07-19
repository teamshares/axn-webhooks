# frozen_string_literal: true

require "axn"
require "active_support/deprecation"

require_relative "webhooks/errors"
require_relative "webhooks/version"
require_relative "webhooks/request"
require_relative "webhooks/response"
require_relative "webhooks/signature"
require_relative "webhooks/resolvers"
require_relative "webhooks/vendor_facet"
require_relative "webhooks/verify"
require_relative "webhooks/verifiers"
require_relative "webhooks/verifiers/hmac"
require_relative "webhooks/verifiers/standard_webhooks"
require_relative "webhooks/inbound"
require_relative "webhooks/inbound/challenge"
require_relative "webhooks/inbound/parsers"
require_relative "webhooks/inbound/build_request"
require_relative "webhooks/inbound/respond_context"
require_relative "webhooks/respond"
require_relative "webhooks/dispatch"
require_relative "webhooks/outbound"

module Axn
  module Webhooks
    extend Axn::Configurable

    # Per-gem config namespace (Axn::Configurable, PRO-2880), so settings declared here don't
    # collide with another adapter configured on the same action.
    config_namespace :webhooks

    # Per-vendor observability facet (spec Decision 7 / PRO-2818). Off by default; a consuming app
    # (Teamshares: :dimension) opts in. See Axn::Webhooks::VendorFacet for the runtime mechanism.
    setting :vendor_facet, default: false, one_of: [false, :dimension, :tag]

    # A dedicated deprecator instance, so a consuming Rails app can register it
    # (Rails.application.deprecators[:webhooks] = Axn::Webhooks.deprecator) and govern
    # its behavior (silence in test, raise in CI, etc.).
    def self.deprecator
      @deprecator ||= ActiveSupport::Deprecation.new("1.0", "axn-webhooks")
    end
  end
end
