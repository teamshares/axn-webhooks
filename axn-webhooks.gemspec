# frozen_string_literal: true

require_relative "lib/axn/webhooks/version"

Gem::Specification.new do |spec|
  spec.name = "axn-webhooks"
  spec.version = Axn::Webhooks::VERSION
  spec.authors = ["Kali Donovan"]
  spec.email = ["kali@teamshares.com"]

  spec.summary = "Axn + webhooks = 🔥"
  spec.description = "Inbound webhook handling for axn: verify signatures, dispatch to handlers, acknowledge. Rails-optional. Outbound signing coming."
  spec.homepage = "https://github.com/teamshares/axn-webhooks"
  spec.license = "MIT"

  # axn requires Ruby 3.2.1+ (Data.define, Vernier profiling).
  spec.required_ruby_version = ">= 3.2.1"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "https://github.com/teamshares/axn-webhooks/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ spec/ spec_rails internal-docs/ docs/ .git .github Gemfile Gemfile.lock .rspec_status pkg/ node_modules/ tmp/ .rspec .rubocop
                          .tool-versions package.json])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "axn", ">= 0.1.0-alpha.4.3", "< 0.2.0"
end
