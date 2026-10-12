Mandoline: Convert a Rails app from Cucumber to RSpec
=====================================================

Mandoline is a set of guides that drive a Claude Code agent to migrate a Ruby on
Rails app's end-to-end tests from **Cucumber** (with Spreewald + cucumber_factory) to
**RSpec feature specs**.

Mandoline was built at [makandra](https://makandra.com) to migrate our own apps. It follows
makandra's conventions, e.g. [Spreewald](https://github.com/makandra/spreewald),
[cucumber_factory](https://github.com/makandra/cucumber_factory),
[capybara-lockstep](https://github.com/makandra/capybara-lockstep) and our feature-spec house
style. Apps with a similar stack should work well; if yours differs, expect to adapt the guides.

Why mandoline
-------------

By hand, the Cucumber migration is weeks of rewriting thousands of prose steps back into
Ruby, which is why most of our apps still run it. Mandoline drives a Claude Code agent through
three guides written from real migrations, so that rewrite is automated:

- **Hands-off.** In automatic mode it runs start to finish with no input; by default it stops
  only for blockers.
- **House style.** The output matches how we write feature specs by hand — `feature`/`scenario`,
  `.and`-chained expectations, `let`/`before`, blank-line layout — because that style is written
  down in the guides.
- **Migrates all the support code, not only the scenarios:** Capybara/Selenium setup,
  `Before`/`After` hooks, `World` modules, helper methods, custom matchers, and the
  `paths.rb`/`selectors.rb` lookups.
- **Converts the canned steps:** Spreewald steps become Capybara calls; `cucumber_factory` prose
  (`Given there is a user with the email "…"`) becomes `create(:user, …)`.
- **Inlines trivial step definitions** rather than keeping one-line helpers.
- **Verifies each scenario** — run green and reviewed — before moving on, and flags anything
  ambiguous instead of guessing.
- **Handles legacy apps, not just modern ones.** It auto-detects the stack and, on an old
  **Rails 2 (LTS) / RSpec 1 / Cucumber 1** app, switches to a dedicated playbook that emulates
  feature specs on RSpec 1 (which has no `feature`/`scenario` or `expect` syntax). Nothing to
  configure — it picks the right approach for the app it finds.
- **Tested on several real makandra apps**, both on modern Rails and on the Rails 2 / RSpec 1 path.
- **Low-risk:** it leaves the Cucumber suite in place for side-by-side review, switches CI to
  RSpec, and — when the remote is controllable (`glab`/`gh`, see *Prerequisites*) — opens a merge
  request and drives CI to green itself; otherwise it recommends the MR so CI validates the result.

The entry point is [`app-migration-guide.md`](app-migration-guide.md); it references
[`conversion-guide.md`](conversion-guide.md) (feature-spec craft & house style),
[`spreewald-guide.md`](spreewald-guide.md) and [`cucumber_factory-guide.md`](cucumber_factory-guide.md),
and — when it needs to confirm how a step behaves — reads the **target app's own bundled gems**
(Spreewald, Capybara, …) via `bundle show`. There are no other projects to check out.

This README gets you from nothing to a running migration that **passes the guide's Phase 1
preflight checks on the first attempt**. Follow the three steps in order.


Time and cost
-------------

Mandoline migrates features **in parallel** — a pool of worker agents converts multiple features
at once. Rough wall-clock: **~2 hours for a small project**, up to **a weekend for a large one**.

It **eats a lot of tokens** (the agent reads the guides, greps the target app's code and bundled
gems, and runs specs repeatedly), so a **premium (Max) seat is required** — on a smaller plan
you'll hit usage limits mid-run.

You don't have to babysit it — the migration is **self-pacing and resumable**:

- **It rides out your 5-hour quota limit automatically.** As the window fills, the agent dials back
  how many features it converts in parallel; when the window is nearly used up it pauses, waits for
  the window to reset, and resumes on its own. So a long migration runs **unattended across many
  quota windows** — no manual restart when you hit a limit.
- **It survives interruption.** Progress is saved under `tmp/mandoline/`; after a crash — or if you
  set an optional per-session time budget and it runs out — just re-run the same launch command and
  it picks up where it left off.


Prerequisites
-------------

- **A Claude Code subscription.** Mandoline *is* a set of guides for Claude Code — there is no
  separate tool to install. You drive it from Claude Code (CLI or IDE), logged in with your
  subscription: quota pacing reads the subscription's usage window, so with an API key the agent
  can't pace itself.
- **A premium (Max) seat** (see *Time and cost* above) — a migration burns a lot of tokens, and a
  smaller plan will hit usage limits mid-run.
- **Opus with high reasoning effort.** The migration needs the strongest model; the guide's
  preflight verifies this.
- **`curl` and `jq`** on the machine you launch from — the agent uses them to read your usage
  window so it can pace itself under the 5-hour quota. Both are standard; install via your package
  manager if missing. Note that [`bin/quota.sh`](bin/quota.sh) reads your local Claude Code OAuth
  token and sends it only to Anthropic's usage endpoint (the one behind Claude Code's `/usage`).
  That endpoint is undocumented and may change; if it fails, the agent falls back to
  conservative pacing.
- **`glab` and/or `gh` (recommended).** If your remote is a GitLab (e.g. self-hosted) or GitHub
  (`github.com`) host, install and authenticate the matching CLI — `glab auth login` / `gh auth login` —
  *before* launching. The agent then finishes the job end-to-end: it opens the merge/pull request and
  drives CI to green itself (monitor → fix → re-push). Without an authenticated CLI it falls back to
  recommending the merge request for you to open and offering to fix any failures you paste back.


Step 1 — Get mandoline
----------------------

Mandoline is just this repo — a set of Markdown guides. **There are no other projects to check
out:** when the agent needs a gem's source (Spreewald, Capybara, …) it reads the target app's
own bundled copy via `bundle show`. So Step 1 is a single clone:

```bash
git clone https://github.com/makandra/mandoline.git
```

Put it wherever you like; you point Claude Code at it with `--add-dir` in Step 3.


Step 2 — Prepare the repo you want to migrate
---------------------------------------------

Do this inside the **target repo** (the app whose Cucumber tests you're converting). These
mirror the guide's Phase 1 checks; doing them now means the agent sails through them.

```bash
cd /path/to/your-app          # the repo to migrate (can live anywhere)

git status                    # must be CLEAN — commit/stash any changes first

ruby -v ; cat .ruby-version   # the two must match (re-activate / install the pinned Ruby if not)
node -v ; cat .nvmrc          # the two must match (install the pinned Node if not)

bundle install
bundle exec rails db:migrate
PARALLEL_TEST_PROCESSORS=4 bundle exec rake parallel:create parallel:migrate   # ONLY if the app uses parallel_tests — mandoline uses up to 4 parallel DBs, so create + migrate all 4 (it won't create them itself)

# Build the frontend so Selenium specs see real assets.
# Use the app's own command (README / Procfile.dev / package.json scripts); examples:
#   pnpm install && pnpm build       (or npm/yarn, per the lockfile)
# Apps on Sprockets (classic asset pipeline) need no pre-build.

# Match the timezone your dev machine / CI uses (check your CI config for a TZ variable),
# so browser-rendered times aren't off by a fixed offset:
export TZ='Europe/Berlin'     # use whatever your CI sets

bundle exec rspec --version   # sanity check: RSpec runs
```

The agent will re-verify all of this and stop to ask you to fix anything that's off — but
getting it right here avoids a round-trip.


Step 3 — Launch Claude Code and start the migration
----------------------------------------------------

From **inside the target repo**, launch Claude with a single command — it points Claude at the
guide and starts the migration. Everything else (confirming inputs, whether to resume a prior run
or start fresh, your session time budget) the guide handles once it's running; there's nothing to paste.

```bash
cd /path/to/your-app
claude --model opus --effort high --permission-mode auto --add-dir ../mandoline
```

Then enter this prompt:

```
Follow ../mandoline/app-migration-guide.md to migrate this repository from Cucumber to RSpec feature specs. This working directory is the INPUT.
```

This assumes you cloned **`mandoline` as a sibling of the target repo** (so it's at `../mandoline`).
**If your `mandoline` checkout lives elsewhere, adjust the path in both `--add-dir` and the prompt.**

A few notes:

- **Launch interactively, then paste the prompt.** Start the normal live Claude Code window with
  the `claude …` command above, then paste the migration prompt at its input — you see the agent's
  updates and answer its questions right there. Paste it explicitly rather than passing it as a
  launch argument: passing the prompt on the command line is unreliable (Claude Code often opens
  idle without running it). And don't use `-p`/`--print` — it runs headless and exits without
  taking input, which would defeat the migration's questions and reviews.
- The launch flags pin the three things the migration needs, so you don't set them by hand:
  - **`--model opus`** — the strongest model (the migration needs it).
  - **`--effort high`** — high reasoning effort.
  - **`--permission-mode auto`** — **auto mode**, so the run is genuinely hands-off: the agent
    runs its commands and edits without stopping to ask you to approve each one. Without it you'd
    have to confirm every step, defeating the unattended design. (A premium/Max seat is
    recommended anyway, and `auto` mode needs one; if it's unavailable on your plan, press
    **Shift+Tab** after launch to turn on "auto-accept edits", or use `--permission-mode acceptEdits`.)

  You can confirm the model and effort with `/model` after it starts.
- The guide's first step (Phase 1a) asks two quick startup questions — whether to **resume** a
  detected prior run or start fresh, and your **session time budget** (hours, or "no limit") —
  then runs unattended. **Re-launching and pasting the same prompt is also how you resume** a long
  migration across sessions: the agent picks up where it left off from the state in `tmp/mandoline/`.

The agent persists its progress under `tmp/mandoline/` in the target repo, so it can resume if
interrupted. When it finishes it leaves the original `features/` directory in place for your
review (delete it yourself once you're satisfied).


License
-------

Mandoline is released under the [MIT License](LICENSE). It is provided as-is: we publish the
guides we use ourselves, but we don't take issues or pull requests.
