# frozen_string_literal: true

require_relative "boot"

require "rails/all"

# Require the gems listed in the Gemfile, including the gem under test — which loads its own axn
# dependency and any Railtie/Engine it defines before the app boots.
Bundler.require(*Rails.groups)

module DummyApp
  class Application < Rails::Application
    config.load_defaults 7.0

    # Minimal API-only app — no views/helpers/session middleware; enough to boot Rails + ActiveRecord.
    config.api_only = true
    config.eager_load = false

    # api_only drops Rack::MethodOverride, which a standard (non-API) Rails app runs by default —
    # and it is load-bearing here: it calls Rack::Request#POST to look for `_method`, which under
    # Rack 3 consumes rack.input WITHOUT rewinding for form-urlencoded bodies. Without it in the
    # stack this app can't reproduce how a real host mangles a Twilio/Slack form POST, which is
    # exactly the regression the form-body specs in webhook_mount_spec.rb exist to pin.
    config.middleware.use Rack::MethodOverride
  end
end
