# Removing Cucumber from a Rails app

This is a **standalone, human-triggered** guide. A human runs it *after* the Cucumber→RSpec migration is complete and reviewed, when they're ready to delete Cucumber for good. It is **not** part of the automated migration process.

## Preflight checks

Before touching anything, confirm with the human:

- **The migration is complete** — every scenario migrated, not just spot-checked. Look at `tmp/mandoline/needs-attention.md` for skipped/unverified scenarios, and check that no `.feature` is still missing its migration-marker comment. If unmigrated coverage remains, deleting `features/` silently drops it — stop and surface this instead of purging. Features deliberately left unmigrated (e.g. stubs symlinked many times, see `app-migration-guide.md`) are expected to have no marker.
- **They have reviewed the migrated RSpec specs** (at least a cursory comparison of some `.feature` files against their migrated specs).
- **They have pushed and CI is green** on the migrated suite — proof the RSpec feature specs stand on their own.
- **Whether we may run `bundle install` autonomously** this session (to regenerate `Gemfile.lock`), or they want to run it themselves.
- **They're ready to kill Cucumber for good** in this repo.

## Purging process

Purge the repo of every trace of the Cucumber test suite. This covers at least the following — work through all of it, then verify.

### Gems

In the `Gemfile`, remove the gems used **only** by Cucumber, not by RSpec. They're usually in `group :test` (sometimes `:development`, or a dedicated `:cucumber` group).

Typical Cucumber-only gems (**scan for more** — anything that depends on `cucumber` / `cucumber-rails` / `gherkin` in `Gemfile.lock`):

- `cucumber`
- `cucumber-rails`
- `spreewald`
- `cucumber_factory`
- `cucumber_priority`
- `spring-commands-cucumber`
- `mail` — **only if** it's pinned explicitly as a Spreewald mail-parsing workaround (check the surrounding comment / `git blame`); leave it if the app depends on it directly.

**Do NOT remove gems the RSpec feature specs now rely on**, even though Cucumber used them too:

- `capybara`, `selenium-webdriver` (and any `webdrivers`/driver gem) — they drive the browser for feature specs.
- `factory_bot` / `factory_bot_rails` — these *replace* `cucumber_factory`; the migrated specs depend on them.
- `database_cleaner`, `webmock`, `vcr`, `launchy`, `site_prism`, and similar shared test infrastructure.

When in doubt, grep `spec/` for the gem before removing it.

After editing the `Gemfile`, run `bundle install` (if permitted) so `Gemfile.lock` is regenerated without the removed gems, and commit the updated lockfile.

### The `features/` folder

Remove the entire `features/` folder — scenarios, step definitions, and `features/support/`.

**But first, grep the whole repo for paths under `features/` — it is not always Cucumber-only.** Fixture directories such as `features/assets/` are routinely referenced from *outside* the Cucumber suite: pre-existing `spec/views/**`, `spec/models/**`, `lib/`, even app code pointing at a sample file. Deleting the folder then breaks specs that have nothing to do with the migration (`Capybara::FileNotFound`, `Errno::ENOENT`), and the failure looks unrelated to what you just did. So run `grep -rn 'features/' --include='*.rb' --include='*.yml' spec/ lib/ app/ config/` before deleting, move any genuinely shared fixtures to `spec/fixtures/files/`, and repoint their callers **in the same commit as the deletion** — not after CI goes red.

### `cucumber.yml`

Delete the Cucumber profiles config. It lives at `config/cucumber.yml` (most makandra apps) or repo-root `cucumber.yml`.

### The `cucumber` binstub and rake tasks

- Delete `bin/cucumber` **and a legacy `script/cucumber`** if present — stale binstubs left behind once `spring-commands-cucumber` is gone.
- Remove any Cucumber rake task: a custom `lib/tasks/cucumber.rake`, or a `require 'cucumber/rake/task'` in the `Rakefile`. (The `rake cucumber` task that `cucumber-rails` provides disappears with the gem.)

### The dedicated `cucumber` Rails environment (if one exists)

Some apps run Cucumber under its own `cucumber` environment. If so, delete:

- `config/environments/cucumber.rb`
- the `cucumber:` entry in `config/database.yml` **and** in `config/database.sample.yml` (if present)

Then grep the codebase for any remaining `cucumber`-environment references and adjust them, e.g.:

```ruby
if Rails.env.in?(['test', 'cucumber'])
  # do something in tests
end
```

becomes `if Rails.env.test?` — the settings the `cucumber` env needed were folded into `test.rb` during the migration. Also check tooling for lingering `RAILS_ENV=cucumber`.

### CI configuration

The migration already switched CI's E2E job to run the RSpec feature specs, so CI should be green. Still, verify that no Cucumber references linger in `.gitlab-ci.yml` / `.github/workflows/*.yml`:

- any remaining `bundle exec cucumber` invocation or a dedicated `cucumber` job;
- a downstream job whose `needs:` / `dependencies:` still lists a now-deleted `cucumber` job — **a `needs:` pointing at a missing job is a pipeline-config error that fails the whole pipeline before any test runs**, so remove it from every such list.

### Other leftovers

- `knapsack_cucumber_report.json` at the repo root — obsolete (the RSpec knapsack report stays).
- **Agent/developer instruction files** — `README`, `CLAUDE.md`, `AGENTS.md` — mentioning `bundle exec cucumber`, `features/` paths, or a `rake tests` alias that ran Cucumber; update them to the RSpec equivalents.
- **`.gitignore` entries** such as `rerun.txt` or `tmp/cucumber`, and **`.prettierignore` / other tool-ignore entries** naming `config/cucumber.yml` or `features/`.
- **Empty factories that existed only so `cucumber_factory` could resolve a phrase** (e.g. an attribute-less `factory :featured_movie`) — if nothing under `spec/` uses them, drop them.
- **Migrated support comments that describe behaviour "as Spreewald did"** — reword so they stand alone; the reader no longer has Spreewald to compare against.
- Editor config and git hooks (lefthook/overcommit) referencing cucumber.
- **Cucumber *constants and config*, not just paths — grep for references, not only `features/`.** A path-based grep misses: a `defined?(Cucumber::Rails)` guard in app code (e.g. an `ApplicationController#integration_test?` that's now dead); a `config/initializers/*` patch (a global `Kernel#at_exit` exit-code fix loaded in *every* environment); `.rubocop.yml` excludes for `features/**`; a `Guardfile` watching `features`; CI/docker wrapper scripts (a test-watcher script, a smoke-test); `CONTRIBUTING.md`. Grep the repo for `Cucumber`, `cucumber`, `Spreewald` and adjust each hit.
- **A cucumber wrapper script may carry *non*-Cucumber functionality** that must be preserved (e.g. a dev-only port-forward); move that part to the RSpec wrapper rather than deleting it with the script.

## Verify success

If the app uses Spring (you removed `spring-commands-cucumber`, so it likely does), first clear any resident Spring so a stale process can't mask breakage: run `spring stop` (more on killing Spring: <https://makandracards.com/makandra/495838-rails-kill-spring-fire>). If the app has no Spring, skip this — the `DISABLE_SPRING=1` below is then a harmless no-op.

Then run a **few** feature specs — with `DISABLE_SPRING=1` — to make sure nothing broke (in particular, that you didn't remove a gem RSpec also uses):

```bash
DISABLE_SPRING=1 bundle exec rspec spec/features/<some>_spec.rb spec/features/<another>_spec.rb
```

If you run into issues, fix them autonomously without asking for permission.

**Do *not* run the entire test suite** — that's what CI is for.

**Run RuboCop over the non-Ruby files you touched, too** (`Guardfile`, `Gemfile`, …). Deleting a trailing block from one of them leaves `Layout/TrailingEmptyLines`, which fails CI — and `rubocop -A` over `.rb` files won't have covered them.

## Report success

When you're done, make a report of what you changed and present it to the human.

Tell the human they should push the Cucumber removal and watch CI for failures, just in case.

Keep this removal as its **own commit/MR**, separate from the migration, and say so in the MR description — because `features/` is deleted only here, a reviewer can still compare each migrated spec against its original `.feature` at the commit *before* this one.

Offer to make the commit and push, but **ask for permission** — some humans want to review and commit manually.
