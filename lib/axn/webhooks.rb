# frozen_string_literal: true

require "axn"
require "active_support/deprecation"

require_relative "webhooks/version"

module Axn
  module Webhooks
    extend Axn::Configurable

    # Per-gem config namespace (Axn::Configurable, PRO-2880), so settings declared here don't
    # collide with another adapter configured on the same action.
    config_namespace :webhooks

    class Error < StandardError; end

    # A dedicated deprecator instance, so a consuming Rails app can register it
    # (Rails.application.deprecators[:webhooks] = Axn::Webhooks.deprecator) and govern
    # its behavior (silence in test, raise in CI, etc.).
    def self.deprecator
      @deprecator ||= ActiveSupport::Deprecation.new("1.0", "axn-webhooks")
    end
  end
end
