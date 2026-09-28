# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in axn-webhooks.gemspec
gemspec

gem "lefthook", "~> 2.0" # Git-hook manager (pre-commit RuboCop on staged files)
gem "rake", "~> 13.0"
gem "rspec", "~> 3.0"
gem "rubocop", "~> 1.21"

# TEMP (PRO-3566): Axn::Extensions::Auth is on axn main but unreleased. Before cutting a version of
# this gem: raise the gemspec axn floor to the release that ships it (alpha 7) and drop this pin.
gem "axn", git: "https://github.com/teamshares/axn", branch: "main"
