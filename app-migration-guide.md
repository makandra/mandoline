# Guide to migrate a Ruby on Rails app's E2E test from Cucumber to RSpec feature specs

INPUT: Path of the repo we're migrating (the current working directory).

**Read this entire guide before you start executing.** It opens with operational rules — state & progress tracking, resume & session budget, and the parallelism model — that apply throughout the whole run, followed by the six migration phases (the executable steps). Don't jump straight to Phase 1: the material before it governs *how* you work.


## Our motivation

We have a lot of legacy Ruby on Rails apps with thousands of E2E tests written in Cucumber. Cucumber was in fashion in the 2000s, but now we want to replace it with RSpec feature specs. The English-prose-to-Ruby mapping in Cucumber is too cumbersome to maintain, and we now prefer to just call Ruby/Capybara in our tests.


## The contract: parity, not improvement

> **Every scenario that passed in Cucumber MUST pass as a migrated spec — reproducing the same observable behaviour and coverage. Never make a spec stricter than the origin; keep it looser only where this guide sanctions it (see *Faithful by default* below).** The job is a faithful translation — not a stricter or "more correct" test suite. You may improve a spec's *form*; never what it *verifies*. This single principle prevents the most common and most expensive failure mode of this migration.

The trap is subtle because being *stricter* looks like doing a good job. It isn't — it's a regression. Concretely, do **not**:
- invent an assertion the origin never made — an exact row **count** (`.exactly`) where the origin said only "the following rows", an exact string where it matched a substring, a recipient/`to:` the origin didn't check, a browser-dialog *text* where the origin only confirmed the dialog;
- tighten a path check — dropping `ignore_query: true` where the origin used Spreewald's `should be on` (path-only) turns a passing check into one that breaks on a stray query param;
- change the test's **principal or setup** — sign in as a freshly-created user when the origin's steps resolved to an existing one (e.g. `User.last` = the factory-created account owner). Trace what the origin's step definitions actually did; don't reinvent equivalent-looking setup;
- treat a scenario as "unverifiable" and skip/exclude it because the **RSpec suite is configured more strictly than Cucumber was** (the classic case: the base suite enforces `WebMock.disable_net_connect!` / VCR, which the Cucumber suite never loaded — see *Global mocks* in Phase 3).

**When a migrated spec is hard to verify or fails, your first move is to READ THE CUCUMBER ORIGIN** — the `.feature`, its step definitions (`features/step_definitions/**`), and support (`features/support/**`) — to see how the behaviour *actually worked there*. Do not fix it from first principles, and do not "correct" what looks wrong: quoted strings, casing, relative-time waits, and loose assertions were all acceptable to the Cucumber author and are therefore correct (required!) here. Reproduce what the origin did.

**The escape hatches are last resorts, not normal branches.** `skip` / `pending` / "leave unverified" / a CI-exclusion tag each lower coverage, so each must be justified against the question *"did this pass in Cucumber?"* The only genuinely-legitimate reason to leave a scenario unverified is a **system-environment fault the box truly cannot provide for** — an absent binary the app shells out to, an unprovisioned service, or a dependency **installed but sandboxed away from the workspace** (see the *missing dependency* rule in `conversion-guide.md`, which also bounds this by *scale*) — never "the suite mocks something Cucumber didn't", never "real-browser timing is flaky", never "a CI tag excludes it". Under fan-out, a worker that "flags an unverified/skipped scenario" *looks* diligent but is reporting a **coverage gap the orchestrator must resolve** (allow the net connection, wait longer, read the origin) before Phase 6 completes — not a note to relay in the final report.

Each escape hatch below is re-framed against this contract at its own site; this is the overarching rule they all serve.


## Faithful by default — the sanctioned exceptions

**The Cucumber suite is the reference — for *what* to migrate and *how* each test should behave.** Most of our work is a faithful, mostly mechanical translation into RSpec feature specs: we reproduce the same observable behaviour and coverage, deviating only slightly, and only toward simplicity or looseness — never toward being stricter (the failure mode *The contract* above exists to prevent). There are just a **few** places where this guide deliberately "optimizes" the original Cucumber feature for simplicity, aesthetics, or reader understanding:

- We sometimes **trim fat from overly complicated step definitions**, replacing them with a much shorter equivalent in modern Capybara (see *Convert trivial step definitions* in `conversion-guide.md`). We accept a little loss of strictness or edge-case coverage in the step's *implementation* — in trade for simplicity — but we **never drop or weaken an assertion the scenario actually made** (*Regrouping changes layout, never assertions*; the Phase-6 *whole-file fidelity* rule). A looser matcher (`should be hidden` → `have_no_content`) is allowed only when it is the faithful analogue of what the origin step actually did, never just because it's shorter.
- We sometimes **re-order a chain of consecutive assertions** (`expect(page).to …`) for aesthetics, in particular to collapse repeated `within()` scopes on the same selector. Re-ordering is usually effect-neutral, but re-order **reads only, never across an interaction**: occasionally a later assertion relies on an earlier one having waited out a prerequisite state, and moving it introduces a failure (see the *Expectations* grouping algorithm in `conversion-guide.md`).
- We sometimes **add narrative comments** to the spec, where intent would otherwise be lost now that RSpec has no "English prose ⇒ step" mapping to document it (*Intent is preserved* in `conversion-guide.md`). Purely additive — never a behavioural change.

**Calibrate to the scenario's key insight, not to every matcher.** Parity is judged at the level of *what the scenario proves*, not the exact strictness of each assertion. A small deviation — slightly stricter *or* slightly looser — is **fine when it simplifies the implementation and the scenario's key insight is still tested**; don't flag it in review, and don't "fix" it. The test to apply is one question: *does the migrated spec still prove the same thing the Cucumber scenario proved?* Same behaviour exercised → fine. Less (or different) behaviour exercised → not.

- **Fine — small, implementation-simplifying, key insight intact:** `find_field('X')` instead of `find_with_disabled(:field, 'X')` when the field isn't disabled in this scenario; `have_field('X', with: 'value')` instead of `have_select('X', selected: 'Label')`; `not_to eq('')` instead of `not_to be_blank`; `click_on` instead of `click_link`/`click_button` when only one element carries the label; dropping an `[aria-label]` selector alternative when the BEM class is the real hook; collapsing a defensive step definition into a Capybara one-liner; turning an origin step that was a **latent no-op** (asserted nothing) into the real assertion it obviously intended (see *Repairing a bad test*).
- **Critical — never OK, because it changes what's proven or drops coverage:** dropping or `skip`/`pending`-ing a scenario, or dropping a distinct `Then`/assertion; any deviation that **flips pass↔fail for the behaviour under test** — a dropped `ignore_query: true` where the URL carries a query (reddens CI), or un-scoping a table assertion on a **multi-table** page (can match the wrong table); excluding/skipping a scenario because of a global mock (WebMock/VCR — coverage loss); changing the test's principal/setup so a different code path runs; weakening an assertion the scenario's key insight *depends on* (asserting mere presence where the exact rows are the point).

The rule of thumb: **simpler is welcome and ±ε strictness is fine — as long as the same behaviour is still exercised.** What's forbidden isn't "being slightly off the origin," it's "proving less than the origin did."

When an optimized spec fails and the fix isn't obvious, fall back to the reference: **read the Cucumber origin** (per *READ THE CUCUMBER ORIGIN* above) to see how the behaviour actually worked there. Assume every scenario passed green for its author before the migration — its behaviour is what you reproduce. If a simplified spec can't go green without dropping coverage, you simplified too far: restore the origin's fuller form.

**That "every scenario passed green" assumption can be replaced with fact — run the Cucumber suite once as a baseline.** It's usually a few minutes well spent (run it against a spare parallel DB so it doesn't disturb your work, and keep the output under `tmp/mandoline/`). The baseline tells you which scenarios were **already red before you touched anything** — one migration found a scenario already failing at origin — so you don't chase a pre-existing origin failure as if your port broke it. A scenario red at origin isn't yours to reproduce-to-green: flag it for the human and move on. (For a scenario-level question later — "did the origin really assert this?" — you still instrument that single scenario, per *instrument the origin* in `conversion-guide.md`; the baseline just gives you the whole-suite pass/fail map up front.)


## Repairing a bad test — welcome, never required, always bounded

Occasionally the origin scenario isn't just loose, it's **broken** — a bad test in its own right:
- its **description doesn't match what it actually checks**;
- an **assertion is always true** — e.g. a negative assertion that passes only because the element never appeared (see the vacuous-negation traps in `conversion-guide.md`), or one that's true only *relative to the previous state* (the same rows asserted after each of several different filters, so it holds whether or not the action did anything);
- it's **flaky** because it fires several actions without observing each one in between (see *interleave actions and observations* in `conversion-guide.md`).

Improving such a test is **welcome, but never required** — and the effort must stay **proportional to the task**. Try the quick, obvious fix. But if it isn't straightforward — it starts rewriting large parts of the spec or the app, or sends you round in circles — **stop and translate the poor test faithfully instead.** A spiralling improvement costs far more than the coverage it would have added.

A merely **loose-but-working** assertion is *not* a bad test — a substring instead of an exact match is often a deliberate guard against brittleness. Leave it.

**A flakiness repair needs *proof*, not a plausible mechanism.** Adding a wait or an observation because it explains the failure is a hypothesis, and hypotheses ship: in one migration a commit claiming to fix a race landed, and the same spec kept failing afterwards. Before you call a flake fixed, **re-run that spec enough times to have seen the failure** (a `--seed` sweep, or a repeat loop of 10–20 runs), and **record in the commit message how many runs you did**. If you can't reproduce the original failure at all, you cannot show you fixed it — say that instead of claiming a fix. Fixing the *wrong* thing is worse than leaving it flagged, because the label "fixed" stops anyone else from looking.

**Record the decision either way in `needs-attention.md`:** that you repaired a test (and leave a brief spec comment saying what was broken and what changed), *or* that you left a bad test unrepaired (no straightforward fix, or you aborted a spiral) — so the human knows a weak test survived the migration.


## Overall strategy

- We need to configure RSpec feature specs to automate browser interactions with Capybara. For this we are going to transform all Cucumber support files (`features/support/**/*.rb`) into Ruby helper methods and `RSpec.configure { ... }` settings.
- We are going to transform all step definitions (`features/step_definitions/**/*.rb`) into Ruby helper methods and `RSpec.configure { }` settings. Trivial step definitions can also be inlined as short Ruby statements or Capybara calls, bypassing the need for extra helpers or custom matchers.
- When we transform a step definition or `Before`/`After` hook into a Ruby method, we remember the original step definition so we can correlate usage in the next step.
- We are going to transform all Cucumber scenario (`features/**/*.scenario`) into RSpec feature specs. For each step we recall the step definition that we transformed earlier, and replace the step with a call to the Ruby method that we generated in an earlier step.


## Migration phases

Work through these phases in order. The numbered headings further down mirror these numbers.

**The number is the order you *enter* a phase, not a promise it fully finishes before the next.** Phases 1–2 and the RSpec/Capybara setup in Phase 3 are genuine prerequisites — do them before migrating any feature. After that, converting support code (3), step definitions (4) and features (5) **interleave**: migrating a feature (5) routinely pulls in a step-definition conversion (4) and sometimes a new support helper or matcher (3), on demand. That's expected — mix these as dependencies require (and as consolidating an existing RSpec suite requires); the phases are a map of the work, not rigid gates.

1. **Preflight checks and environment setup** — confirm inputs and ground rules, verify the app's Ruby *and Node* versions are active (ask the human to fix if not), install gems, build assets, migrate the DB, replicate CI env vars (e.g. `TZ`), and confirm RSpec runs.
2. **Internalise the house style** — it is documented statically in `conversion-guide.md`; read it. You don't need to study the reference apps to rediscover the style (they remain a backstop for edge cases).
3. **Converting support code** — configure RSpec for feature specs (Capybara/Selenium), **audit what `spec/support/` already provides**, and transform only the *gaps* plus the cross-cutting `features/support/**` and shared step definitions into modules, hooks and matchers. Record the step→method mapping (see *Scratch files* below).
4. **Converting step definitions** — convert the obvious infrastructure (auth, shared matchers) up front; convert everything else **on demand** in Phase 5, memoizing each in the mapping artifact so it's reused, never re-converted. Turn each into a Ruby method (or inline it).
5. **Converting features and scenarios** — translate each `.feature` into a feature spec, **one scenario at a time**, verifying and reviewing each scenario before moving on. (The full craft for phases 4 and 5 lives in `conversion-guide.md`.)
6. **Finishing up** — after the authoring fan-out (each worker having already normalized its own spec), a serial orchestrator pass: consolidate the support tree, lint, run the verification, then sort out knapsack, switch CI off Cucumber, **open the merge request and drive CI to green** (or recommend it when the remote isn't controllable), report what remains, and signal completion.


## State, progress, and resuming (operational rules)

This is a large, long-running task — for a giant suite, several sessions. Its state won't fit in one context, and a session can end at any time (budget or quota running out, the human stepping away, a crash). **Persist your state to scratch files so a later session can always resume**, and keep the human informed.

### Parallelism — serial foundation, then a job queue of short-lived workers

The migration is a small **shared foundation** every feature depends on, plus a large body of **independent per-feature work**. One main agent — the **orchestrator** — runs the whole migration and performs every shared or serial step itself. It fans out to background **workers** only for the independent per-feature authoring, and only after the shared foundation is in place.

#### The three stages

1. **Serial foundation (Phases 1–4) — orchestrator only.** Build all shared code once — the environment, RSpec/Capybara config, support-file migration, and **every cross-cutting step definition** (auth/sign-in, the `paths.rb`/`selectors.rb` helpers, shared matchers, and common JS-widget interaction helpers like Select2 and date pickers) — into the shared support tree and the canonical `step-mapping.md`. Then migrate features serially — **auth first, then the features whose steps recur most** (grep step frequency across the `.feature` files) — **until one feature completes needing no new shared support.** That is the signal the shared surface has stabilized — fan out now: hand the remaining features to spawned workers (up to 4, or a single worker at a time with no `parallel_tests`) — the per-feature work runs in workers, not in you (see *The job queue*). Workers build on this foundation and **may still extend or edit it** when a feature needs something it lacks (logging each change — see below); because you stabilized it first, that stays rare.
2. **Fan-out (Phase 5) — a job queue of short-lived workers.** Migrate the remaining **in-scope** `.feature` files through a **quota-paced pool of workers** (up to 4, throttled down automatically as the 5-hour quota window fills — see *The job queue* below; with no `parallel_tests`, a single spawned worker at a time). Workers write their own spec files and may edit the shared support tree directly, logging each change; see below.
3. **Finishing up (Phase 6) — orchestrator only, in the foreground.** After authoring, consolidate the shared support tree (serial — cross-file work, never parallelized), lint, and run **one verification pass** over this session's migrated specs (`parallel_tests` for speed = OS-process parallelism, **not** another fan-out), then the shipping steps (knapsack, CI-off-Cucumber, the MR + driving CI to green, the report). There is **no** separate review/normalize fan-out — **each worker normalizes its own spec to the house style before returning it** (see *What a worker does*).

#### The job queue, paced by the quota window
The features to migrate are the **in-scope, not-yet-done** ones — the Phase-1a scope, minus anything already migrated (on a resume). **Translate every `.feature` to a corresponding spec so the two trees line up 1:1** — even an empty or fully-commented one, since a reviewer diffs the trees: an empty scaffold → an empty (or one-comment-line) spec; a feature whose scenarios are **all commented out** → a spec that preserves the original Gherkin as a comment (RSpec loads a comment-only file and defines nothing, so the suite stays green) **plus a `needs-attention.md` line** — commented-out scenarios are disabled behaviour, a pre-existing coverage gap the human should see rather than inherit invisibly (and one that Cucumber-removal would otherwise delete without trace). These trivial targets carry no authoring work, so the **orchestrator produces them inline** — don't queue them as worker jobs, don't flag them as blockers. **The one exception is a stub symlinked many times** (e.g. a folder of identical stub features used for parallel-run debugging): translating it 1:1 would spray N identical empty specs, so skip it. The rest run through a **job queue** of short-lived workers, and the orchestrator **throttles concurrency and job size by how full the 5-hour quota window is** — wide open while the window is fresh, tapering to nothing as it fills — so work never crashes into the usage limit. Workers stay dumb; **all quota pacing lives here, in the orchestrator.**

- **Rank files biggest-first** by the cost proxy — **non-blank, non-comment line count**: `grep -cvE '^[[:space:]]*(#|$)' file.feature`. Hand out the biggest files while the window is freshest: a big feature is an atomic unit (a worker migrates it whole), so it needs the most headroom to finish — dispatched late, it would run out of window mid-file. **Assemble each job by packing features (biggest-first) up to the current tier's line-count budget** below; a single feature larger than the budget goes alone. Line count is a deliberately dumb proxy (it's language-agnostic, so it works for German Gherkin too, and it rolls steps + tables + Scenario-Outline rows into one number); precision doesn't matter because the quota ladder is the real safeguard. No JS multiplier — a `@javascript` scenario is slow (idle browser wait), but that wait costs no tokens.
- **Read the quota at every slot-free moment.** A worker terminating frees a slot — the natural point to decide what's next. Run `bin/quota.sh` from your mandoline checkout (**derive the path from where mandoline was `--add-dir`'d — it may be `../mandoline`, `../gems/mandoline`, …; don't hardcode `../mandoline`**) → it prints `<utilization> <resets_at> <resets_in_min>` (`utilization` = percent of the 5-hour window **used**; `resets_at` is **UTC**, and `resets_in_min` is whole minutes until it resets — use *that* for any "will the reset fit before X?" comparison, since the migration otherwise works in local time; it self-caches ~75 s, so calling it on every termination is cheap). If it prints `unknown` (endpoint hiccup / offline), treat the window as nearly full and act conservatively — **but a persistent `unknown` is often a *fixable* block, not an empty quota: under a network-filtering sandbox the call to `api.anthropic.com` is refused, so check whether the sandbox blocked it (and allow that endpoint) before resigning yourself to the reserve tier.** Compute `left = 100 − utilization` and apply the ladder:

  | quota left | concurrent workers | job size |
  | --- | --- | --- |
  | ≥ 55% | up to 4 | generous line-count budget |
  | ≥ 45% | 3 | moderate budget |
  | ≥ 35% | 2 | small budget (≈ one feature) |
  | ≥ 25% | 1 | small budget (≈ one feature) |
  | < 25% | 0 — drain, then wait for reset (see *Resume & session budget*) | — |

- **Concurrency ratchets down, never up mid-window.** Utilization only climbs until the window resets, so the pool shrinks monotonically (4→3→2→1→0): when a worker terminates and the current tier allows fewer workers than are running, simply **don't refill** — let the pool shrink as workers finish. No thrashing. After a reset the window is fresh and you ramp back to the top tier.
- **Refill on termination when the tier allows it.** If the tier permits more concurrent workers than are currently running (and quota isn't in the reserve), spawn a fresh worker into the freed slot with the next tier-sized job, biggest-remaining-first, until the queue drains.
- **Print every batch decision — it's your audit trail.** Each time you size a job and (don't) spawn, print the reasoning so a later debugger can see *why* the pacing behaved as it did: the quota reading that drove it, the tier it selected, and the job's `.feature` files each with its line-count proxy. On a dispatch:
  ```
  quota: 48% left → 3-worker tier (medium jobs) · spawning worker into freed slot
    features/billing/invoices.feature   312
    features/billing/refunds.feature    128
    → packed 2 files (~440 lines, medium budget), biggest-remaining first
  ```
  When you deliberately **don't** dispatch, print that too, with the reason — e.g. `quota: 38% left → 2-worker tier, already 2 running → hold (ratcheting down)` or `quota: 22% left → reserve; draining, then waiting for reset`. These lines are for debugging, so favor concrete numbers over prose.
- **Even one worker is a *spawned* worker — never migrate inline.** Whether concurrency is 1 because of the quota tier or because there's **no `parallel_tests`** (which pins it at 1 — you can't isolate concurrent DBs), the orchestrator still spawns a single worker per job rather than doing the migration itself. That keeps the orchestrator a thin coordinator that **re-reads quota at each termination and ramps concurrency back up (2→3→4) as soon as a window reset re-opens headroom.** The job-size taper still applies at concurrency 1 (shrink each job as the window fills; stop-and-wait at < 25% left).

#### Progress = worker completions (no streaming, no heartbeat)
A background worker **cannot stream to the orchestrator** — you only hear from it when it terminates. Short-lived workers turn that constraint into the progress mechanism: **each termination is a tick.** On every completion, update `progress.md` (features done / total, and the running scenarios-migrated tally — the headline fan-out metric), **fold any items the worker flagged in its summary into `needs-attention.md`**, and print the aggregate status line. There is **no** heartbeat, polling, `progress-<id>.md` shard, or `SendMessage` continuation — a worker finishes its one job and returns a one-line summary. (`progress.md`, kept current by the orchestrator, remains the resumable record.)

#### Stop/continue check at each slot-free moment
A worker terminating is the natural point to decide what's next — and the only place these are checked (no interval polling):
- **Quota** — apply the ladder above: read `quota.sh`, set the tier, refill or not. At **< 25% left**, spawn nothing, let in-flight workers drain, then **wait for the window to reset and resume in place** (see *Resume & session budget → riding out the quota window*). You do **not** hand off to a fresh session for quota.
- **Session budget & context** — the other two stop conditions in *Resume & session budget*. If either is low, stop scheduling, let in-flight workers drain, and **hand off** to a fresh session (the human re-runs the launch command and chooses resume).

#### What a worker does
A worker migrates its assigned features and shares one **live** `spec/support/` tree with the other workers:
- It migrates its job's `.feature` files into `spec/features/**`, following **`conversion-guide.md`** (craft + house style) and reusing everything already recorded in `step-mapping.md`.
- If it needs a helper/matcher the foundation doesn't provide, it **adds it directly to the shared support tree** — no per-worker files, no inlining-for-isolation. Two concurrent workers *could* touch the same support code; with a stabilized foundation that's rare. Nothing reconciles concurrent-edit *conflicts*, so the final verification run plus CI are the safety net (the Phase 6 clean-up consolidates *duplication* afterward — a separate concern).
- **It logs every support-code change** to its own `tmp/mandoline/support-changes-<id>.md` — one line each: `timestamp · file · helper/matcher name · what changed`. Its **own** file, so concurrent logging never clobbers.
- **If it changes an *existing* shared helper/matcher** (signature or behavior), it greps for that helper's **other call sites** — in features outside its own batch — and fixes them too. Narrow: adjust the call sites, not a broad refactor.
- It verifies **scenario by scenario** — each scenario green individually as it goes (`TEST_ENV_NUMBER=<id> bundle exec rspec spec/features/<file>_spec.rb:<line> --format doc`, confirming the printed example name is the scenario it meant — see the `:line` gotcha in `conversion-guide.md`).
- **Then it normalizes the whole file before returning it** — a distinct final pass, **not** review-as-you-go (as-you-go is what produced uneven grouping before). With every scenario green, it works the concrete checklist in `conversion-guide.md` → *Finish a feature with a whole-file normalization pass* (make grouping identical across scenarios, merge same-selector `within`s, one-interaction-per-block, lone-scoped → `have_css`, cluster page-level, multi-line `.and`, blank-line isolation, whole-file fidelity — several checks are greppable), then **re-runs the scenarios it changed**. Only now is the feature **done**. It still does **not** re-run the whole feature or batch beyond what it touched (the single Phase 6 verification run covers the rest).

#### How the orchestrator briefs a worker
The brief splits into a **shared part** (identical for every worker) and a tiny **per-worker part** (two variables). **Write the shared part once** to `tmp/mandoline/worker-brief.md` — right after you freeze the foundation, since it names the foundation's helpers — then make each spawn a short pointer plus the two variables. Don't regenerate the shared prose per worker: it wastes your context, scales badly across a job queue, and risks paraphrase drift.

**`tmp/mandoline/worker-brief.md` (write once, after freeze)** — pointers, not rules; the reusable instructions live in `conversion-guide.md`, which opens with the worker reading order:
- **Who you are (stated first, so you recognize yourself in the "if you are a fan-out worker" notes):** *"You are one of several parallel fan-out workers migrating this repo at the same time. You own only the feature files your spawn lists; you may add to or edit the shared `spec/support/` tree when needed, but log every change to `support-changes-<your-id>.md`, and if you change an existing helper, grep for and fix its other call sites; run every command under your `TEST_ENV_NUMBER`; before you mark a feature done, do the **final whole-file normalization pass** (`conversion-guide.md` → *Finish a feature with a whole-file normalization pass* — a concrete checklist), then re-run what you changed; you can't ask questions mid-run, so report everything in a final summary."*
- **What to read:** `conversion-guide.md` (and `spreewald-guide.md` / `cucumber_factory-guide.md` on demand for any step not yet mapped), then `step-mapping.md` for everything already converted.
- **App-specifics — fill these in from the foundation you actually built; never leave placeholders.** List the real helper/matcher names the foundation provides (e.g. `sign_in(user)`, `have_flash(:type, 'text')`, `have_table_with_rows(...)`, `within_modal { }`), point to a couple of the already-migrated `spec/features/**` specs as exemplars, and note any app-specific gotchas you hit migrating the first features (a quirky auth flow, a locale/timezone setting, a factory trait workers will need). **If this is a Rails 2 / RSpec 1 app** (Phase 1b detected it), say so and tell the worker to **also read `rails2-guide.md`** — the specs use the RSpec-1 dialect.
- **If the repo enforces RuboCop *inside* the rspec suite** (a `spec/rubocop_spec.rb` that isn't `allow_failure` — check for one during foundation setup): tell the worker its specs must be **offense-free**, because any offense fails the ordinary `bundle exec rspec` run, not just a separate lint job. Flag **`RSpec/RepeatedDescription`** in particular — two identically-named scenarios in one `.feature` become two `scenario 'same name'` blocks that trip it, so rename one (e.g. a distinguishing suffix). (Fuller cop list in Phase 6 → *Lint*.)
- **What to return:** a short completion summary — per feature, scenarios migrated/green, any shared-support changes you made (also logged to `support-changes-<your-id>.md`), any new step→method mappings (the orchestrator folds these into `step-mapping.md`), and anything you skipped or flagged for the orchestrator to resolve.

**Each spawn (the per-worker part)** — just: *"Read `tmp/mandoline/worker-brief.md`. Your feature files: `…`. Your `TEST_ENV_NUMBER`: `N`."* (The first slot's `N` is **blank** — see the numbering note in *Ground rules*; omit `TEST_ENV_NUMBER` entirely for a lone worker with no `parallel_tests`.)

#### Ground rules
- **`parallel_tests` is required for concurrency ≥ 2.** Each *concurrent* worker needs an isolated DB via `TEST_ENV_NUMBER`. **If the app also shares a Redis across workers**, that number must fold into the Redis namespace too, so workers don't clobber each other's keys (e.g. via `REDIS_URL` or the app's Redis config — adapt to how the target app configures Redis, or skip if it uses none in tests). **No `parallel_tests` → concurrency pinned at 1:** still spawn a single worker per job (don't migrate inline), just run one at a time and omit `TEST_ENV_NUMBER` (it uses the plain test DB).
- **`TEST_ENV_NUMBER` numbering — the first slot is blank, not `1`.** `parallel_tests` names the first database **without** a suffix (`app_test`) and only suffixes the rest (`app_test2`, `app_test3`, …) — there is **no `app_test1`**. So map the first fan-out slot to a **blank/unset** `TEST_ENV_NUMBER` (`bundle exec rspec …`, no prefix) and the others to `2`, `3`, `4` (`TEST_ENV_NUMBER=2 bundle exec rspec …`). Using `TEST_ENV_NUMBER=1` fails with `database "app_test1" does not exist`.
- **Shared support is live, not frozen — but log every change.** A worker may add to or edit `spec/support/` when a feature needs it; it records each change in its own `support-changes-<id>.md` and fixes other call sites if it altered an existing helper. Concurrent edits *could* collide, but a stabilized foundation makes that unlikely. There's no *conflict*-reconciliation stage; the final verification is the safety net (point it at the change logs if failures appear). **Edit a shared file that already exists with `Read` → `Edit` (add or modify in place), never a whole-file `Write`** — a `Write` silently clobbers a helper a concurrent worker just added; and if an `Edit` fails because the file changed since you read it, **re-read and re-apply** onto the current content (reconciling both) rather than forcing.
- **The orchestrator does the *shared* serial work itself, in the foreground — never in a background agent:** the foundation (Phases 1–4, including migrating the first features until the support surface stabilizes), briefing workers, the Phase 6 support-tree consolidation, and the Phase 6 verification. But **per-feature authoring during fan-out is always delegated to a spawned worker — even when only one runs at a time** — so the orchestrator stays free to poll quota and scale concurrency back up when a window resets. And **never fan out just to overlap a short serial task** (reading CI config, teardown) with the workers.
- **Stay serial** whenever fan-out doesn't fit: no `parallel_tests`, or a suite small enough that the foundation already covers most of it.

### Scratch files (use `tmp/mandoline/`)

Write all our files under **`tmp/mandoline/`** in the repo you're migrating (it's git-ignored). You run from inside that repo, so a single folder is enough — no repo name in the paths. Re-read these whenever you resume.

**Write incrementally — flush the moment something happens, never hold state in memory to "write later."** Append a mapping row the instant a step is converted, append a `progress.md` event when a feature is done (orchestrator only), append to `guide-feedback.md` when you hit a guide problem. These files exist to survive interruptions and let a later session resume — anything kept only in your head is lost when the run stops.

At minimum, maintain:

- **`tmp/mandoline/step-mapping.md`** — the **step→method mapping**, the linchpin of the whole migration. As you convert each step definition (phase 4) and each support hook (phase 3), append a row recording the original step regexp, the file it came from, and the generated Ruby method (module + name + keyword signature), or "inlined" / "Spreewald" / "cucumber_factory" if it didn't become a helper. In phase 5 you **read this file** to translate each scenario step — do not rely on memory. Example rows:

  ```
  | Original step                                   | Source file              | Maps to                                  |
  | ----------------------------------------------- | ------------------------ | ---------------------------------------- |
  | When /^I sign in as Joe$/                       | authentication_steps.rb  | AuthenticationSteps#sign_in_as_joe       |
  | When /^I save the form$/                        | web_steps.rb             | inlined: first('[type=submit]').click    |
  | Then /^I should see "([^"]*)"$/                 | (spreewald)              | expect(page).to have_content(...)        |
  ```

  **A recorded claim is consumed as fact — verify it before you write it.** Workers translate steps straight from this file, so an annotation like *"origin bug"* or *"dead step — skip it"* propagates to every scenario that uses it. **Empirically verify** any such claim first — run it, or probe the behaviour in a rolled-back transaction — before recording it: a step that *looks* broken often isn't (`groups << Group.where(name:)` looks like it pushes a relation, but an `ActiveRecord::Relation` flattens via `to_ary`, so `concat` unwraps it), and a "dead" step over-generalised from a genuinely-broken *sibling* may be well-formed and used across many files (skipping it silently changes their setup). Workers may contradict the mapping when something genuinely looks wrong, but shouldn't second-guess it reflexively — it's usually right. **Mark the risky rows.** A mapping you derived by *reading* a step definition but did **not execute** is the one most likely to be wrong — tag it `(unverified)` in the table so a worker re-checks it against the origin step before relying on it. (Real case: `"X" should be selected for` a disabled multi-select was recorded as `select_options(...).to include(...)`, but the origin reads `field.all('option[selected]')` — so on the multi-select where it's used the recorded form is **vacuous**, passing whatever is selected. A worker caught it only by re-reading the origin.) **A *negative* claim is the most dangerous kind** — "this step/callback isn't needed", "the factory doesn't write back to its parent". A single easy case that happens to pass *looks* like proof, and every later worker that also hits the easy case **reinforces** it (several workers can independently "confirm" the same false negative). Before recording a negative claim, run a **deliberate counter-example** that would fail if the claim were wrong; observing a passing sample is not verification, and `(unverified)` won't be applied because it *feels* checked.

- **`tmp/mandoline/progress.md`** — the **append-only event log** that makes the migration resumable across sessions. **Only the orchestrator writes it** (never a worker — one writer, no races). Append one line per event, so a crash mid-write loses at most the last line: the **master feature list + feature and scenario totals** (written once, early); each **phase milestone** as it completes (`env ready`, `support foundation built & stable`, …); each **feature** when it reaches **done** — migrated, green, and whole-file-normalized by the worker, **recording its scenario count** so the scenarios-migrated tally replays on resume (`feature users/list → done (6 scenarios)`); and anything **skipped/flagged**. A spec file on disk that isn't logged done is a **partial** from an interrupted run and must be redone. Derive current status (done / todo / flagged) by replaying the log; that's exactly what a resumed session reads to know what's left (the remainder is `all − done`).

- **`tmp/mandoline/needs-attention.md`** — the **consolidated list of everything a human must look at**, kept *out* of the `progress.md` noise so it can't get lost among dozens of routine events. **Only the orchestrator writes it.** The moment an item is flagged — a feature you **couldn't migrate or verify** (e.g. a missing system dependency), a **skipped** scenario, an ambiguous mapping, a helper collision, anything needing human judgement — append one line: `file · what's wrong · when`; fold in whatever a worker flags in its completion summary too. **Reconcile it at every termination and on resume:** drop any entry that's since been resolved (e.g. a feature that now carries its migration marker), so it stays current and nothing stale resurfaces. This file is the single source for the loud `⚠️ NEEDS ATTENTION` block in every handoff and the final report — persistent across resumes, re-scanned each time you stop.

- **`tmp/mandoline/guide-feedback.md`** — anything about *these guides* that was wrong, vague, or missing while you followed them. **Append to this file the moment you hit such a problem** — one entry per issue, written then and there — don't accumulate them in memory to dump at the end (you'll forget some, and an interrupted run loses them all). This is feedback for the humans maintaining the guides, **not** working state — leave it in place at the end. **In Rails 2 mode, tag each entry with the guide it belongs in** — prefix `[rails2]` when it's specific to the RSpec-1 dialect / `rails2-guide.md`, and leave the rest untagged (main guide / `conversion-guide.md` / step guides) — so it's later folded into the right guide.

- **`tmp/mandoline/finished.md`** — a **terminal completion signal** for a reviewing agent, written **only** at the very end of Phase 6 once *every* feature is `done` (migrated, green, and normalized by its worker) — see *Phase 6 → Signal completion*. It is **not** working state, and is **never** written on a partial stop (budget/quota out, a scoped subset, human intervention) — its presence means the whole suite is done, full stop.

`step-mapping.md`, `progress.md`, and `needs-attention.md` are resumable **working state** (a fresh run clears `tmp/mandoline/` via the Phase 1a resume question; a resumed run reads them — see *Resume & session budget*). **Don't delete `tmp/mandoline/` at the end of your run** — leave the whole folder in place. Its `guide-feedback.md` is collected much later by a separate guide-revision pass, so wiping it loses that feedback; a *later* fresh migration will clear the folder if needed. (For brevity the rest of this guide refers to them by bare name; they always live under `tmp/mandoline/`.)

### Keep the human posted

Post a short status line after each unit of work (a support file converted, a scenario green), so the run never looks hung. Two rules:

1. **Lead with a count, never a bare phase name.** A bare "Phase 5 — Converting features" can sit unchanged for an hour and looks stuck. Report whatever currently has a denominator — support files converted early on, then **scenarios migrated** once fan-out is underway. **Scenarios, not features, are the progress metric during fan-out:** features vary so wildly in size that "12/53 features" tells the human little, while "scenarios migrated / total" tracks real progress. Since the phases interleave, a single update can span more than one: e.g.

   > support 40/40 · **scenarios 78/312** · now `users/list.feature` (scenario 3/6 green) · 2 flagged

2. **Read the status from `progress.md`**, which you keep current as you go (see *Scratch files*) — don't reconstruct it from memory.

Work out each denominator once, when you first need it, and store it in `progress.md`. The fan-out headline denominator is the **total scenario count** across the in-scope features — count it up front, e.g. `grep -rE '^[[:space:]]*Scenario' features/ | wc -l` (counts `Scenario`/`Scenario Outline` header lines; approximate, but a stable gauge). The feature count (`ls features/**/*.feature | wc -l`) is still worth storing for resume bookkeeping, just not the headline. Fold this into the stop/continue checkpoint below so it's one regular beat.

**Include this session's elapsed time in the line, and always print it at two moments: when a phase completes, and when a worker terminates.** Elapsed is `now − session-start.md`, always the *current* session (not the whole multi-session migration). During **fan-out** (Phase 5) emit the line on each **worker completion** — append the finished feature(s) and their scenario counts to `progress.md` (advancing the scenarios-migrated tally), then print (see *Parallelism → Progress = worker completions*): e.g. `session 1h12m · scenarios 214/312 · 3 workers running · 2 flagged`.

### Resume & session budget

Giant suites take several sessions. The migration must survive a session ending — **abruptly** (crash, `Ctrl-C`, quota kill) as well as cleanly — and pick up in a fresh session. That rests entirely on the on-disk `progress.md` event log (see *Scratch files*); everything here builds on it.

**The stop/continue checkpoint.** Run it at every natural breakpoint — **after each worker terminates** (fan-out) and **after each feature you migrate serially** (the foundation phases, where there are no worker terminations to trigger it). Quota is handled differently from the other two conditions:

**Quota — pace it and ride it out; never hand off for it.**

> **⚠️ QUOTA RESERVE IS NEVER A HAND-OFF.** Low quota — at any point, at any phase boundary — means **wait in place for the window to reset, then resume**. It is *not* one of the stop conditions. Only the two **measured** thresholds below — (A) session budget and (B) context — end a session, and quota is neither. Never combine "quota is low" with a vague "and context feels tight" to justify a hand-off the quota rule forbids. (One nuance: the ride-out wait itself counts against the session budget (A) — if *that* runs out while you're waiting, you hand off on the **budget**, not the quota; see *Riding out the quota window*.)

Quota is managed proactively by the job-queue ladder (*Parallelism → The job queue*): as the 5-hour window fills, concurrency and job size taper (4→3→2→1), and at **< 25% left** you spawn nothing. This lets a long migration run **unattended across many quota windows**, never handing off to a human for quota.

- **Riding out the quota window.** Once quota hits the reserve (< 25% left) *and* the in-flight workers have drained, **wait in place for the window to reset, then resume** — no fresh session, and no human unless the endpoint breaks. **You own the wait loop yourself, in short chunks.** Don't try to block in one long-lived call: this harness (and many) **kills any single Bash invocation — foreground *or* background — at ~10 min** (SIGTERM → exit 143), which is *not* a quota verdict, so a 30–70-min ride-out must be a loop of sub-cap steps. Each pass:
  1. **Print a visible status line first** — a silent multi-hour wait looks frozen: e.g. `⏳ Quota 12% free (< 50% target) — waiting ~9 min, then re-checking; will resume automatically.`
  2. **Read the quota once** with a short call — `read used resets mins < <(../mandoline/bin/quota.sh)` (`mins` = whole minutes until the window resets, already UTC-safe) — and branch:
     - **`used` is numeric and `100 − used ≥ your threshold`** (≈ 50, a healthy tier) → the window reset: set the tier from the ladder and **resume the fan-out**.
     - **numeric but still under threshold** → the window is counting down; `sleep 540` (≈ 9 min, under the cap) and loop.
     - **`unknown` / unreadable** → **don't resume blind.** Retry the read once or twice; if it stays unreadable for **~10 min** it's almost always an **expired OAuth access token** (it refreshes only when Claude Code makes a call, so it won't self-heal while you idle) — **ask the human to type anything into the terminal** (that turn refreshes the token), then re-check. Never loop silently on it.
  3. **Keep two counters across passes so you never hang:** consecutive-unreadable reads (→ escalate to the human, as above) and total elapsed (if you've waited well past one 5-hour window and still can't clear the threshold, something's wrong — the threshold may be set too high; surface it).

  `bin/quota.sh` self-caches (~75 s) and the usage endpoint isn't billed against the window, so polling is cheap. **Never resume on a non-numeric reading, and never hand off the whole session for quota** — the wait and the resume both happen right here.

  **The session time budget keeps running while you wait.** The ride-out counts against it like any other elapsed time, so if the budget falls under the 15-min threshold mid-wait (see *Session budget & context* below), stop the loop and hand off cleanly — that's a **budget stop (A)**, not a quota hand-off (you're stopping because the human's time box expired, not because quota is low). The `resets_in_min` field lets you see it coming: if the next reset is further out than your remaining budget, the wait can't finish in time, so hand off rather than starting another pass.

**Session budget & context — these *do* end the session; hand off.** Stop on either measured threshold:

- **(A) Session budget** — under **15 minutes** left (elapsed `now − session-start.md` vs the hours the human gave; skip if they said "no limit"). A rough guess — fine if an already-running worker overruns it; you just don't start new work below it. **This counts wait time too:** a quota ride-out runs the clock down like anything else, so if the budget expires mid-wait, hand off (see *Riding out the quota window*).
- **(B) Context** — under **15%** left. (Rarely binding — each worker runs as a spawned **sub-agent** with its own context window, so they carry most of the load — but a cheap backstop.) **You have no reliable context meter — do *not* substitute a feeling that "this conversation is long" for a real reading.** Context pressure is handled by automatic summarization (you don't need to wrap up early), so **never self-declare a context hand-off without an actual low-context signal** — and never let a vague sense of length turn a quota ride-out into a hand-off (see the guard above).

**On (A) or (B):** stop cleanly. Schedule **no** new workers; let in-flight workers **finish and get logged** (never kill them — that discards partial features that resume would redo); then **summarize and hand off** — this is a partial stop, so **do not** create `tmp/mandoline/finished.md` (that marker is only for a fully-migrated suite; see *Phase 6 → Signal completion*). **Lead the summary with the loud `⚠️ NEEDS ATTENTION` block — the reconciled contents of `needs-attention.md`** (drop anything now resolved first) — then report: how far you got (`migrated 240/900`), that all state is saved under `tmp/mandoline/`, and that the human resumes by **re-running the same `claude … "…"` command from the README** and choosing "resume" when asked. No mid-session compaction — a fresh session is how you get more budget/context.

**Resuming (when the human chose "resume" in Phase 1a):**

- **Re-run Phase 1.** A new session doesn't inherit the old shell's activated Ruby/Node, built assets, or `TZ` — re-verify the environment (it's idempotent). Only *migration* work is skipped, never the preflight.
- **Reconcile the log against disk — don't trust it blindly.** Skip features logged **done** (green, reviewed, normalized) whose spec file still exists; a spec file that exists but **isn't** logged done is a partial from an interrupted run → **redo it** (overwrite). Rebuild the fan-out job queue from the genuine remainder (all features − done).
- **Re-surface what still needs attention.** Read `needs-attention.md` (it persists across sessions) and reconcile it against disk — drop entries now resolved (e.g. a feature that gained its migration marker), keep the rest. The survivors carry forward to lead the next handoff / final report, so nothing flagged is lost across resumes.
- **Gate on milestones.** Don't fan out until the log shows the support foundation *built & stable* (if the prior session never reached that, finish the foundation first). Run **Phase 6** (support consolidation, verification, CI, teardown) only once **features-todo hits zero** — so it naturally happens only in the last session.
- **Idempotent.** Resuming an already-finished migration finds nothing todo and goes straight to Phase 6 onward (or reports it's done) — it never re-migrates.


## Additional resources: read the app's own bundled gems

When a step, matcher, or factory-prose variation isn't obvious, read the **source of the gems the target app bundles** — Spreewald, Capybara, capybara-lockstep, cucumber_factory / FactoryBot / Machinist, rspec-rails. Get a gem's path with `bundle show <gem>` (run inside the target repo) and read or grep there:

```bash
bundle show spreewald         # → …/gems/spreewald-x.y.z ; read lib/spreewald/*_steps.rb and lib/spreewald_support/*
bundle show capybara          # confirm a Capybara API (you already know most of it from training)
bundle show cucumber_factory  # its README is the authoritative list of factory-prose variations
```

Reading the app's **own** bundled versions is deliberate: you map each step exactly as it behaves in the version the app runs. **Don't read it all up front** — it would exceed your context; reach for `bundle show` + a targeted grep only when something is unclear. The step→Capybara and factory-prose mappings are already worked out in `spreewald-guide.md` and `cucumber_factory-guide.md` (your first stop), and house style lives in `conversion-guide.md`; the gem source is a backstop for edge cases and internal helpers. And **some helpers a step relies on are defined by the *app itself*** — a custom `paths.rb`/`selectors.rb` lookup (e.g. a `find_by_anything!`), a `lib/` or initializer extension — not by any gem; if a helper isn't in Spreewald/Capybara/cucumber_factory, grep the **target repo** for it before assuming it's missing.

**When you need precedent, grep the target repo's *own* code** — `spec/**` for existing specs and helpers, `features/**` for the Cucumber you're converting — never another project's, so a convention from an unrelated app can't leak in.


## The examples in these guides are illustrative only

Every concrete gem, helper, path or selector in these three guides is an **illustration of a technique**, not a statement about the app you're migrating. The examples use **Devise** (`Devise.friendly_token`, `new_user_session_path`) to show how to migrate a tricky piece of auth support code — but your app may use **Clearance** (`new_session_path`, `require 'clearance/rspec'`), or something else entirely. The point of that example is *the migration move*, not Devise.

So: **detect the app's actual gems and conventions** (read its `Gemfile`, `spec/support/`, `features/support/`) and apply the *principle* from the example to whatever the app really uses. Don't assume the app uses a gem just because a guide example did.


# Phase 1 — Preflight checks and environment setup

We can only trust a migrated spec once we've **run** it, and feature specs only run if the *whole* environment matches what the app (and its CI) expect — not just Ruby, but Node, assets, the database, and environment variables like the timezone. Get this right first; otherwise specs fail with errors that look like migration bugs but aren't.

## 1a. Before you start — confirm inputs and ground rules

Confirm these before doing any work; ask the human if anything is unknown:

- **Resume or start fresh?** If a `tmp/mandoline/` directory already exists, a previous migration ran here. **Ask the human immediately — before reading anything inside it:** *"A previous migration was detected — (1) resume where it left off, or (2) start from scratch?"* Do **not** read `tmp/mandoline/`'s contents before asking; on "start from scratch" that would just pollute your context with stale state you're about to delete.
  - **Resume (1):** leave `tmp/mandoline/` in place; **now** read `progress.md` (and the other scratch files) to reconstruct prior progress, and skip already-completed phases and features (see *Resume & session budget*).
  - **Scratch (2):** `rm -rf tmp/mandoline` and start clean — without having read any of it.
  - No `tmp/mandoline/` directory → it's a fresh run; don't ask.
- **Session time budget.** Ask how many hours the human wants to spend **this session** (they may answer "no limit"). Record it; you'll stop cleanly and hand off when the budget runs low (see *Resume & session budget*).
- **Parallelism is automatic — don't ask.** Feature migration fans out to **up to 4 workers**, and the orchestrator throttles that down (4→3→2→1→0) as the 5-hour quota window fills, riding out each limit and resuming on its own (see *Parallelism → The job queue*). With no `parallel_tests` it runs serially. There's nothing for the human to choose here.
- **Scope — which features to migrate?** Ask the human (default **all**):
  - **All unmigrated features (default)** — migrate every not-yet-done feature, in any order.
  - **A named scope** — the human names paths/folders under `features/` (e.g. a top-level module like `frontend`/`backend`/`mobile_app`, or specific `.feature` files); migrate only those.
  - Scope affects **only which features the workers batch** — you **always migrate the full support code** (or skip it if a resumed session already did).
- **The migration otherwise runs unattended** — there is no interactivity mode to pick. After these startup questions you never pause for review; you stop only on a hard blocker you can't resolve, or when the session budget or context runs low (quota is paced and ridden out automatically — see *Parallelism*). **Never ask the human about quota or budget — at any point, including at a phase boundary.** Low quota when entering *any* phase (fan-out, review, verification) means **wait for the window and proceed**, never "should I start?". The only interactive moments in the entire run are these Phase 1a startup questions.
- **The path to the repo we're migrating** (the INPUT). You must launch from *inside that repo*, **not** from the `mandoline` folder that holds these guides.
- **The path to `mandoline`** (these guides). It should have been added via `--add-dir` (or similar) so you can read it.
- **Warn the human up front** that this migration burns a lot of tokens; a premium Claude Code seat (Opus with high effort) is recommended.
- **Sanity-check the workspace:**
  - The repo we're migrating has **no uncommitted changes** (so the migration is reviewable as a clean diff).
  - You can read `mandoline`'s guides (it was passed via `--add-dir`), and `bundle show spreewald` (or the app's equivalent test gems) resolves from inside the target repo — that's where you read gem source, so there's nothing else to check out.
  - **`tmp/mandoline/` is handled by the resume question above** — cleared only if the human chose "start from scratch", kept intact on a resume.
  - **Record this session's start time** for elapsed reporting and the budget check: `date +%s > tmp/mandoline/session-start.md`. **Overwrite it every session** (fresh *or* resumed) — elapsed and budget always refer to the *current* session, not the whole migration.

## 1b. Set up the toolchain

Replicate what the app needs to boot and what its **CI** sets — not just Ruby/gems. Check the app's CI config (`.gitlab-ci.yml`, `.github/workflows/*.yml`) and `README` for required versions and environment variables.

> **Don't install or switch Ruby/Node versions yourself.** There are too many version managers (rbenv, rvm, asdf, chruby, mise; nvm, fnm, volta, …) to drive reliably. **Activation is already handled** — the human starts by `cd`-ing into the migrating repo before opening Claude, so their shell config auto-activates the versions pinned by `.ruby-version` / `.nvmrc`. Your job is only to **verify** that activation happened. If the active version is wrong, the required one most likely **isn't installed** — stop and ask the human to install it, then continue. Never install it yourself.

> **Scope — assume a runnable project; don't set it up.** The human hands you an app whose test suite already runs: gems installed, dev/test databases created and migrated, any **required background services running and reachable** (Redis, OpenSearch, a queue — on the ports the app expects, which may be non-standard), and — if the app uses `parallel_tests` — all the parallel test DBs mandoline uses (up to 4) created and migrated. **Never install system packages (never `sudo`), and never create or migrate databases.** The one setup step you *do* perform is **building the frontend** (below), since Selenium needs real assets. If something the suite needs is missing — a pending migration, an absent DB, a system binary the app shells out to — **flag it for the human and move on; don't fix it** (see the *missing dependency* rule in `conversion-guide.md`). **You may *start* a required service only if (a) it isn't already running *and* (b) the repo documents how — a `Procfile.dev` entry or an explicit README run-step; never install one and never invent a setup.** A required service that's down and undocumented is an environment problem to **escalate to the human**, not to fix or start yourself — you may *check* whether it's up, but never install or boot it (you'd orphan a stray process and produce non-reproducible state). If the gap **blocks the whole suite** (e.g. a Redis every spec flushes), the run can't meaningfully proceed until the human fixes the environment — **escalate it prominently and stop**, rather than starting your own copy or grinding on with nothing to do. And **workers never boot or install anything** (see the fan-out-worker rules in `conversion-guide.md`).
>
> **Assume the suite runs on the host** (`bundle exec rspec`). Use a container wrapper (`docker compose run …`) **only if the human or README explicitly says the suite runs that way** — a `docker-compose.yml` / `bin/docker` in the repo is usually just the database (via `bin/dev`) or CI, and **CI always containerises even when local dev doesn't**, so never infer "the suite runs in Docker" from CI config or an incidental docker trace. If the suite genuinely runs in a container, find out what docker is actually for, put the full command prefix in the worker brief, and pass `TEST_ENV_NUMBER` **into** the container (a docker `-e` flag), not as a host shell variable — but only when docker runs the test commands.

> **Always run commands with `DISABLE_SPRING=1`.** Spring is a persistent source of confusion in Rails apps: it keeps a booted process resident and **caches the first connection**, so after you change code or switch `TEST_ENV_NUMBER` it silently serves *stale* behavior — a spec picks up an old version of the app, or a parallel-DB check via `rails runner` reports every env on the same DB even though `database.yml` suffixes them correctly. Prefix **every** command that boots Rails — `bundle exec rspec`, `rails runner`, `rake`, `rails …` — with `DISABLE_SPRING=1` for the whole migration (e.g. `DISABLE_SPRING=1 bundle exec rspec …`). Tell the workers to do the same. To clear a resident Spring entirely, see <https://makandracards.com/makandra/495838-rails-kill-spring-fire>.

1. **Ruby.** Verify the active Ruby matches `.ruby-version`:

   ```bash
   cat .ruby-version
   ruby --version          # must match .ruby-version
   ```

   If it doesn't match, the pinned Ruby probably isn't installed — ask the human to install it (their shell will then auto-activate it). Don't install it yourself.

2. **Gems.** Install the app's gems:

   ```bash
   bundle install           # if it complains the Bundler version is missing, ask the human to install that Bundler
   ```

   Then **detect the RSpec generation — it decides which guide you follow** (don't abort on an old stack; there's a playbook for it). Read the version with `bundle info` (not by grepping code or loading gem paths):

   ```bash
   bundle info rspec-rails     # e.g. "rspec-rails (5.1.2)" (modern) or "rspec-rails (1.3.4)" (RSpec 1)
   ```

   - **Modern RSpec (the common case)** — `rspec-rails ≥ 2.14` (feature specs arrived in 2.14.0; `expect` syntax is present). Proceed with this guide as written, and **do not read `rails2-guide.md`** — it would mislead a modern migration.
   - **Rails 2 / RSpec 1** — `rspec-rails` at **1.x** (Rails LTS 2.3, sometimes on Ruby 2.5+; RSpec 1 also ships a single `rspec` gem — `bundle info rspec` → `1.x`). RSpec 1 has no `feature`/`scenario` and no `expect` syntax, and you **can't** upgrade without leaving Rails 2. **Read `rails2-guide.md` now and follow it throughout.** It emulates feature specs on RSpec 1 and **overrides** the RSpec-specific parts of this guide and `conversion-guide.md` (the `feature`/`scenario` DSL, `expect`, `RSpec.configure`, metadata-filtered hooks); everything else here still applies. Don't abort, and don't try to upgrade the test stack.

3. **Database — assume it's ready; don't create or migrate it.** Per *scope* above, the human has already migrated the dev/test databases and, if the app uses `parallel_tests`, created + migrated all the parallel test DBs mandoline uses (up to 4 — the top of the quota taper). **Don't run `db:migrate`, `parallel:create`, or `parallel:prepare` yourself.** If a spec later errors on a pending migration or a missing `TEST_ENV_NUMBER` database, that's a project-setup gap — flag it for the human, don't fix it. (No `parallel_tests` → the migration runs serially; see *Parallelism*.)

4. **Node + frontend assets (don't skip this for modern apps).** Selenium feature specs render the *real* frontend, so JS/CSS assets must be built — otherwise specs fail with confusing errors like `PrecompiledAssets::Manifest::NotFound` that look unrelated to the migration.
   - Verify the active Node matches the app's `.nvmrc`:

     ```bash
     cat .nvmrc
     node --version          # must match .nvmrc
     ```

     If it doesn't match, the pinned Node probably isn't installed — ask the human to install it (their shell will then auto-activate it); don't install it yourself. A wrong Node version makes the `pnpm`/`corepack`/`esbuild` toolchain crash with opaque errors (e.g. "Invalid host defined options").
   - Install JS packages with whatever the app uses (`npm`/`yarn`/`pnpm` — look for the lockfile).
   - **Build the frontend.** Find the build command in `README.md`, `Procfile.dev`, or the `package.json` scripts (fallback: `RAILS_ENV=test bundle exec rake assets:precompile`). **Exception:** apps on **Sprockets** build automatically on render and need no pre-build; JS-bundled apps (esbuild/webpacker/jsbundling) do need a build.
   - **Note — the app may already auto-compile assets in a test hook.** Some apps wire a compile step into a test hook rather than relying on a manual build: a Cucumber `Before` hook (in `features/support`) for feature tests, or an RSpec hook scoped to request/system specs. If such a hook already covers the specs that need assets, no manual build is needed for them — and during the migration you don't add a separate `before(:suite)` compile: you **extend the existing hook to also cover `type: :feature`** (see the Phase 3 audit). A Cucumber-side compile hook is migrated like any other support code, scoped to `:feature`.

5. **Set the test process's timezone to match your dev/CI zone** (`$TZ`; headless Chrome inherits it). Symptom of a mismatch: "your time" / relative-time assertions off by a **fixed offset** (e.g. exactly one hour). **Shell state does not persist between tool calls in this harness**, so an `export TZ=…` in one command is gone by the next — verify the *system* zone instead, and if it doesn't match CI, prefix `TZ=…` on every Rails-booting command (exactly as you already do with `DISABLE_SPRING=1`):

   Also **check `config.active_record.default_timezone` and `time_zone_aware_attributes`** now, and note the result in the worker-brief gotchas. If the app sets `default_timezone = :local` with `time_zone_aware_attributes = false` (common in older makandra apps), wall-clock time-travel must parse **system-local** (`Time.parse`), **not** `Time.zone.parse`, or displayed times are off by the UTC offset — the `spreewald-guide.md` `parse_time` helper already does this, but detecting it up front saves a worker rediscovering it mid-migration. Rails time zones + ActiveRecord are genuinely confusing; if a time bug resists the usual fixes, read <https://makandracards.com/makandra/46009-working-time-zones-rails-applications>.

   ```bash
   cat /etc/timezone            # (or: timedatectl) — confirm it matches what .gitlab-ci.yml sets
   # If it matches, nothing to do. If not, DON'T `export` (it won't persist) — prefix each command:
   #   TZ='Europe/Berlin' DISABLE_SPRING=1 bundle exec rspec …
   ```

6. **Sanity-check** that RSpec runs at all:

   ```bash
   bundle exec rspec --version
   ```

From here on, always run specs through `bundle exec` so you get the app's pinned gem versions, and verify each migrated scenario as you go (see *Work scenario for scenario* in `conversion-guide.md`).

> If a JavaScript (Selenium) spec later fails because Chromedriver doesn't match the installed Chrome, fetch a matching driver — see *Verifying the setup* below.


# Phase 2 — Internalise the house style

The style your migrated specs must match is documented **statically** in **`conversion-guide.md`** (the *House style* section): skeleton, rhythm, expectations, helper/selector conventions, the deliberate deviations from the reference apps, and annotated examples. **Read it now** — you do not need to study the reference apps to rediscover the style.

`conversion-guide.md` is the single source of craft that you (the orchestrator) and every fan-out worker follow. For anything it doesn't cover, fall back to the target app's own already-migrated `spec/features/**` and its existing `spec/support/` for precedent — plus the mappings in `spreewald-guide.md` / `cucumber_factory-guide.md` — never another project's code.

# Phase 3 — Converting support code

Phase 3 has two parts: **3a** gets RSpec itself ready to drive a browser, and **3b** mechanically transforms the Cucumber support files and step-definition hooks into RSpec support files.

## 3a. Configure RSpec for feature specs

> **Watch for CI-only failure classes — a green *local* run does not prove a green *CI* run.** Feature-spec migrations reliably produce failures the local verification this guide prescribes **cannot** surface, because CI drives a *real remote* browser, *blocks the network* by default, and *merges feature + unit specs into one random-order process* — none of which a local single-file run reproduces. Each class below tends to fail *many* specs at once, so fix it **proactively** during setup, not reactively after a red CI run:
> 1. **A global net-blocker blocks the remote WebDriver host.** With a remote browser (a Selenium/Chrome container reached via `CHROMEDRIVER_URL`), every WebDriver command is a Ruby HTTP call through WebMock/VCR — allow the *driver host*, not just `/__identify__` (see *Global net-blockers* below).
> 2. **A feature spec leaks a mutated global into a later unit/model spec** once both suites share one rspec process — extend any `:request`-scoped (or other-type) save/restore-global hook to `:feature` too (see the audit's *item 2* below).
> 3. **A background poller errors during teardown** and trips a per-scenario JS-error check, failing an *unrelated* scenario (only when the app has such a poller + JS-error check). Two fixes: **(1)** disable the polling by default in the test env and opt only the scenarios that actually exercise it back in — good practice regardless; or **(2)** as a blanket stability measure, wait out pending AJAX before teardown ([makandra card 32001](https://makandracards.com/makandra/32001-capybara-waiting-pending-ajax-requests-test)). See *Migration gotchas* in `conversion-guide.md`.
>
> The through-line: **local green is necessary but not sufficient** — apply these fixes **up front**, because nothing in your local run will reveal that they're needed.

### First: audit what `spec/support/` already provides — migrate only the gaps

The target app already ran RSpec for unit/model/controller specs, so `spec/support/` is **not empty**, and some of it already applies to feature specs. Before migrating anything from `features/support/`, read the existing `spec/support/` tree — you'll often find working `database_cleaner.rb`, `factory_bot.rb`, `action_mailer.rb`, `webmock.rb`, an auth helper (Devise/Clearance), an `allow_rescue` hook, payment/stub teardown, even an asset-compile hook.

**Never duplicate config that already exists** — two DatabaseCleaner strategies or double-cleared deliveries cause conflicts you won't catch until the full run. **And an existing DatabaseCleaner is not automatically safe for JS specs:** if it selects the strategy in a `before` hook (`config.before(js: true) { DatabaseCleaner.strategy = :deletion }`) but calls `start` in an `around`, RSpec runs the `around` *outside* the `before`, so `start` always uses the *previous* example's strategy (usually `:transaction`) — every `js: true` example then builds its data in an uncommitted transaction the Capybara server (a separate connection) can't see. The symptom looks nothing like a DB bug: `login_as` works for the first request (Warden holds the user in memory), then the *second* request can't restore the session and the spec lands on the sign-in page. So don't "skip it because DatabaseCleaner exists" — verify the strategy is chosen **inside the same `around` that calls `start`** (outside-in relative to `start`). For each `features/support/*.rb`, decide:

1. **Equivalent exists and already covers feature specs** → skip it.
2. **Exists but scoped to other spec types** → extend its scope to `type: :feature`; don't add a parallel hook. (E.g. add `:feature` to an existing asset-compile hook rather than bolting on a `before(:suite)` compile.) **This especially covers an existing hook that saves-and-restores a global** — `ActionMailer::Base.default_url_options`, `Time.zone`, `I18n.locale`, a class attribute, `RequestStore[...]` — often scoped to `:request`. **Feature specs are request-driven and mutate the same globals**, so if the restore hook doesn't also cover `:feature`, the mutated value **leaks out of the feature run into later model/unit specs**. This is invisible locally — a feature-only *or* non-feature-only run never interleaves the two (see the Phase-6 verification caveat) — and surfaces only in CI's mixed, random-order run. The `default_url_options[:host] = request.host_with_port` controller concern is a near-universal makandra pattern, so **expect this one specifically**: extend its restore hook to `:feature`.
3. **Similar but not identical** (e.g. a richer `DownloadHelpers` used by request specs) → **unify, never overwrite** — merge both needs into one file serving all callers. Overwriting regresses the specs already depending on it.
4. **A Cucumber tag already has an RSpec metadata hook under a different name** (e.g. `@active_job` ↔ an existing `inline_jobs: true` hook) → reuse that hook **and its key**; the migrated scenario carries the existing key, and you record the tag→key mapping in `step-mapping.md`.
5. **Genuine gap** (Cucumber-only support: Spreewald compat, paths/selectors, mail-link helpers) → migrate it.

(When a sub-guide says "the target `spec/` starts empty," read it as "light on *feature-spec* support" — its inlined source is a fallback for when the app has no such helper; when it does, unify per above.)

**A metadata-scoped `config.include(Mod, tag: true)` can't be narrowed by key — and leaks *into* feature groups that share the tag.** RSpec matches include filters with **any-key** semantics, so `config.include(Mod, snapshots: true, type: :model)` still fires for a `type: :feature` group that carries `snapshots: true` — adding `type:` does **not** exclude features (a `before(:each, type: :model)` hook *does*; this doesn't behave like one). So if a migrated tag collides with a pre-existing include — e.g. the app's `config.include RSpec::Rails::ViewRendering, snapshots: true`, and `@snapshots` scenarios become `snapshots: true` feature specs — the module leaks into every such feature group and its hooks error (`render_views?` on a feature group). Include filters can't express *and*/*not*, so put the condition in **plain Ruby** as a proc filter that reads the group metadata: `config.include RSpec::Rails::ViewRendering, snapshots: ->(_v, meta) { meta[:type] != :feature }` (the proc runs only for groups carrying `snapshots`, and includes the module unless it's a feature group).

**Port the Devise + Warden test setup — a near-universal makandra pattern.** `features/support/` very often has `World(Warden::Test::Helpers)` + `Warden.test_mode!` (which lets `login_as(user)` / `logout` bypass the login form) and an `After { Warden.test_reset! }`. Migrate it as: `config.include Warden::Test::Helpers, type: :feature`, a top-level `Warden.test_mode!` (a load-time registration, like the other Warden hooks — not inside a `before`), and `config.after(:each, type: :feature) { Warden.test_reset! }`. (Devise's own `Devise::Test::IntegrationHelpers` / `sign_in` is the alternative — match whatever the app used.)

### Global mocks (WebMock / VCR): never be stricter than the Cucumber origin

**VCR cassettes — three fidelity traps when the app uses VCR:**
- **Set `record: :none`** in the migrated VCR config (with an env override to re-record). VCR's default `:once` **records silently when a cassette is missing**, so a deleted or renamed cassette turns into a live production call nobody notices.
- **Carry the cassette name when the origin used `use_scenario_name: true`.** Cucumber's `VCR.cucumber_tags { |t| t.tag '@vcr', use_scenario_name: true }` names the cassette `<feature basename>/<Scenario name>`; VCR's `configure_rspec_metadata!` derives it from the example's *full description* instead, which won't match — so map to `scenario 'X', vcr: { cassette_name: '<feature basename>/X' }`, not a bare `vcr: true` (renaming the cassette files loses their git history).
- **Check the cassette actually exists before mapping `@vcr`.** Some were deleted long ago, so the Cucumber scenario has been recording against the real API ever since; a bare `@vcr` mapping would do the same. A missing cassette needs a real fixture or a deliberate `:allow_net_connect` decision, not a silent live call.

This is a predictable, high-frequency failure, so expect it. The base RSpec suite — shared with unit/request specs — usually enforces `WebMock.disable_net_connect!(allow_localhost: true)` (and/or VCR) globally. **Cucumber feature suites frequently loaded no such thing**, so real outbound calls (Stripe, geocoders, an OAuth endpoint, …) worked fine for the author. Migrating a feature into the RSpec suite drops it into the stricter regime, and it fails on a blocked connection — e.g. `POST https://api.stripe.com/... blocked by WebMock`.

**It's not only the *network* that's stricter — look for global "make it cheap" switches too.** The same "RSpec support set does something Cucumber's didn't" trap covers speed optimizations: `CarrierWave.enable_processing = false` in a `before(:suite)`, jobs not running inline (ActiveJob/Sidekiq test mode), disabled image/PDF/thumbnail generation. These fail **silently and only at the assertion** — the work simply never ran — so a scenario asserting on the *produced artifact* (pixels, a generated file, an indexed record) fails even though its stub/tag was ported faithfully. Grep pre-existing `spec/support/**` for `enable_processing`, `perform_enqueued_jobs` / inline-job config, and similar switches, and note which tags/scenarios must opt back *out* of them.

This is **not** a missing dependency and **not** a reason to skip, exclude, or invent a "needs real X" tag the origin lacked (see *The contract: parity, not improvement*). Fix it, in order:

1. **Supply/migrate the stub** if the Cucumber suite had one and it's easy to carry over.
2. **Otherwise opt that scenario out of the global block per-example** and tag it `:allow_net_connect`. The mechanism lives in the canonical `spec/support/webmock.rb` in *Global net-blockers … block `GET /__identify__`* below — its `around` hook lifts the block for the tagged example and **restores the exact same blocking config afterwards** (the shared `block_net_connect` lambda, **never** bare `disable_net_connect!(allow_localhost: true)`: restoring the wrong config silently re-breaks `/__identify__` on CI for every later JS spec — see that section). Tagging follows CI parity: if Cucumber CI excluded the scenario (`--tags 'not @X'`), keep an equivalent metadata symbol so RSpec CI excludes it too (see tag rules #9 in `spreewald-guide.md` and the *Tag-parity audit* in Phase 6); if the origin did *not* tag it, it stays un-excluded and runs in CI as before. Hitting a real sandbox (e.g. a payment provider's test API) is acceptable when that is exactly what Cucumber did.
3. **If verification is still hard, READ THE CUCUMBER ORIGIN** (`features/**`, `features/support/**`) to see how it actually worked — don't invent a stricter approach.

### Global net-blockers (WebMock *or* VCR) block `GET /__identify__` — always allow that path

**Whenever the base suite globally blocks real HTTP** — WebMock's `disable_net_connect!`, or VCR with `allow_http_connections_when_no_cassette = false` — **you MUST always allow Capybara's server health-check, or every `js: true` spec fails.** Capybara boots its own app server and verifies it with one request, `GET /__identify__`; the global blocker rejects it (WebMock: `WebMock::NetConnectNotAllowedError: … GET http://<host>:<port>/__identify__`; VCR: `VCR::Errors::UnhandledHTTPRequestError`, which often surfaces as a confusing *secondary* `undefined method 'values_at' for nil` in the DatabaseCleaner around-hook).

> **With VCR `hook_into :webmock`, don't trust `WebMock.net_connect_allowed?`** — VCR overrides it to return `true` whenever a cassette context is active, so a smoke-check or guard that reads it will *always* look permissive. Read `WebMock::Config.instance.allow_net_connect` for the real setting (and remember it's **VCR**, not WebMock, that raises the blocked-request error). A **local** chromedriver on `localhost` is likewise intercepted by VCR unless `ignore_localhost = true`.

> **⚠️ This is a CI-ONLY failure — a green local run is NOT evidence you've handled it.** Locally Capybara binds its server to `127.0.0.1`, which `allow_localhost: true` (WebMock) / `ignore_localhost` (VCR) already permits, so it passes. On CI the browser is remote/dockerized, so `spec/support/selenium.rb` sets `Capybara.server_host` to the **container's own IP** (e.g. `172.17.0.3`, via `hostname -i`) so the browser can reach the server — and `allow_localhost` does **not** cover that IP, so `/__identify__` is blocked and hundreds of JS specs fail. Because you can't see this locally, **apply the fix proactively during this Phase-3a audit**, never in response to a failure you won't witness.

**Allow the `/__identify__` *path*, host-agnostically — not the host.** Matching the path is strictly better than allowing `Capybara.server_host`: it's the **only** Ruby-level request Capybara makes to its *app* server — the browser's own page loads don't pass through WebMock/VCR (true for a **local** driver; a **remote** driver adds WebDriver traffic that does — see the next paragraph), it needs no coupling to `Capybara.server_host` (which may be unset, `nil`, or differ from the bound host), and it keeps blocking every real external call.

**On CI with a *remote* browser, the WebDriver host must be allowed too — this is the single biggest remote-Selenium CI failure.** The `/__identify__` allowance covers the *app* server, assuming the browser reaches it directly. But when CI drives a **remote** Chrome — a `chrome:4444` service reached via **`CHROMEDRIVER_URL`**, common in containerized CI — Selenium sends **every** WebDriver command as a Ruby `Net::HTTP` request *through WebMock*, starting with `POST http://chrome:4444/session` to create the browser session. `allow_localhost` doesn't cover that host, so **every `js: true` spec fails at session creation** on CI — and a local run (local chromedriver on `localhost`) passes, hiding it. So the canonical file also allows the remote WebDriver host, derived from the same env var your `selenium.rb` uses to register the driver.

**Always amend the app's existing `spec/support/webmock.rb`** (or `vcr.rb`) rather than adding a competing file. That file was written for model/controller specs that run **no browser**, so it never needed this — migrating feature specs into the same suite is exactly what first exposes it. The canonical WebMock setup, which also folds in the per-scenario real-network opt-out from *Global mocks* above (one shared lambda, so the opt-out restores the **same** config):

```ruby
# spec/support/webmock.rb
require 'webmock/rspec'

RSpec.configure do |config|
  # Hosts Selenium's WebDriver talks to. With a LOCAL driver this is nil (localhost,
  # already allowed by allow_localhost); on CI a REMOTE Chrome is reached via
  # CHROMEDRIVER_URL, and EVERY WebDriver command is a Ruby Net::HTTP call through
  # WebMock — so the driver host must be allowed, or js specs die at `POST …/session`.
  driver_url  = ENV['CHROMEDRIVER_URL'] || ENV['SELENIUM_REMOTE_URL']   # match your selenium.rb
  driver_host = driver_url && URI(driver_url).host

  # Block real HTTP by default, but ALWAYS allow (a) Capybara's `GET /__identify__`
  # health-check (match the PATH — on CI the app server binds the container IP, not
  # localhost) and (b) the remote WebDriver host. Both are CI-ONLY failures a green
  # local run won't reveal.
  block_net_connect = lambda do
    WebMock.disable_net_connect!(
      allow_localhost: true,
      allow: ->(uri) { uri.path == '/__identify__' || (driver_host && uri.host == driver_host) },
    )
  end
  block_net_connect.call

  # Per-scenario opt-out for scenarios that legitimately need real external calls (see *Global mocks*).
  # Restore via the SAME lambda afterwards — NOT bare disable_net_connect!(allow_localhost: true),
  # or the next JS spec re-hits the blocked `/__identify__` (or WebDriver-host) failure on CI.
  config.around(:each) do |example|
    next example.run unless example.metadata[:allow_net_connect]

    WebMock.allow_net_connect!
    begin
      example.run
    ensure
      block_net_connect.call
    end
  end
end
```

**VCR equivalent** — VCR hooks in ahead of WebMock (`hook_into :webmock`) and applies its own ignore list, so WebMock's `disable_net_connect!` alone won't save you. Ignore the same path (and carry over any `ignore_hosts` the Cucumber-only `features/support/vcr.rb` had):

```ruby
# spec/support/vcr.rb
VCR.configure do |c|
  c.ignore_request { |request| URI(request.uri).path == '/__identify__' }
  # …plus any ignore_hosts the Cucumber config had
end
```

**Meta-lesson for the Phase-3a audit — detect this by the *mechanism*, not the gem name.** Grep `spec/support` **and `spec_helper.rb` / `rails_helper.rb`** for **any** global net-blocker (`disable_net_connect!`, `allow_http_connections_when_no_cassette`, a `VCR.configure`) and apply the `/__identify__` allowance regardless of which gem enforces it. **A bare `require 'webmock/rspec'` is itself enough** — it enables WebMock and blocks *all* real connections (including localhost) via its own `before(:suite)`, with **no explicit `disable_net_connect!` to grep for**. So grep for the **`require`**, not just the config call: the block can be on with nothing in `spec/support` naming it. "No VCR → skip" is the trap that shipped this bug: the app used WebMock, not VCR, so a pattern-match on the tool name missed the shared mechanism. **And net-blocking only covers HTTP:** a validator or service that does **real DNS/MX lookups** (an email-domain validator is the classic case) or opens a raw socket bypasses WebMock/VCR entirely and quietly depends on live network + third-party records. Grep for `Resolv`, `Socket`, and `Net::` (outside your HTTP client) near this audit; such specs need stubbing or a tag, not a net-blocker. And more broadly: **local green is necessary but not sufficient** — this, and the container-IP server binding, are only observable in a real CI run, which is exactly why the Phase-6 *Validate in real CI* step (drive the MR + CI to green when the remote is controllable, else recommend it) is mandatory, not optional.

### A dedicated `cucumber` Rails environment folds into `test`

Some legacy apps run Cucumber under its **own Rails environment** called `cucumber` (common on old Rails-2 apps), distinct from `test`. RSpec feature specs run under the **`test`** environment, so after migration there is no `cucumber` environment to run in.

> **A `config/environments/cucumber.rb` file alone is a false positive — confirm the env is actually *used* before folding it in.** Apps routinely keep a dead `cucumber.rb` long after they stopped using it. It's only live if Cucumber actually booted under it: check that **`cucumber.yml` (or the CI cucumber job) sets `RAILS_ENV=cucumber`** (not `test`), **and** that `config/database.yml` has a **`cucumber:` entry**. If those say `test` (or are absent/empty — e.g. an empty `cucumber.yml`), the `cucumber` env is dead: treat the app as a normal `test`-env app and skip the rest of this section.

Therefore:

- **Diff `config/environments/cucumber.rb` against `config/environments/test.rb`** and **port any settings the feature suite relies on into `test.rb`** — otherwise migrated specs run under a `test` env that lacks what the `cucumber` env provided. Common culprits: `config.action_controller.allow_forgery_protection`, `config.action_dispatch.show_exceptions` / `config.consider_all_requests_local` (how errors render), `config.action_mailer.*`, asset/`public_file_server` settings, eager loading, and `config.cache_classes`/`action_view.cache_template_loading`. Only port what differs and what E2E actually needs; don't blindly copy.
- The `cucumber` **database** is likewise replaced by the `test` database — the *test* DB must be at the current schema (the human's setup, per *Phase 1 → scope*); if a spec errors on a pending migration, flag it rather than migrating yourself.
- Don't delete `config/environments/cucumber.rb` or the `cucumber:` database entry yet — that's part of the Phase 6 teardown (the human removes it after reviewing the migration).

### Rails UJS `data-method` links need `respect_data_method: true` on the rack-test driver

For non-JS (rack-test) scenarios to exercise Rails UJS `data-method` links (`data-method="delete"`, `"patch"`, …) **at all**, register the rack_test driver with **`respect_data_method: true`**. Capybara's default is `false`, so otherwise it follows such a link as a plain **GET** — the delete/patch silently never happens and the spec stays **green while losing coverage**. (cucumber-rails enabled this emulation; RSpec doesn't.) **But `respect_data_method` only synthesizes the form — it does *not* inject the CSRF token that cucumber-rails' emulation did**, so on an app with `allow_forgery_protection` on you must also handle forgery (next section).

### Forgery protection (CSRF) — make it toggleable, default to what Cucumber used

If the app's `test.rb` enables `allow_forgery_protection`, a **non-JS** scenario that deletes/patches via a Rails UJS `data-method` link fails with `ActionController::InvalidAuthenticityToken` — the form `respect_data_method` synthesizes carries **no CSRF token** (JS scenarios are fine; real UJS attaches it). Don't read this as "Cucumber just ran with forgery off": for a forgery-**on** app, cucumber-rails' own emulation (`cucumber/rails/capybara/javascript_emulation.rb`) **injected the CSRF token** into its synthesized form, so those scenarios passed under Cucumber *precisely because of* that injection — a behaviour `respect_data_method` does not reproduce. So enabling `respect_data_method` **requires defaulting `allow_forgery_protection` off** in the test env (a deliberate, sanctioned loosening: the observable behaviour — the link performs its non-GET request — is preserved), toggling it back on only for the few specs that specifically test CSRF.

Add a metadata-toggleable hook (the support file below is the model). **When you use `respect_data_method`, default the hook to forgery *off*** (it can't inject the token cucumber-rails did, so a forgery-on default re-breaks every `data-method` spec); read the app's `cucumber` env only to confirm which scenarios genuinely tested CSRF. Those opt back in with metadata:

```ruby
# spec/support/csrf_protection.rb
RSpec.configure do |config|
  config.around(:each, type: :feature) do |example|
    previous = ActionController::Base.allow_forgery_protection
    # Default = the Cucumber suite's effective default (usually false); opt in per example.
    ActionController::Base.allow_forgery_protection = example.metadata.fetch(:forgery_protection, false)
    example.run
    ActionController::Base.allow_forgery_protection = previous
  end
end
```

### `allow_rescue` — errors bubble by default; opt in to test error pages

By default, let application exceptions **bubble up** — a failing scenario should show the real stack trace, not the app's rendered 500 page. Specs that test the error pages themselves (404/500/422) need the app to rescue and render them, so make rescuing **opt-in** via metadata (mirrors Cucumber's `@allow-rescue` tag):

```ruby
# spec/support/allow_rescue.rb — only tagged specs let the app rescue & render its error page.
RSpec.configure do |config|
  config.around(:each, :allow_rescue, type: :feature) do |example|
    env = Rails.application.env_config
    show_exceptions = env['action_dispatch.show_exceptions']
    show_detailed   = env['action_dispatch.show_detailed_exceptions']

    env['action_dispatch.show_exceptions'] = :all            # rescue and render an error page (value is Rails-version-specific; mirror the app's own allow_rescue.rb)
    env['action_dispatch.show_detailed_exceptions'] = false  # ...the app's custom page, not Rails' debug page

    example.run

    env['action_dispatch.show_exceptions'] = show_exceptions
    env['action_dispatch.show_detailed_exceptions'] = show_detailed
  end
end
```

**Toggle *both* keys.** `show_exceptions` alone still renders Rails' *debug* exception page in the test env (where `show_detailed_exceptions` is on), so a "custom 404/500 page" scenario would fail — setting `show_detailed_exceptions = false` is what makes the app's own error page render.

Untagged specs are unaffected (they keep `test.rb`'s default) — don't add an *unconditional* hook that makes errors bubble; you usually only need this tagged one. A spec that renders an error page then declares `scenario '404 page', :allow_rescue do … end`.

### Core RSpec is already configured

The core RSpec library is already configured in our target apps, as we have always used RSpec for model specs, controller specs, etc. We only used Cucumber for E2E tests.

Factories / blueprints for sample data are also already in the `spec` folders, usually in `spec/factories.rb` or `spec/factories/*.rb`.


### Support file load order

Cucumber starts by loading `features/support/env.rb`, then loads all files in `features/support/**.rb`.

Our RSpec config should start by loading `spec/spec_helper.rb`, then loads all files in `spec/support/**.rb`.
Make sure our `spec_helper.rb` has the code that loads the other support files:

```ruby
Dir[Rails.root.join("spec/support/**/*.rb")].sort.each {|f| require f}
```

Our projects do not use the `rails_helper.rb` vs. `spec_helper.rb` distinction, we only have `spec_helper.rb`.

**Don't rely on load order for hook ordering.** Real apps often glob support files **unsorted** (`Rails.root.glob('spec/support/**/*.rb').each` — no `.sort`), so which file's hooks register first isn't predictable. When the *relative order* of two `after`/`around` hooks matters (e.g. the JS-request drain must run before `DatabaseCleaner.clean` — see Phase 3a), **put both hooks in the same file** so their registration order pins them, instead of depending on which file loads first.

**In `spec_helper.rb`, set `config.infer_spec_type_from_file_location!`.** It gives specs under `spec/features/` their `type: :feature` metadata — which every `before(:each, type: :feature)` hook and `config.include(…, type: :feature)` in this guide depends on. Without it, those hooks and includes silently never apply:

```ruby
RSpec.configure do |config|
  config.infer_spec_type_from_file_location!
end
```


### Support file organization

We prefer to only have a minimal `spec_helper.rb`.
Additional tool configuration should go into a dedicated support file.
Use one support file per tool, topic, matcher, helper group. Examples for illustration only:

```
spec/support/database_cleaner.rb
spec/support/devise.rb
spec/support/factory_bot.rb
spec/support/vcr.rb
spec/support/matchers/be_allowed_access.rb
spec/support/matchers/be_denied_access.rb
spec/support/matchers/be_same_second_as.rb
```


### Setting RSpec up for feature specs

Because we only used RSpec for unit tests so far, we need to configure RSpec feature specs to automate browser interactions with Capybara and Selenium (headless Chrome). Capybara has already been configured in the Cucumber support files, and we can migrate these settings to RSpec.

Make sure this is in our `spec_helper.rb`:

```ruby
require 'capybara/rspec'
require 'selenium/webdriver'
```

Capybara configuration is often found in `features/support/capybara.rb`. If found, copy that to `spec/support/capybara.rb`.

If you see `features/support/env.rb` requiring other test-related gems, also migrate them to `spec_helper.rb`. Some examples:

```ruby
require 'capybara-screenshot/rspec'
require 'webmock/rspec'
```

Do **not** migrate any `require` statements already required by RSpec support code.

Do **not** migrate any `require` statements for Cucumber and cucumber-related libraries, such as:

```ruby
require 'cucumber/rails' # ❌ Do not migrate Cucumber-related require
require 'cucumber/rspec/doubles' # ❌ Do not migrate Cucumber-related require
require 'spreewald/all_steps' # ❌ Do not migrate Cucumber-related require
require 'cucumber_factory/add_steps' # ❌ Do not migrate Cucumber-related require
```


### Understanding @javascript and js: true

Cucumber's `@javascript` tag opts a scenario into the JavaScript driver (Selenium/headless Chrome); untagged scenarios use the faster rack-test driver. The RSpec equivalent is `js: true` metadata. So a `@javascript` scenario becomes a `js: true` scenario:

Example INPUT:

```cucumber
@javascript
Scenario: Visiting a page that requires JavaScript
  When I go to a page with JavaScript
```

Example OUTPUT:

```ruby
scenario 'Visiting a page that requires JavaScript', js: true do
  visit '/page-with-javascript'
end
```

A `@javascript` tag on the `Feature` itself → put `js: true` on the `feature do ... end` block.

Example INPUT:

```cucumber
@javascript
Feature: Many JS scenarios
  Scenario: ...
  Scenario: ...
```

Example OUTPUT:

```ruby
feature 'Many JS scenarios', js: true do
  scenario '...'
  scenario '...'
end
```

**Drop Cucumber's driver-switching `Before` hooks — don't migrate them.** Cucumber suites often set the driver imperatively, e.g. `Before { Capybara.current_driver = :rack_test }` and `Before('@javascript') { Capybara.current_driver = Capybara.javascript_driver }`. In RSpec these are **unnecessary and actively wrong to port**: `capybara/rspec` already picks the driver from `js: true` metadata (rack-test by default, the JS driver when `js: true`). Migrating them into a `before(:each)` would override that and break driver selection. Just delete them (this is a Phase-3b hook you drop, not translate).

**But if the app registers *additional* drivers behind their own tags** — e.g. `@mobile` → a `:mobile_selenium` driver, `@with_unload_confirmation` → a driver that keeps the unload prompt — those *do* need a metadata switch, and it must be a **`before` hook, not `around`**. `capybara/rspec` installs its own `before` that sets `Capybara.current_driver = Capybara.javascript_driver` whenever `js: true` is present, and these tags always co-occur with `@javascript`; an `around(:each, :mobile) { … }` assigns the driver *before* that `before` runs, so it's overwritten and the spec **silently runs on the plain `:selenium` driver while *looking* fine**. Register it as `config.before(:each, :mobile) { Capybara.current_driver = :mobile_selenium }` (after `capybara/rspec` is required — the normal support-glob order guarantees that). Capybara's own `after` already restores via `use_default_driver`, so no manual restore is needed. (A wrong driver is invisible — see the *hook smoke-check spec* in *Verifying the setup*.)

### Verifying the setup

To check if Capybara was configured correctly, make a simple feature spec 

```ruby
# spec/features/capybara_configuration_spec.rb

feature 'Capybara configuration' do

  scenario 'Default driver configured' do
    visit '/'
    expect(page).to have_text(/\S/)
  end

  scenario "JavaScript driver configured", js: true do
    visit "/"
    expect(page.evaluate_script("1 + 1")).to eq(2)
  end

end
```

Call `bundle exec rspec spec/features/capybara_configuration_spec.rb` to see if both examples pass.

**Also smoke-check the migrated *tag hooks* before fanning out.** `capybara_configuration_spec.rb` proves the driver and JS are up, but not that each metadata hook you ported does what it should — a wrong `around`-vs-`before` (see *driver tags*) or a mis-scoped hook is invisible, because the spec still *passes*, just with the wrong behaviour. Add a throwaway spec (delete before shipping) that asserts each hook's observable effect — `Capybara.current_driver` under each driver tag, `Capybara.default_max_wait_time` under `:patiently`, `Rails.application.env_config['action_dispatch.show_exceptions']` / `allow_forgery_protection` under their tags. A handful of examples, and it catches a broken hook before a worker wastes time on it.

We run Selenium tests (JavaScript tests) with headless Chrome (never Firefox or any other browser).
Ensuring a **working, version-matched Chromedriver exists on the machine is the developer's responsibility** — it's part of a functioning dev environment, not something this migration sets up. If a JavaScript test complains that Chromedriver's version doesn't match Chrome's, fetch a matching one however the app's toolchain does it. On a geordi-based stack that's:

```bash
gem install geordi
geordi chromedriver-update
```


## 3b. Transform support files and step-definition hooks

Now convert each `features/support/**` file and step definition into RSpec support files under `spec/support/` (per *Aggregating your output* below). The remaining subsections cover the individual transforms.

### Before and After blocks

When you encounter a `Before` block, transform this into a `before(:each, type: :feature)` directive in the RSpec configuration.

Example INPUT:

```ruby
Before do
  WebMock.reset!
end
```

Example OUTPUT:

```ruby
def reset_webmock
  WebMock.reset!
end

RSpec.configure do |config|
  config.before(:each, type: :feature) do
    reset_webmock
  end
end
```

An `After` block is identical, using `config.after(:each, type: :feature)` instead of `config.before`.

Both `Before` and `After` blocks can have an optional `@tag` as an argument. Convert this into a additional RSpec metadata filters, right after `type: :feature`:

Example INPUT:

```ruby
Before('@patiently') do
  @old_max_wait_time = Capybara.default_max_wait_time
  Capybara.default_max_wait_time = 12
end

After('@patiently') do
  Capybara.default_max_wait_time = @old_max_wait_time
end
```

Example OUTPUT:

```ruby
def increase_capybara_wait_time
  @old_max_wait_time = Capybara.default_max_wait_time
  Capybara.default_max_wait_time = 12
end

def reset_capybara_wait_time
  Capybara.default_max_wait_time = @old_max_wait_time
end

RSpec.configure do |config|
  config.before(:each, type: :feature, patiently: true) do
    increase_capybara_wait_time
  end

  config.after(:each, type: :feature, patiently: true) do
    reset_capybara_wait_time
  end
end
```

**But a tag-scoped hook that *cleans up shared global state* must become unconditional.** The `@patiently` example above is safe because it only adjusts a setting and restores it. Cleanup is different: a `Before('@sidekiq')`/`Around('@sidekiq')` that cleared enqueued jobs must not be ported into a `sidekiq: true` metadata branch, because **tagged and untagged examples share one process**, and a cleanup that only runs for tagged examples lets state leak *into* them from untagged neighbours — and the failure lands on the tagged example, which looks like the tag's fault. So split the translation: keep the **mode switch** metadata-scoped (`Sidekiq::Testing.fake!` for the tagged examples), but register the **cleanup** as an unconditional global `before` (`Sidekiq::Queues.clear_all`). The same applies to any external store the suite touches — search indexes, caches, uploaded files, background-job queues.

#### Compound tag expressions have no metadata equivalent

A single tag maps to a metadata key (above). But Cucumber allows **boolean tag expressions** — `Before('@a or @b')`, `Before('not @javascript')`, or a comma meaning OR (`Before('@a, @b')`). RSpec metadata filters can't express "or"/"not", so **make the hook unconditional (`type: :feature`) and branch inside it on `example.metadata`.** The hook needs the example, so take the block arg:

Example INPUT:

```ruby
Before('@native-field-clearing or not @javascript') do
  Capybara.default_set_options = { clear: :backspace }
end
```

Example OUTPUT:

```ruby
def use_backspace_clearing
  Capybara.default_set_options = { clear: :backspace }
end

RSpec.configure do |config|
  config.before(:each, type: :feature) do |example|
    use_backspace_clearing if example.metadata[:native_field_clearing] || !example.metadata[:js]
  end
end
```

(Map each tag to its metadata key as usual — `@native-field-clearing` → `native_field_clearing`, `@javascript` → `js` — then translate the boolean expression to Ruby: `or`/comma → `||`, `and` → `&&`, `not` → `!`.)

#### No per-step hook (`AfterStep`) — collapse to one per-scenario check

Cucumber has a per-**step** hook, `AfterStep`, that some apps use to assert something after *every* step — most commonly "there should be no JavaScript errors" (often wired as both `AfterStep('@javascript')` *and* `After('@javascript')`). **RSpec has no per-step hook.** Map both to a **single per-scenario** check in `after(:each, type: :feature, js: true)`:

```ruby
RSpec.configure do |config|
  config.after(:each, type: :feature, js: true) do
    expect_no_javascript_errors   # port the app's own check + its ignorable-errors allowlist verbatim
  end
end
```

**Port the app's existing console-error check — its mechanism *and* its app-specific allowlist** of ignorable errors (framework bugs, failed resource loads, autoplay warnings) — verbatim from its `selenium_steps.rb` / equivalent; don't invent one, and **don't impose a stricter check than the app already had.** A stricter check on a suite that never had one unearths a flood of pre-existing console errors nobody ever cared about — a parity/scope blow-up, not a win. Two mechanisms are in the field: a **per-scenario** check (an `after` hook — see [makandra card 55056](https://makandracards.com/makandra/55056-raising-javascript-errors-ruby-e2e-tests-rspec-cucumber); catches essentially all real errors without the per-step runtime cost, marginally less strict since a JS error that appears *and disappears* mid-scenario won't be caught), and the makandra **house standard** `Capybara::Lockstep.after_synchronize { BrowserConsole.assert_no_errors! }`, which checks between Capybara commands. Match whatever the app already uses. If you adopt `after_synchronize`, mind three pitfalls: (1) teardown also synchronizes (request drain, unload-alert removal), so **mute** `BrowserConsole` after the final per-example check and unmute at the next example's start, or harness timers fail green examples; (2) after a tab closes the session has no current window, so `BrowserConsole.all_errors` must **rescue `Selenium::WebDriver::Error::NoSuchWindowError`**; (3) reading the log drains it and `patiently` retries every exception, so an error raised inside a `patiently` block can be **swallowed** on the retry. Don't try to reproduce per-step checking.

If the Cucumber setup *also* clears the browser log in a companion `Before('@javascript')` (so the end-of-scenario check doesn't inherit errors from a *previous* example in a reused browser session), migrate that too, to a `before(:each, type: :feature, js: true)` that drains the log (e.g. reads `page.driver.browser.logs.get(:browser)`). Otherwise the per-scenario check can fail an innocent example on a prior one's error.

**Wrap any browser-touching teardown (`localStorage`, closing tabs, reading logs) in a `rescue` — best-effort cleanup must never raise.** Such a hook can throw at the end of an example (e.g. a document whose origin denies `localStorage` access); in an `after` hook that fails the just-passed example *and* degrades the shared browser session so the next example fails too — and it surfaces only in the full run, not your single-`-e` authoring runs. Guard it:

```ruby
config.after(:each, type: :feature, js: true) do
  begin
    page.execute_script('window.localStorage.clear()')
  rescue Selenium::WebDriver::Error::WebDriverError
    # best-effort cleanup; a denied/again-navigated document must not fail the example
  end
end
```

#### Conclude in-flight browser requests before DatabaseCleaner runs (JS specs)

On a `js: true` example the browser can still have a request **in flight or scheduled** when the example body ends — a poll (`up-poll`), or anything deferred via `setTimeout`/`setInterval`/debounce/a pending `fetch`. `DatabaseCleaner.clean` (deletion strategy for JS) then empties the DB *before* the browser stops, so that late request hits an empty DB (e.g. `current_user` gone → 404), and the recorded server error is **re-raised during Capybara teardown**, failing an otherwise-green scenario.

Fix it globally: before the DB is cleaned, **stop the browser from issuing new requests and drain the in-flight ones** (per [makandra card 32001](https://makandracards.com/makandra/32001-capybara-waiting-pending-ajax-requests-test)). Add a support file and an `after(:each, …, js: true)` hook that must run **before** the DB is cleaned (ordering caveat below the code):

```ruby
# spec/support/conclude_browser_requests.rb
module ConcludeBrowserRequests
  def conclude_browser_requests
    return unless page.driver.is_a?(Capybara::Selenium::Driver)

    # First, dismiss any dialog the example left open. This step is only load-bearing when the driver
    # is registered with `unhandled_prompt_behavior: 'ignore'` (the makandra convention) — then an
    # unhandled alert/confirm stays open and would (a) leak into the NEXT example in this process —
    # which then dies on UnexpectedAlertOpenError at its first command — and (b) block the
    # execute_script below. If your driver uses Selenium's default (auto-dismiss), no dialog survives
    # the example and this block is a harmless no-op (it rescues NoSuchAlertError). Clear it first.
    begin
      page.driver.browser.switch_to.alert.dismiss
    rescue Selenium::WebDriver::Error::NoSuchAlertError
      # no dialog open — the normal case
    end

    # Block any *new* requests (stops polls / timers / debounced calls from firing again)...
    page.execute_script(<<~JS)
      window.XMLHttpRequest.prototype.send = function() {}
      window.fetch = function() { return new Promise(function() {}) }
    JS
    # ...then wait for the ones already in flight to finish.
    Capybara::Lockstep.synchronize   # if the app bundles capybara-lockstep
  rescue Selenium::WebDriver::Error::WebDriverError
    # best-effort; must never fail the example
  end
end

RSpec.configure do |config|
  config.include(ConcludeBrowserRequests, type: :feature)
  config.after(:each, type: :feature, js: true) { conclude_browser_requests }
end
```

**Pin the order — `DatabaseCleaner.clean` must run *after* this drain.** RSpec runs plain `after(:each)` hooks in reverse-registration order, and `append_after(:each)` hooks *after all* of them; **`prepend_after` is merely an alias of `after`**, so it does not help. This drain is a plain `after`, so it beats the clean only if the app cleans via an **`around` hook** (whose post-`example.run` cleanup runs after every `after`) or an **`append_after`**. If instead the app cleans in a plain `config.after { DatabaseCleaner.clean }`, the two are same-level `after` hooks whose relative order depends on support-file **load order** (an unsorted `Dir[…]`) — the drain-before-clean invariant is then **unpinned, and green only by luck**. So in the Phase 3a audit, ensure the app's DB-clean is an `around` hook, or change it to `config.append_after { DatabaseCleaner.clean }`.

**The same ordering trap hits a global time-travel reset.** A `config.after { Timecop.return }` (or `travel_back`) in a support file registers early under the sorted load, so — plain `after` running in reverse-registration order — it resets the clock **before** the browser-teardown hooks; a session signed in at the travelled time then expires and its "session expired" alert breaks teardown. Make it `config.append_after { Timecop.return }` so the clock resets only after the browser is done.

**The same ordering trap sinks any cleanup that purges an external store *by enumerating DB rows*** — a search index (Searchkick/Elasticsearch), a cache keyed by record, an upload store. A hook written as `model.searchkick_index.bulk_delete(model.all)` is correct only while the rows still exist: registered as a **sibling `around` to DatabaseCleaner's**, it can run *outside* it, so the DB is already empty, `model.all` returns nothing, and the purge is a **silent no-op** — no error, nothing to notice. The documents then leak into the next example, where they surface as a phantom hit that counts in a facet but renders as "no results", one example *later* than the cause. So when porting such a hook: either pin it to run **inside** the DB-cleaning hook, or — better — **purge by query rather than by DB rows** (`delete_by_query`, drop and recreate the index), which is correct regardless of hook order. Verify it rather than assuming: a stack trace from a failing example shows which hook wraps which.

If the app has **no** capybara-lockstep, replace the `synchronize` line with a short wait for pending requests to settle (e.g. poll `page.evaluate_script('window.jQuery ? jQuery.active : 0').zero?` until true, with a timeout). Don't fix this per-scenario (navigating away in one spec) — it's a global teardown concern.

### Non-step-definition code: load-time configuration vs. `before(:suite)`

If a steps file contains method calls that are *not* a block prefixed with `Given`, `When`, `Then`, `Before` or `After`, decide between two targets:

- **Pure configuration and one-time registrations** (Capybara settings, driver registration, Warden hooks, etc.) → keep them as **plain top-level statements** in the support file, run at load time — as the reference apps' `capybara.rb` do (top-level, not inside a hook). Don't wrap these in a method or a hook.
- **Setup that must run once, *after* the app and database have booted** (e.g. `DatabaseCleaner.clean_with(:deletion)`, resetting DB sequences) → put it in a `config.before(:suite)` block.

> **Don't try to scope suite-level setup to "only feature runs".** A `:suite` hook isn't tied to any example or group, so `config.before(:suite, type: :feature)` **silently ignores** the metadata — it does *not* do what it looks like. Configure unconditionally.

Example INPUT (pure configuration + a one-time registration):

```ruby
Capybara.match = :prefer_exact
Capybara.default_normalize_ws = true
Capybara.enable_aria_label = true

if CapybaraSupport.ci?
  Capybara.save_path = 'tmp/artifacts/capybara'
end

Warden::Manager.on_request do |proxy|
  Rails.logger.info("Warden request")
end
```

Desired OUTPUT (`spec/support/capybara.rb`) — left as top-level load-time code, no hook:

```ruby
Capybara.match = :prefer_exact
Capybara.default_normalize_ws = true
Capybara.enable_aria_label = true

if CapybaraSupport.ci?
  Capybara.save_path = 'tmp/artifacts/capybara'
end

Warden::Manager.on_request do |proxy|
  Rails.logger.info("Warden request")
end
```

Example INPUT (runtime setup that must run after the DB is up):

```ruby
DatabaseCleaner.clean_with(:deletion)
```

Desired OUTPUT — wrapped in `before(:suite)` (no metadata filter):

```ruby
RSpec.configure do |config|
  config.before(:suite) do
    DatabaseCleaner.clean_with(:deletion)
  end
end
```


### Some statements remain in the file unchanged

The following statements should NOT be transformed. They should be copied into the OUTPUT file unchanged:

- Class definitions with `class`
- Module definitions `module`
- `require` statements
- Monkey patches using `class_eval` or `prepend`


### `World(mod)` calls become a `config.include(mod)` hook

When an input file includes a module into Cucumber steps using `World(mod)`, include the module with an RSpec `config.include(mod, type: :feature)` hook instead.

Example input:

```ruby
World(FactoryBot::Syntax::Methods)
```

Example output:

```ruby
RSpec.configure do |config|
  config.include(FactoryBot::Syntax::Methods, type: :feature)
end
```

### Other Cucumber-only DSL: `ParameterType`, `Around`

`features/support/` often defines more Cucumber-only DSL that has no place in RSpec:

- **`ParameterType(...)`** (in e.g. `parameter_types.rb`) registers custom step-argument types like `{json}` or `{class}` used by step regexps. There's no RSpec equivalent — **drop the definition and inline its parsing** wherever the step using it is converted (e.g. a `{json}` param → `JSON.parse(...)`, a `{class}` param → `value.classify.constantize`).
- **`Around` hooks** wrap each scenario. Migrate them to **`config.around(:each, type: :feature) { |example| … example.run … }`** (same as `Before`/`After` → `before`/`after`, with the same optional-tag → metadata handling).

(Add these to your mental "Cucumber-isms" list alongside `World`, `Before`/`After`, and the non-migrated `require`s.)

### Don't translate `require` for Cucumber and cucumber-related libraries

In env.rb:

```ruby
require 'cucumber/rails'
require 'rspec/core'
require 'cucumber/rspec/doubles'
require Rails.root.join('spec/support/should_syntax')
require 'spreewald/all_steps'
```


### Aggregating your output

When you're done, place all generated Ruby methods in a module. Name the module after the processed file. E.g. when processing `web_steps.rb` the module should be named `WebSteps`.

After the module have a single `RSpec.configure` block that includes the module into all RSpec feature specs. It should also host all the generated `before` and `after` hooks.

So the final file structure is, in this order:

- Unchanged code (classes, module, require, monkey patches, etc.)
- Methods generated from step definitions and Before/After hooks, grouped in a module.
- `RSpec.configure` block

**Where each kind of file goes:**

- **Migrated step-definition modules → `spec/support/feature_steps/`** (e.g. `spec/support/feature_steps/foo_steps.rb`). Keep them in their own subfolder, *not* loose in `spec/support/`, so the migrated helpers are easy to find and review as a group. They're picked up by the existing recursive `spec/support/**/*.rb` loader.
- **Custom matchers → `spec/support/matchers/`** (as the Spreewald/cucumber_factory guides already specify).
- **Pure tool configuration** (Capybara, DatabaseCleaner, etc.) → directly in `spec/support/` (e.g. `spec/support/capybara.rb`).

The module name should be derived from the original filename we're transforming. E.g. methods generated from `features/step_definitions/authentication_steps.rb` should go into a module `AuthenticationSteps`. E.g. methods generated from `features/support/capybara.rb` should go into a module `CapybaraSupport`.

**Always keep the filename's `…Steps` / `…Support` suffix — never shorten to the bare topic name.** A topic file like `articles_steps.rb` → `ArticlesSteps`, **not** `Articles`: in a Zeitwerk app a bare `Articles` / `Admin` / `UserGroups` module **reopens the app's own namespace module** (the one Zeitwerk defines from `app/controllers/articles/…`), mixing your test helpers into an application constant. Keeping the suffix keeps the support module distinct.

**Watch for method-name collisions across modules.** Every generated module is mixed into the same feature-spec scope (`config.include(..., type: :feature)`), so if two step files both define, say, a `save_form` method, whichever module is included last silently wins — and the wrong body runs. When deriving method names, check `step-mapping.md` for a name you've already used; if two genuinely different steps would collide, give them distinct, more specific names (e.g. `save_user_form` vs `save_settings_form`) and **flag the collision** to the human in `progress.md`.

Example INPUT `features/step_definitions/foo_steps.rb`:

```ruby
require 'warden'

Warden::Manager.on_request do |proxy|
  Rails.logger.info("Warden request")
end

class SomeClass
  def some_method
    puts "foo"
  end
end

When /^I save the form$/ do
  first('[type=submit]').click
end

Given /^the next generated token will be "(.+?)"$/ do |token|
  allow(Devise).to receive(:friendly_token).and_return(token)
end

Before('@patiently') do
  @old_max_wait_time = Capybara.default_max_wait_time
  Capybara.default_max_wait_time = 12
end

After('@patiently') do
  Capybara.default_max_wait_time = @old_max_wait_time
end
```

Desired OUTPUT `spec/support/feature_steps/foo_steps.rb`:

```ruby
require 'warden'

class SomeClass
  def some_method
    puts "foo"
  end
end

module FooSteps
  def log_warden_request
    Warden::Manager.on_request do |proxy|
      Rails.logger.info("Warden request")
    end
  end

  def save_form
    first('[type=submit]').click
  end

  def mock_next_devise_token(token:)
    allow(Devise).to receive(:friendly_token).and_return(token)
  end

  def increase_capybara_wait_time
    @old_max_wait_time = Capybara.default_max_wait_time
    Capybara.default_max_wait_time = 12
  end

  def reset_capybara_wait_time
    Capybara.default_max_wait_time = @old_max_wait_time
  end
end

RSpec.configure do |config|
  config.include(FooSteps, type: :feature)

  config.before(:suite) do
    log_warden_request
  end

  config.before(:each, type: :feature, patiently: true) do
    increase_capybara_wait_time
  end

  config.after(:each, type: :feature, patiently: true) do
    reset_capybara_wait_time
  end
end
```

### Transformed files from features/support are also created to spec/support

When you transform a file in `features/support`, place the transformed output in the `spec/support` folder, alongside with the transformed step definitions.

Note that Cucumber-specific code must be **dropped or translated**, never copied verbatim — the RSpec app has no `Cucumber::Rails` constants. The DatabaseCleaner setup is a good example: Cucumber selects the cleaning strategy via `Cucumber::Rails::Database.javascript_strategy`, whereas the reference RSpec apps select it per-example in an `around` hook (deletion for `js: true` / non-transactional examples, transaction otherwise).

Example INPUT `features/support/database_cleaner.rb`:

```ruby
DatabaseCleaner.clean_with(:deletion) # clean once, now
DatabaseCleaner.strategy = :transaction
Cucumber::Rails::Database.javascript_strategy = :deletion
```

Example OUTPUT `spec/support/database_cleaner.rb`:

```ruby
RSpec.configure do |config|
  config.before(:suite) do
    DatabaseCleaner.clean_with(:deletion) # clean once, now
  end

  config.around do |example|
    DatabaseCleaner.strategy =
      if example.metadata[:transaction] == false || example.metadata[:js] == true
        :deletion # JS specs run in a real browser / separate connection, so a transaction won't be visible
      else
        :transaction
      end

    DatabaseCleaner.start
    example.run
    DatabaseCleaner.clean
  end
end
```

**Port any per-scenario primary-key-sequence reset the Cucumber suite had.** Check `features/support/env.rb` (and other `features/support/*.rb`) for a hook that resets pk sequences every scenario — `reset_pk_sequence!`, a raw `setval`, `RESTART IDENTITY`, or `reset_ids: true`. It's Cucumber-only, so it's easy to drop silently — but **if the suite inserts explicit ids** (`create(:movie, id: 10)`, a helper that pins a record's id, ids asserted verbatim in the UI) it almost certainly depended on it. RSpec's `:transaction`/`:deletion` cleaning does **not** reset sequences and `nextval` is **non-transactional** (never rolled back), so across a run each table's sequence climbs monotonically as examples auto-create records — until it hands out a value equal to a fixture id and the next app-created record collides. The result is an intermittent, **order-/shard-dependent `PG::UniqueViolation` on a `*_pkey`** that's invisible until a shard climbs far enough (small fixture ids like `10`/`100` collide fast; large ones only on long shards) and reads like infra noise. Port it into `spec/support/database_cleaner.rb` so it runs each example while the tables are empty (the cleaning strategy has just rewound them, so sequences reset to 1):

```ruby
# in the same RSpec.configure as above — mirrors the Cucumber `Before` hook in features/support/env.rb
config.prepend_before do
  conn = ActiveRecord::Base.connection
  conn.tables.each { |t| conn.reset_pk_sequence!(t) }
end
```

Do it **globally (all tables)**, not per-table: every table with explicit-id fixtures (`movies`, `users`, `attachments`, …) has the same exposure, and a one-table patch just moves the flake.

# Phases 4 & 5 — Converting step definitions, features, and scenarios

The craft of converting step definitions (Phase 4) and features/scenarios (Phase 5) lives in its own file, **`conversion-guide.md`** — because the fan-out workers need exactly this subset and nothing else. Read it there.

- **During the serial foundation (orchestrator):** convert all cross-cutting step definitions and migrate the first features yourself, following `conversion-guide.md`, until the shared surface stabilizes (see *Parallelism*). Everything you build lands in the shared support tree and `step-mapping.md`, then freezes.
- **During fan-out (workers):** each worker migrates its assigned `.feature` files per `conversion-guide.md`, building on the foundation and adding to the shared support tree directly when it needs something the foundation lacks (logging each change).

# Phase 6 — Finishing up

Once **all** in-scope features are `done` (migrated, green, and each worker's whole-file normalization done — see *What a worker does*), finish the suite: **by yourself, in the foreground, with no workers**, consolidate the shared support tree, lint, run one verification pass, then ship (knapsack, CI, the MR, the report, the completion signal). There is no separate review/normalize fan-out — each worker already normalized its own spec, so this phase is entirely serial orchestrator work.

### Clean-up pass over the generated helpers and matchers

Parallel workers each write their own spec-local helpers, so near-duplicate helpers/matchers end up scattered across `spec/features/**` and the shared tree. **After fan-out — by yourself, in the foreground, with no workers (this consolidation is never parallelized)** — make one consolidation pass over `spec/features/**`, `spec/support/feature_steps/`, and `spec/support/matchers/`. **Time-travel helpers** (`travel_to_time`/`Timecop.travel(...)` wrappers), **job-perform helpers** (`perform_enqueued_jobs_now` and the like), and **JS-widget interaction helpers** (Select2 / date-picker wrappers) are common — non-exclusive — examples of what workers reliably duplicate, so look there first:

- **Promote duplicated spec-local helpers/matchers into shared support.** Scan `spec/features/**` for helpers/matchers defined *inside* spec files (a `def`, a `matcher`, or `shared_examples`). Where two or more specs define the **same or near-same** thing (e.g. a `meta_tag_content` helper appearing in two specs), unify them into one definition under `spec/support/feature_steps/` or `spec/support/matchers/`, point the specs at it, and delete the local copies. **Light parameterization is fine** to make one helper serve its callers (add an argument or keyword). But **don't unify when it would take excessive parameterization or metaprogramming** to cover the variants — leave those spec-local; a little duplication beats a contorted shared helper.
- **Unify duplicates already in the shared tree.** Merge helpers/matchers in `spec/support/` that do the same — or almost the same — thing into one. (`tmp/mandoline/step-mapping.md` is the inventory to scan.)
- **Inline the trivial ones.** A helper/matcher whose body is a single self-evident Capybara call adds indirection without value — inline it at its call sites as a Ruby/Capybara one-liner and delete the helper.
- **Keep the ones that earn their place.** A helper/matcher that does several things, or whose *name* conveys tester intent (`sign_in_as_admin`, `have_flash`), should stay.
- **Localise single-use helpers.** If, after unifying, a helper/matcher is used in only **one** feature spec, move it out of the global support tree and into that spec — a `def` or a `matcher`/`shared_examples` defined inside the example group — so global support stays lean and the helper lives next to its only user.
- **Census every helper/matcher by call-site count — the mechanical backstop for the bullets above.** For each `def`/`matcher`/`shared_examples` (shared *and* spec-local), grep **all of `spec/` — features *and* support** — for its call sites, **counting calls from other support code**: a helper used only by another helper (e.g. `enqueue_login` called by `sign_in`, `mail_links` by `mail_link_paths`) is **live**, not dead. Then **0 → delete it** (dead code a fan-out reliably leaves behind — an unused matcher, an orphaned `json_body`), **1 → localise it** into its sole caller, **2+ → keep it shared**. **Exempt `define_negated_matcher` aliases** (`have_no_*`) — a negated alias with 0 call sites is deliberate API (every custom matcher gets one, so `.and have_no_x` chains work — see `spreewald-guide.md`), not dead code; keep it. Grepping `spec/features` alone would wrongly flag internally-called helpers as dead — so grep the whole tree. This catches the residue eyeballing misses. **Match the bare name without a word boundary, and validate the census before you trust it:** grep the name literally (`grep -rF 'name' spec/`) or allow the suffix explicitly (`grep -roE 'name[?!]?' spec/`). A `\b` word-boundary *after* a `?`/`!` method name **never matches** — both are already non-word characters, so there's no boundary there — silently reporting every predicate/bang helper (`javascript_driver?`, `downloaded?`) as **0 → wrongly deleted**. Before acting on any census, **check it against two known quantities** — one helper you know is used everywhere and one used exactly once; if those two rows are wrong, the whole table is (that check, not the recipe, is what catches a broken grep).
- **Scan for the same helper defined in two *different* modules.** `Lint/DuplicateMethods` only catches duplicates **within one file**, but under fan-out the common collision is two workers each adding, say, `click_image` to two different support modules — both `config.include`d into feature specs, so the later include silently wins and nothing reports it. Run a cross-file scan during consolidation: `grep -rhoE '^\s+def [a-z_0-9?!]+' spec/support/**/*.rb | sed -E 's/^\s+def //' | sort | uniq -d` — then reconcile each duplicate to one definition.

Re-run the affected specs after this pass to confirm nothing broke.

### Tag-parity audit — every Cucumber tag survived the migration

A dropped tag is silent coverage/CI drift: an organizational tag that vanished breaks a `--tag` workflow, and an **exclusion** tag that vanished makes CI run (or a preserved one makes CI skip) the wrong set. **`@javascript` → `js: true` is the costliest one to drop, and it never announces itself:** the spec doesn't error, it quietly runs under rack-test and asserts against a page the JavaScript never touched — so a filter spec "passes" having never applied its filter. Count it like any other tag (see tag rules #9 in `spreewald-guide.md` and *Global mocks*). Under fan-out this is easy to miss, so verify it mechanically. **Build the tag list from the tag *lines*, splitting lines that carry several tags** — `grep -rhE '^[[:space:]]*@' features --include='*.feature' | tr -s ' \t' '\n' | grep -oE '^@[a-zA-Z0-9_-]+' | sort -u`. This dodges two silent traps: a bare `@[a-z-]+` scoops up email addresses in scenario data (`batman@example.com` → phantom `@example`/`@test`); and — subtler — matching `^[[:space:]]*@…` against the *whole line* sees only the **first** tag on a line carrying several (`@javascript @solo`), silently hiding the rest and any support hook keyed to them. Filtering to lines that *start* with `@` still excludes scenario data, and splitting the line first (`tr … '\n'`) catches every tag, including ones with digits or underscores. Then, for every non-debug tag, assert occurrence parity between the `.feature`s and the specs:

```bash
for tag in authorization patiently mobile real-api-requests allow-rescue; do   # ← your suite's tags
  meta=$(echo "$tag" | tr - _)
  echo "$tag: features=$(grep -rhoE "(^|\s)@$tag(\s|$)" features --include='*.feature' | wc -l)" \
       "spec=$(grep -rhoE ":$meta\b|\b$meta:" spec/features | wc -l)"
done
```

Note the spec pattern matches `\b$meta:` (**any** value), not `\b$meta: true` — otherwise **value-style** metadata (`sidekiq: :fake`, `mobile: :tablet`) scores `spec=0` and reads as *dropped*, when it's actually the correct migration of a valued tag. A false "dropped" here is worse than noise: it invites you to add metadata that's already present, or to "fix" a correct value mapping into a wrong boolean one.

Counts should match per tag, with two expected, explainable exceptions: (1) a whole-feature `@javascript` collapses to a single `js: true` on the `feature` block, so reconcile `@javascript` per-file, not by raw count; (2) the debug tags `@slow-motion` / `@single-step` are intentionally dropped (spreewald rule #8). Any other mismatch is a tag that got lost — track it down and restore it.

**This audit counts *tags* — a cheap, robust mechanical check. Do not grow it into a scenario/step "coverage auditor."** Migration *completeness* — every scenario, step, and assertion present and in order — is verified by **reading each `.feature` against its migrated spec** (the per-scenario review in `conversion-guide.md`), not by a regex/grep/Python script. A scripted parity auditor gives *false confidence*: it silently under-counts (a line-continued `js: true`, a renamed-but-equivalent step, a table nuance) while guarding exactly the drop that otherwise passes green. Use your judgement on the pair, not a tool.

### Lint the generated code

**Detect each linter with `bundle show <gem>`, not by eyeballing the `Gemfile`/config.** `bundle show <gem>` is definitive — it prints the gem's path if bundled, or `Could not find gem …` if not.

- **RuboCop.** Check `bundle show rubocop`. If it's present, run it over the code you generated and fix the violations:

  ```bash
  bundle show rubocop && bundle exec rubocop spec/features spec/support
  ```

  RuboCop can auto-correct most style offenses. Use **`-A` (uppercase)**, which applies *all* corrections; do **not** use `-a` (lowercase), which applies only the ones RuboCop deems "safe" and leaves the rest as offenses that then fail CI:

  ```bash
  bundle exec rubocop -A spec/features spec/support   # -A, not -a
  ```

  No need to re-run specs just for this: `-A` runs before the final verification run below, which re-executes this session's specs anyway. (`-A` does include unsafe corrections, but in practice they don't break feature specs.)

  **RuboCop may be enforced *inside* the rspec suite, not just by a (often `allow_failure`) CI lint job.** Grep for a `spec/rubocop_spec.rb` (or any rubocop-in-rspec spec); if one exists and isn't `allow_failure`, **any** offense in a migrated file fails the rspec run. **But how it runs varies — don't infer lint coverage from the rspec run:** it may be **guarded** (e.g. `unless ENV['CI']` — active locally, skipped on CI's rspec job, where a *separate* lint job/step enforces it), or the app may not wire RuboCop into rspec at all (you run it by hand). So don't stop at "`-A` ran", and don't read a green rspec run as lint-clean — make the migrated files **truly offense-free** by running `bundle exec rubocop spec/features spec/support` (no `-A`) directly and clearing what remains. Several cops `-A` won't auto-correct need a manual fix or a scoped inline `# rubocop:disable` — e.g. `Capybara/SpecificMatcher`, `Capybara/VisibilityMatcher`, `FactoryBot/ExcessiveCreateList`, `RSpec/ExpectActual`, `RSpec/IteratedExpectation`.

- **Brakeman.** Check `bundle show brakeman`. **If it's present, you must run it** — CI runs Brakeman and will fail the MR otherwise. Don't skip it on a "test-only change" assumption:

  ```bash
  bundle show brakeman && bundle exec brakeman
  ```

  **Leave it green the way CI runs it.** Many apps set `config/brakeman.yml` to exit non-zero on *any* unignored warning, so one warning fails CI. Run it as CI does and resolve **every** warning — don't dismiss one as "unrelated/baseline" and leave CI red:
  - **Migration introduced it** (rare — you touch `spec/`, not app code) → fix it.
  - **Pre-existing / non-actionable** (e.g. an EOL-dependency warning from the Rails version) → silence it the way **this repo already silences such warnings**, and **flag it in your closing report** — don't just leave the build red. Check `config/brakeman.yml` first: if it already lists checks under `:skip_checks:` (e.g. `CheckEOLRuby`), follow that convention (add `CheckEOLRails` etc.) rather than introducing a second mechanism; otherwise use `config/brakeman.ignore`. **Edit the ignore file directly** — don't run `bundle exec brakeman -I`, which is *interactive* and will stall an unattended run.

  The bar is "Brakeman passes the way CI runs it," not "I ran Brakeman."

- **`license_finder` (if present).** Some apps gate dependency licenses via a spec or CI job. This migration adds **one** runtime-adjacent gem — `patiently` (see `spreewald-guide.md`) — so the diff isn't purely `spec/`. If `bundle show license_finder` succeeds and its check fails on `patiently`, approve it the way the repo already approves licenses (a `dependency_decisions.yml` entry / `license_finder approvals add`). (`patiently` is MIT; if MIT is already permitted, nothing is needed.)

### Now — and only now — run the specs you migrated this session

> **If the human forbids large local runs** (they can block their machine for a long time) **and the app has CI, skip the local passes below and let the MR pipeline be the verification** — push and drive CI to green (*Validate in real CI*). Prefer CI whenever it exists; the local runs here are the gate only when there is **no** CI (see the no-CI exceptions).

**First, make sure the fan-out has fully wound down, and reap any orphaned test processes.** An interrupted or abnormally-terminated worker can leave an **orphaned rspec process** holding DB connections (dirties the shared test DB → spurious cascading errors like "… already taken") **and a leaked headless Chrome**. Chrome leaks specifically when an rspec run is **killed before Capybara's `at_exit` fires**: a cleanly-exiting run quits its browser, but SIGTERM/SIGKILL bypasses `at_exit` — a `timeout` wrapper firing, a `kill -9`, or the harness's own foreground-command timeout — and these accumulate *throughout* a long run, not just now. When you reap:
- **Kill by specific PID**, not `pkill -f <pattern>` (which can match your own shell).
- **The box is often a dev workstation with the human's *interactive* Chrome open, so only ever kill Chromes whose args contain `--headless`** — rspec/Capybara always pass it (plus a `/tmp` user-data-dir and a remote-debugging port); interactive Chromes never do. **Never reap by process *age* or a bare `chrome` pattern** — that closes the human's tabs. Prefer the specific orphaned spec/PID over any broad sweep — and note the detection command **self-matches**: `ps … | grep -- --headless` (or `grep rspec`) also matches your own `grep`/`bash -c …` wrapper, so on a clean box you'll "find" phantom orphans. Match on the process **name** and ignore freshly-started ones: `ps -eo pid,etime,comm,args | awk '$3 ~ /chrome/ && /--headless/'`, treating an `etime` near `00:00` as yourself, not an orphan.
- **For your own verification runs, don't let rspec be killed** — that killed run is the main *self-inflicted* Chrome leak. Give it a **generous** timeout (don't wrap it in a tight `timeout N`), or run it as a **tracked background task you await**: you're the orchestrator, so you persist and the completion callback reaches you — a *worker* can't, which is why workers must run rspec in the foreground (see `conversion-guide.md` → *Work scenario for scenario*).

Run the **feature specs you migrated in this session** — **not** the whole `spec/features`. Prior-session specs were already verified as they were migrated, and out-of-scope specs aren't yours to prove; re-running everything each session is wasteful (and pointless when the scope was limited or you resumed). Gather this session's specs from `progress.md`'s this-session done-events, and run them **once** (during the phases you only ran targeted per-scenario selections — see *Work scenario for scenario*):

- **Serial** — simplest, fine for a modest set:

  ```bash
  bundle exec rspec spec/features/a_spec.rb spec/features/b_spec.rb   # this session's migrated specs
  ```

- **With `parallel_tests`** if the set is large and the app bundles it (`bundle show parallel_tests`) — pass the same file list, or the scope directory when the session migrated a whole module:

  ```bash
  bundle exec parallel_rspec spec/features/a_spec.rb spec/features/b_spec.rb
  ```

> **Moving flakes in a local *parallel* run = suspect the machine, not the specs.** On a dev workstation (an IDE, the app's service containers, several headless Chromes on a few cores) a full `parallel_rspec` run can fail *differently* each time — the same env-blocked specs plus a *different* browser spec each run, all with the same signature: a matcher that *does* retry timing out on an **empty** read. That looks exactly like a missing sync point or too-short retry budget, but it's **load**. Confirm by re-running the movers **serially**; if they pass, don't touch them — cap local parallelism well below core count, or just run serially and eat the wall-clock. CI (one container per shard) is the arbiter. **Changing a spec to accommodate the reviewer's laptop is a silent parity regression.**

> Two other flakiness sources worth recognising, because they *don't* clear on a serial re-run: a spec that flakes the **same way even run alone** usually needs **action/observation interleaving**, not a longer wait (see *interleave actions and observations* in `conversion-guide.md`); and **factories that set random or sequenced values** can themselves cause order-dependent pass/fail when a spec searches or filters by a short term that a generated value happens to match (more: <https://makandracards.com/makandra/22471-ruby-build-randomness-factories>).

> **A local-only failure while CI is green is a *local-environment* quirk — don't chase it locally.** Example: a recent local Chrome honours `scroll-behavior: smooth`, so during Selenium's scroll-before-click the target animates into place and a **below-the-fold click** lands where it *was* and misses — the spec fails locally though it's correct, while CI (a different Chrome) is green. **Green CI is the completeness arbiter:** don't re-run the suite locally "to be sure", and don't change the spec to satisfy your browser (a silent parity regression). If it disrupts local work, fix it at the **environment** level, not in specs — `html { scroll-behavior: auto !important }` in the test env — so local matches CI. Scope this to a *recognised* env quirk like smooth-scroll; a local failure you can't explain that way is still a real failure to fix.

**Run them unconditionally — do not replicate any exclusions the CI config applies** (skipped tags like `@wip`/`:flaky`/`:broken`, excluded files, sharding). A spec CI would skip is exactly the one most likely to hide a migration mistake.

**Also run the non-feature spec types once — but never the whole feature suite.** Your migration edited **shared** support (matchers, hooks, sometimes a global Rack/Warden hook), and feature specs don't exercise the other suites. So after the feature-spec run above, run the app's **non-feature** specs once — fast, no browser — to confirm you didn't break them:

```bash
DISABLE_SPRING=1 bundle exec rspec --tag '~type:feature'   # models, requests, controllers, mailers, …
```

This is the cheap catch for the classic trap: a global `Warden::Manager.on_request` hook that reads feature-only state crashes **request** specs with `NoMethodError` while every feature spec stays green. **Do not** run the whole *feature* suite to compensate — that can take hours on a large app; the full feature run is CI's job (see *Validate in real CI*).

**A failure here may be *pre-existing*, not migration-caused — check before you chase it.** The non-feature suites were green before you touched them, so a red one usually means the migration broke shared support. But not always: adding feature specs **changes knapsack's file distribution**, which can make a **shard-dependent latent bug** (an order- or co-location-sensitive one — a factory-sequence collision, a leaked global) start failing where it happened not to before. Before assuming the migration caused it, reproduce with **only the pre-existing files** in a fixed order — `rspec <a>_spec.rb <b>_spec.rb --order defined`, none of your new specs. If it still fails, it's latent and pre-existing: flag it as such rather than treating it as a migration regression.

> **Caveat — this run does NOT prove the reverse direction: state a *feature* spec leaks into a later non-feature spec.** It never runs a feature spec, so a global a feature spec mutates and leaves dirty (e.g. `ActionMailer::Base.default_url_options[:host]` set from the request host) is invisible here — it surfaces only in CI's mixed, random-order `knapsack:rspec` run (or a deliberate `rspec spec/features/<one>_spec.rb spec/models/<suspect>_spec.rb` interleave). The real defence is upstream, not here: scope every save/restore-global hook to `:feature` during the Phase-3a audit (see *audit what `spec/support/` already provides* → item 2).

**Exception — no CI + migration complete → run the *entire* spec suite once.** If the project has **no CI config** (no `.gitlab-ci.yml`, no `.github/workflows/`, no other CI setup) **and this session migrated the last remaining `.feature`** (nothing left todo), run **all** specs once — every type, every file, not just feature specs:

```bash
bundle exec rspec                       # or: bundle exec rake parallel:spec   (if parallel_tests is bundled)
```

With no CI there's no later full-suite run, so this local pass is the only end-to-end safety net — take it when the migration is actually finished. (If features still remain — you stopped on budget or context — run only this session's migrated feature specs, as above; defer the full run until a later session completes the migration.)

Either way, **normal random order — do not pin `--seed`/`--order defined`** (a fixed order just hides an order-dependent leak). Note: a single serial process surfaces cross-example state leaks better than parallel (which can split a leaker from its victim across processes), but **one pass is enough here** — CI is the authoritative full green.

> **"Green individually" is necessary but not sufficient** — some defects appear only in the **full, parallel, random-order** run, which here is CI's job. Two classes recur and both are prevented at the source (so they don't reach CI): a **cross-example browser-dialog leak** — a JS example that ends with an unhandled `alert`/`confirm` open leaks it into the next example in the same worker process, which dies on `UnexpectedAlertOpenError` (fixed by the dialog-dismissal in the standard `conclude_browser_requests` teardown — see Phase 3); and a **non-retrying custom read** that returns a transient `nil` under the latency of parallel browsers (fixed by the "every custom matcher that reads live page state must retry" rule — see `spreewald-guide.md`). If CI surfaces one anyway, fix it at the source per those rules rather than papering over the single scenario.

**On a failure: fix it, then re-run only the scenarios you fixed — do not repeat the full pass.** Fix the failing scenario (or the helper/matcher it depends on), re-run just those file(s)/line(s), and move on. Don't launch another whole-suite run to re-confirm: **CI runs the full suite on the MR** (see *Validate in real CI* — you drive that when the remote is controllable, otherwise recommend it), and that run is the real bar for "done."

**When failures appear, suspect the shared-support edits first.** Concatenate the workers' `tmp/mandoline/support-changes-*.md` logs — a failure in a feature that uses a changed helper/matcher was most likely caused by a concurrent edit (a signature/behavior change whose other call sites weren't all fixed). Reconcile that helper and its call sites. (Other usual suspects: cross-example state leakage — add an `after(:each, type: :feature)` reset for whatever a step left set, see *Migration gotchas*.)

### Knapsack report — leave regeneration to the human (if the app uses `knapsack`)

If the app splits specs across CI nodes with the **`knapsack`** gem (there will be a committed `knapsack_rspec_report.json`, since the app already ran RSpec through knapsack before the migration), the migration adds feature specs that report doesn't list. **Regenerating it is not part of this migration** — it needs a full timing run, and the migration is long enough. It's safe to leave stale: knapsack runs *all* globbed spec files regardless, distributing files absent from the report round-robin across nodes (its `LeftoverDistributor`). So every migrated spec runs on CI; only the **load balance** across nodes is uneven until the report is refreshed.

So instead, **tell the human in your closing report to update the knapsack RSpec profile themselves** — stating explicitly that **CI still works without it, only with uneven worker-load distribution** — or that they can copy the `knapsack_rspec_report.json` artifact from any CI run. (This is only for the regular `knapsack` gem; `knapsack_pro`'s queue mode allocates dynamically and needs no committed file.)

**Put that hand-off in the closing report, never *only* in a code comment.** A `# NOTE (mandoline migration): consider bumping parallel: and regenerating the knapsack report` left in `.gitlab-ci.yml` is not a follow-up mechanism — such a note can sit untouched for months while the browser suite runs on too few nodes with no timings for any migrated file, whereas an explicit hand-off in the report tends to get acted on right away. And **anything you can apply yourself, apply**: the deleted cucumber job's `parallel:` value is right there to copy, so port it now rather than leaving a note about it. If you must defer something, leave it where humans track work — the closing report and `needs-attention.md` — and **don't delete the CI file's existing documentation of how to do it** (one migration removed a commented-out line explaining how to regenerate the report, taking away the knob for exactly the task it was deferring).

**If CI is controllable, you can regenerate the report *on CI* instead of punting** — no local timing run needed. A temporary commit that sets `KNAPSACK_GENERATE_REPORT: 'true'` and adds `knapsack_rspec_report.json` to the rspec job's `artifacts:` makes each node write the timings of its own files; download the N partial reports and merge them (nodes cover disjoint files, so there's no overlap) into the committed report, then revert the temporary commit. Watch for a node that **reran failures** — its partial then covers only the rerun, so exclude it. Fall back to the leave-it-to-the-human path above only when the remote isn't controllable.

**If you *do* regenerate a report, generate it from a clean checkout and sanity-check the paths.** Knapsack matches **repo-relative** paths, so an entry recorded as `/home/you/.rbenv/versions/…/gems/makandra-rubocop-17.0.0/…/rubocop_spec.rb` (a spec loaded from an installed gem) or any other absolute path can never match and silently rots. Grep the generated JSON for `/home/`, `/Users/` and `.rbenv` before committing it.

### Adjust CI to stop running Cucumber

The app's CI currently runs the E2E suite with `cucumber`. Switch it to run the RSpec feature specs and remove the Cucumber invocation.

**If the repo has no CI config at all** (no `.gitlab-ci.yml`, no `.github/workflows/`, nothing) — some legacy apps have none, by design — there's nothing to switch. **Skip this section entirely; don't suggest adding CI.** The full local run (see the no-CI exception under *run the specs*) is the validation.

- Most projects use **GitLab CI** — configured in `.gitlab-ci.yml`.
- Some use **GitHub Actions** — configured in `.github/workflows/*.yml`.

Find the job/step that runs `cucumber` (e.g. `bundle exec cucumber`, or a `knapsack:cucumber` node-split job) and replace it with the equivalent RSpec run (`knapsack:rspec` if the app splits with Knapsack — the feature specs now flow through the same rspec split, so a separate E2E job is usually no longer needed). Often this just means **deleting** the cucumber job outright (the feature specs already flow through the existing rspec job).

**But carry the deleted job's *throughput* across, not just its work.** "The feature specs flow through the existing rspec job" is about *where* the work runs, not *how fast*. If the cucumber job was **sharded** (`parallel: N`) and the rspec job isn't, deleting it silently moves the whole browser suite onto a single unsharded node — the pipeline stays green but gets dramatically slower, and nothing about the config *looks* wrong. So compare the removed job's throughput settings against the rspec job that inherits its work — **`parallel:` above all**, plus `services`, resource-class/tags, and timeouts — and copy them over. With knapsack, adding the same `parallel: N` to the rspec job is all that's needed (GitLab supplies `CI_NODE_INDEX`/`CI_NODE_TOTAL`, and knapsack reads them to split files across nodes).

**If you delete the cucumber job, grep for anything that still references it** — a downstream aggregation/coverage job commonly lists it in `needs:` (e.g. `needs: [rspec, cucumber]`). A `needs:` pointing at a job that no longer exists is a **pipeline-config error** that fails the whole pipeline before any test runs, so remove `cucumber` from every such `needs:` too.

**More generally, diff the deleted job's *definition* against the rspec job — a `.feature`→`_spec.rb` inventory doesn't cover the job's *behaviours*, and dropping one silently is easy.** For each of these, state whether it's dropped, kept, or ported: a **retry/rerun harness**, `timeout:`, `parallel:` (above), runner tags, `artifacts:`, `needs:` (above), and any `||` exit-code juggling in `script:`. **The retry harness is the one that bites:** makandra `cucumber` jobs often reran failures **in a fresh process with a fresh browser** (`-f rerun -o tmp/failing_features.txt`, then a second `cucumber @tmp/failing_features.txt` whose exit status won). A plain `knapsack:rspec` drops that, which matters two ways:
> 1. **A dead browser is no longer survivable.** A crashed Chrome renderer (`tab crashed`, zero assertion failures) now fails the whole shard, where the rerun would have re-run those examples against a fresh Chrome and gone green. The true analogue is RSpec's `config.example_status_persistence_file_path` + a **second `rspec --only-failures` pass** (a fresh process) — **not** an in-process retry gem (`rspec-retry`/`rspec-rebound`), which re-runs against the *same dead session*.
> 2. **A rerun had been silently hiding real failures.** Some fraction of "green" pre-migration jobs only passed *on the rerun*. So "the old suite was green" never meant "it passed" — and dropping the retry makes the migration **look** like it introduced flakiness when it merely stopped concealing it. Say so up front, because the reflex is to blame the migration.
> 3. **If you port it, pair it with a loud signal — otherwise it hides *your* flakes too.** Both failure modes happen in practice. With the rerun ported, migrated specs can keep failing their first pass and passing the retry, with **every pipeline green** and nobody looking — including specs a commit claimed to have fixed. With it dropped, a single flaky migrated spec can keep the **default branch red** for a long time. Neither is the outcome you want, and the choice between them isn't the point: port the rerun *and* make a masked failure visible — publish the first pass's failures as a CI artifact or junit report, or run the second pass as a separate `allow_failure: true` job so a masked flake shows as a warning instead of plain green. At minimum, say explicitly in the handover that the job reruns failures, so a green pipeline isn't read as a clean suite. A rerun harness is a defence against a **crashed browser**, not a place to keep flaky specs.

**Preserve any intentional staging.** Some CI configs deliberately run E2E tests *after* the fast tests (models, controllers, etc.), so the slow browser tests only run once the fast suite is green. If the config does this, keep two separate stages:

```bash
# Stage 1 — all specs EXCEPT feature specs (fast):
bundle exec rspec --tag '~type:feature'

# Stage 2 — ONLY feature specs (slow; runs after stage 1 passes):
bundle exec rspec --tag 'type:feature'
```

(Note the `~` in `'~type:feature'` means *exclude*; the second command has no `~`, so it runs *only* feature specs. This relies on `infer_spec_type_from_file_location!` — see Phase 3.) If CI just ran one `cucumber` step with no staging, a single `bundle exec rspec` is fine.

**If you add a *separate* CI step for the feature specs (rather than folding them into an existing RSpec step), invoke RSpec the same way the existing RSpec steps do.** In particular, if those steps run through knapsack (`knapsack:rspec` / a knapsack wrapper with the CI node-split env vars), your new feature-spec step must go through knapsack too — a plain `bundle exec rspec` step would bypass the node split and run the whole (slow, browser-driven) feature suite on a single node.

### Validate in real CI — drive it yourself when the remote is controllable, else recommend it

However thoroughly you ran specs locally, you **could not reproduce the real CI environment** — its parallelism, services, browser/Chrome version, env vars (`TZ`, etc.), and headless setup. The migrated suite green on your machine is necessary but not sufficient; **a green CI run is the real bar for "done."**

(**No CI in the repo?** Then there's nothing to validate against — the full local run you did (see the no-CI exception under *run the specs*) plus the human's review are the bar. The project has no CI by design; **don't recommend adding one**, and skip the rest of this section.)

**Before you hand the branch over, re-diff `features/` against the target branch — a long migration goes stale.** A large suite can take weeks of wall-clock to migrate and review, and the app does not stand still: new `.feature` files can land on the default branch while the migration is under review, forcing a second migration batch (and its own round of fixups) onto a branch everyone had already reviewed. So immediately before merging, `git fetch` and diff the origin's `features/` tree against the branch point: every `.feature` added or changed since then needs migrating too, and every changed step definition needs re-checking. Do this **as the last step**, not when you start, and report what it turned up — a reviewer who approved the first batch has no reason to expect a second.

**Can you drive CI yourself? Check the remote.** `git remote get-url origin` (or the branch's push remote) gives the host:
- **a GitLab host** (gitlab.com or self-hosted) → driven with the **`glab`** CLI.
- **`github.com`** → driven with the **`gh`** (GitHub) CLI.
- **any other host** → not controllable from here → use the *fallback* below.

You can drive it only if the matching CLI is **installed and authenticated** — check `glab auth status` / `gh auth status`. If it's missing or not logged in, **don't try to authenticate it yourself**; take the fallback.

**When you can, run the whole loop yourself.** Opening the MR/PR is the migration's deliverable, so this is expected — but **never *merge* it** (the human reviews the migration and merges):

1. **Commit** the migration and **push** it to a **feature branch** — follow the repo's branch-naming conventions, and never push to the default branch. Announce what you're doing.
2. **Open the merge/pull request** against the default branch — `glab mr create …` / `gh pr create …` — which triggers CI. (A draft MR/PR is fine.)
3. **Monitor the pipeline to completion** — e.g. `glab ci status` / `glab ci view` (GitLab), `gh run watch` (GitHub).
4. **If it fails, fix and re-run:** pull the failing job's log (`glab ci trace` / `gh run view --log-failed`), fix it exactly as you fixed local failures — many will be the **CI-only failure classes** flagged at the top of Phase 3a — then push and re-monitor. Loop until green. **Some red runs look like infra noise but are real, reproducible bugs** — notably a `PG::UniqueViolation` on a `*_pkey` with a **hardcoded id** in the DETAIL, which is the dropped per-scenario pk-sequence reset (see *Port any per-scenario primary-key-sequence reset*) and is seed/shard-dependent, so only some shards fail. Distinguish those from genuine infra (a pg/redis "zombie container disconnected", a job that clears on retry) before dismissing — retrying hides the real bug.
5. **When it's green, hand off:** tell the human *"CI is green on `<MR/PR URL>` — ready for your review and merge,"* and **do not merge it yourself**.

**Don't push over a running pipeline.** If CI jobs are `interruptible: true`, a new push **cancels** the in-progress pipeline — and a *cancelled* pipeline is easy to misread as green. Let the current pipeline finish (check `glab ci status`) before pushing the next batch, and treat only a **`success`** result as green — never `canceled`/`skipped`. Check every pipeline's result before building on it; a single red run early can otherwise go unnoticed for several pushes.

**Practicalities.** A CI run takes minutes to ~an hour and monitoring blocks — if your harness forbids a long foreground wait, poll the pipeline status periodically instead (as with the quota ride-out). Quota pacing still applies; if a session limit hits mid-monitor, hand off with the MR link (see *Resume & session budget*) and a later session re-checks that pipeline and continues. **On resume, if the feature branch / MR already exists, reuse it — don't open a duplicate**; just re-check its pipeline and carry on. If the pipeline keeps failing on something you genuinely **can't** fix from here (a missing CI *service*, an infra flake outside the migration), **don't loop forever** — surface it as a `needs-attention` item with the MR link, as you would any local blocker. Never print or log auth tokens.

**Fallback — remote not controllable** (other host, or the CLI is missing/unauthenticated): don't push or open anything. Instead, in your closing report give the human the steps and offer to finish the job:

1. **Commit, push to a feature branch, and open a merge/pull request** — that triggers CI, which runs the full suite in the environment that actually matters and surfaces what local runs couldn't (flakiness under parallelism, missing CI services, driver/version mismatches).
2. **Offer explicitly:** *"If CI reports any failures, paste them back to me and I'll fix them."* You fixed local failures the same way; the migration isn't done until CI is green.

### Tell the human what remains — do NOT delete `features/`

**Leave the Cucumber test suite (`features/`) in the project.** Do not delete it. The human needs it to **manually review the migration** — comparing each original `.feature` against its migrated spec.

In your closing report to the human, state clearly:

- **This session's elapsed time.** `echo $(( $(date +%s) - $(head -1 tmp/mandoline/session-start.md) ))` seconds, reported human-readably (e.g. `This session: 3h 42m`). Elapsed always refers to the current session, not the whole multi-session migration.
- The original Cucumber tests are still in the `features/` folder for review.
- **Removing Cucumber is a separate, human-triggered step — do NOT do it as part of this migration.** Leave `features/`, the Cucumber gems, and all Cucumber config in place. When the human has finished reviewing and is ready to purge Cucumber for good, they can hand the repo to the standalone **`../mandoline/cucumber-removal-guide.md`** — it removes the Cucumber-only gems, the `features/` folder, `cucumber.yml`, the dedicated `cucumber` environment and its `database.yml` entry, `bin/cucumber`, cucumber rake tasks, the obsolete `knapsack_cucumber_report.json`, and any lingering CI/tooling references. Point them to it, but never invoke it yourself here.
- Note that **you have already removed the `cucumber` invocation from CI** (Phase 6 *Adjust CI*) — so the app's E2E suite already runs on RSpec; the removal guide only cleans up leftover references.
- **Lead with a loud `⚠️ NEEDS ATTENTION` section at the very top of the report**, before anything else — it is just the (reconciled) contents of `tmp/mandoline/needs-attention.md`, which you've kept current all along. It lists every **skipped or unverified scenario**, every **feature left without a migration marker** (e.g. blocked by a missing dependency), and every collision/ambiguity/step that needed human judgement — each with its file and a one-line reason. These are trivial to lose in a long report, so they go first and unmissable, not buried among routine notes.

A one-line reason is enough for a *skip*, but a **human *decision*** (where a faithful port and the app's behaviour genuinely disagree) needs enough to decide **in one shot**: for that item, give the origin feature and its step definitions, the port, and the relevant app code as repo-relative `path:line` with **verbatim quotes**, plus a verified statement of **why the two suites differ**. Present such decisions **one at a time**. (Agents produce this context well when asked — so ask for it.)
- **Point to the guide-feedback file.** The next person won't know it exists otherwise. State where it is and give a count plus a one-line list of the notable items, e.g.:

  > Guide-improvement notes are in `tmp/mandoline/guide-feedback.md` (13 items: the `have_table_with_rows` matcher bug, CSRF/forgery-protection setting, thread-local leakage, the parallelism rethink, serial-vs-parallel verification, …).

### Signal completion — `tmp/mandoline/finished.md`

**Only once *every* feature is `done` (migrated, green, and normalized by its worker)** — `progress.md` shows nothing left todo, and you have finished all of Phase 6 — create **`tmp/mandoline/finished.md`** as the done-signal a reviewing agent looks for. **If you drove CI yourself (a controllable remote), "finished Phase 6" includes a green pipeline** — don't signal completion on a red one; an unresolvable CI failure is a `needs-attention` hand-off, not a `finished.md`.

```bash
echo "migration complete: $(date -u +%FT%TZ)" > tmp/mandoline/finished.md
```

**Never create it on a partial stop.** If any feature is still todo and you're terminating for another reason — session budget or quota exhausted, the migration was scoped to only some features, or the human intervened — do **not** write `finished.md`; hand off via the clean-stop path instead (see *Resume & session budget*). Its presence must mean "the entire suite is migrated," nothing less — so a reviewing agent can trust it.


## Start transforming!

Now apply the migration according to the rules above. Don't change files in `features` — **one exception:** when a `.feature` is fully migrated, prepend the migration-marker comment (see `conversion-guide.md` → *Work scenario for scenario*). Otherwise `features/` stays untouched for the human's review (see Phase 6).

If you are unsure about something, ask me. But do not get hooked up on tiny details. You can also aggregate your questions and ask me in batch (e.g. after a full feature was migrated).

As you follow these guides, you will hit things that are wrong, vague, or missing. **Each time that happens, immediately append an entry to `tmp/mandoline/guide-feedback.md`** (see *Scratch files*) — write it the moment you notice, not from memory at the end. I use this file to revise the guides, so it must capture every issue as it occurs; leave the file in place at the end (it is feedback, not working state). If you reach the end and that file is empty, you almost certainly forgot to flush as you went.

