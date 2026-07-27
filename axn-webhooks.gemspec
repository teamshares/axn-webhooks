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

  # Ship the runtime payload only — allowlist, not denylist. A gem's shippable surface is small and
  # stable (lib/ + a few root docs), so enumerating it beats an ever-growing exclude list that
  # silently leaks new dev artifacts into the package. `git ls-files` keeps this to tracked files.
  # Anything not listed (bin/, spec*, docs/, internal-docs/, lefthook.yml, …) simply never ships;
  # add a token here only when you add a genuinely new shippable path (e.g. exe/ for a CLI).
  # AGENTS-consuming.md ships if you write one (agent-facing usage guide, read via `bundle show`);
  # `git ls-files` just omits it when absent, so it's a harmless no-op until then.
  spec.files = IO.popen(
    %w[git ls-files -z -- lib README.md CHANGELOG.md LICENSE.txt AGENTS-consuming.md],
    chdir: __dir__, err: IO::NULL,
  ) { |ls| ls.readlines("\x0", chomp: true) }
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "axn", ">= 0.1.0-alpha.4.3", "< 0.2.0"
  # Requires Rack 3: Response's headers are lowercased per Rack 3's SPEC, and Rack 3's native
  # Array multi-value headers are used. Consumers need Rails 7.1+ (the first Rails whose
  # actionpack allows Rack 3); Rails 7.0 is Rack-2-only and intentionally unsupported.
  spec.add_dependency "rack", ">= 3.0", "< 4"
end
