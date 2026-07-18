# AGENTS.md

Guidance for agents working on **axn-webhooks**, an [axn](https://github.com/teamshares/axn)-consuming gem.

## Axn

Before writing or modifying an Axn action (`include Axn`): run `bundle show axn` and read
`AGENTS-consuming.md` there — the `expects`/`exposes`/`call` contract, failure surfaces
(`fail!`/`fails_on`/unhandled exception, `standalone:`/`join:`), and gotchas.

## Rules

- TDD: failing test first.
- Works outside Rails — guard `Rails`/`ActiveRecord`/`ActiveJob` references with `defined?(...)`.
- `bundle exec rake` (specs + rubocop) before done.
- `axn` is pinned to `branch: "main"` in the Gemfile; `Gemfile.lock` is gitignored and CI resolves
  fresh. Re-run tests after `bundle update axn` if it may have moved.

## Changes & compatibility

- CHANGELOG every user-visible change under `## [Unreleased]`.

## Docs & planning artifacts

Brainstorming specs and implementation plans — including anything the `superpowers` skills generate —
go in `internal-docs/specs/` and `internal-docs/plans/`. (This is the location preference the
`writing-plans` / `brainstorming` skills defer to.) `docs/` is **reserved for a future user-facing
VitePress site** (as in [teamshares/axn](https://github.com/teamshares/axn)); don't put internal notes
there.
