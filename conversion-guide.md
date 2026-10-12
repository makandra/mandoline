# Conversion guide — feature-spec craft & house style

This guide is the single source for the **craft** of converting Cucumber to RSpec feature specs: the house style your output must match, and the mechanics of converting step definitions (Phase 4) and features/scenarios (Phase 5). The orchestrator follows it while building the serial foundation; **fan-out workers follow it too** — it is what makes every migrated spec read as if one person wrote it by hand.

The main orchestration guide (`app-migration-guide.md`) covers everything else — preflight, environment, support-code migration, parallelism, finishing up — and references this file at Phases 4–5. Phase numbers mentioned here (Phase 1, 3, 6, …) refer to that guide.


## Worker reading order

If you are a fan-out worker, read this before migrating your assigned features, in order:

1. **This guide** — the house style below, then Phase 4 (converting a step definition) and Phase 5 (converting a feature/scenario).
2. **`tmp/mandoline/step-mapping.md`** — every step the foundation already converted. **Reuse these; never re-derive a step that is already mapped.**
3. **`spreewald-guide.md` / `cucumber_factory-guide.md`** — consult *on demand* only when you hit a Spreewald or factory step that is **not** yet in `step-mapping.md`.
4. **`spec/support/**`** — the foundation's helpers/matchers. **Call** them by name; you **may also add to or edit** them when your features need something they lack (see *Support code during fan-out*, below). Skim existing `spec/features/**` too as a style reference (shape and rhythm).
5. **Only if the orchestrator's brief says this is a Rails 2 / RSpec 1 app:** also read `rails2-guide.md`. It **overrides** the RSpec-specific mechanics below — no `feature`/`scenario`, no `expect` (you use `describe … type: :feature` + `.should`). On a modern app, don't read it; it would mislead you.

When this guide doesn't cover an edge case, look to the target app's **own** already-migrated `spec/features/**` and existing `spec/support/` for precedent — never another project's code.


## House style — what a migrated spec must look like

This is the authoritative house style; you do **not** need to study the reference apps to rediscover it. It is distilled primarily from our two most modern feature-spec apps; our older apps are secondary. If two references disagree, follow the modern ones.

### The skeleton

- **`feature` / `scenario`**, never `describe`/`it`. Use the bare `feature`/`scenario` keywords, not `RSpec.feature`.
- **No `type: :feature` metadata** — it is inferred from the `spec/features/` location (`config.infer_spec_type_from_file_location!`).
- **`js: true` marks what needs a real browser** — put it on the *scenario* (or on a wrapping `context`/`feature` when *every* example in that group needs JS), not scattered redundantly. Only tag what genuinely needs a browser; the rest run on the faster rack-test driver.
- Group clearly distinct situations with `context '…'`; keep nesting shallow.
- **Setup:** `let` for data a single scenario needs, `let!` for data shared across a feature's scenarios, `before { sign_in … }` for authentication.

### The rhythm — arrange → act → assert, in blank-separated beats

A scenario reads top-to-bottom as the user's journey. Blank lines separate the *beats* of that story; within a beat, statements are packed together. (The precise blank-line rules live in *Mechanical formatting rules* under Phase 5, below — this is the shape they produce.)

### Expectations

- `expect(page).to have_content(...)`, and **chain related assertions about the same page state with `.and`**, breaking the line after `.to`:

  ```ruby
  expect(page)
    .to have_current_path(root_path)
    .and have_flash(:success, 'Saved.')
  ```

- **Prefer `have_no_*` over `not_to have_*`** for negation (`have_no_content`, `have_no_css`, `have_no_button`) — it waits correctly instead of returning immediately. (Capybara's built-in matchers provide `have_no_*` for free; a **custom** matcher only has a `have_no_<name>` form if you defined its negated alias — see the Spreewald guide's matcher note — otherwise `.and have_no_<name>` in a chain raises `NoMethodError`.)
- Where the scenario implies it, assert **both** rendered state *and* model state — e.g. `expect(user.reload.locked).to be(true)` or `expect(company).to have_attributes(name: 'ACME Inc.', city: 'Springfield')` — proving the behaviour, not just the screen.
- **Before porting an *ordered* assertion, read the query that produces the rows.** A Cucumber table/list step often carries an implicit order the database never guaranteed: if the backing finder or scope has **no `ORDER BY`** (and the spec doesn't click a sort control), row order is whatever Postgres returns that day — stable for years, then a coin flip once the suite is resharded. Emit the unordered variant (`have_table_with_rows(...).in_any_order`, or two pairwise assertions instead of one `have_content_in_order`) and leave a one-line comment saying the query is unordered. Only assert order when the code guarantees it. **And scope every positional assertion to a container:** `have_content_in_order('0001', '0002', '0003')` against the whole `page` is satisfied by those tokens appearing in some *other* column, in a footer, or in a hidden template — assert within the table/list, or read the column explicitly (`all('table tbody tr td:first-child').map(&:text)`) and compare with `eq`.
- **Group assertions by scope — an explicit algorithm.** Scoped checks *cohere*: several assertions about one element fragment describe one thing, so they belong in one `within(selector) do … end`. That names the selector once (**DRY**), and because `within` resolves its selector via `find`, the block also **waits for it** — so you never need a separate `have_css('sel')` presence check. Don't just chain assertions in the Cucumber step order; lay out each **observation** — a *maximal run of consecutive assertions with no interaction between them* (an interaction like `click_on` / `check` / `visit` ends the observation and begins the next beat) — by this procedure:

  1. **Partition *this observation's* assertions by scope** — page-level (path, flash, unscoped text), and one group per element-fragment selector; a fragment may contain sub-fragments, so partition those recursively. Group only *these consecutive* assertions — never reach across an interaction into another observation; the *same* selector appearing in a later observation is a separate `within` block (a different beat), and that's correct.
  2. **Emit one `expect(page).to … .and …` chain** for everything expressible as a lone page-level matcher: the page-level assertions, *plus* any fragment you assert only **once** (written `have_css('sel', text: '…')`). **For a `table`/`link`/`button`/form-`field` fragment, use the element-specific matcher, not `have_css`** — `rubocop-capybara`'s `Capybara/SpecificMatcher` rejects `have_css('table.cars', text:)` in favour of `have_table(class: 'cars', text:)` (likewise `have_link`/`have_button`/`have_field`). The dev didn't consciously enable that cop — it simply had no feature specs to scan until this migration, so it activates the moment you add them. `have_css` is the more expressive matcher, so when a filter you need can't be expressed by the specific one, keep `have_css` and add `# rubocop:disable Capybara/SpecificMatcher` for that line/section. And a filter-only specific matcher (`have_table(class:)` with no positional locator) must **stand alone**, per the chained-modifier rule.
  3. **Emit a `within('sel') do … end` block** for each fragment you assert **two or more** times — chain the inner checks; a sub-fragment asserted 2+ times becomes a **nested** `within` (a sub-fragment asserted once stays a `have_css('.sub', text:)` inside).
  4. **Fold a following interaction *on the same selector* into the block** — if the next step is an interaction scoped to the **same** selector as the block (e.g. `click_on` / `check` inside `'sel'`), put it inside *that* `within`: assertions, blank line, then the interaction. Only when the selector matches — an interaction scoped to a *different* selector gets its **own** `within`, never merged in. (So never leave two consecutive `within` blocks on the *same* selector with no interaction between them — merge those; `within`s on *different* selectors, or *separated* by an interaction, stay separate.) **A single scoped assertion followed by a same-selector interaction also forms a block** — the scope is *used twice* (assert + interact), so wrap both in one `within('sel')` (assertion first, interaction last) rather than a page-level `have_css` *plus* a separate `within` for the click. The lone-assertion→page-level `have_css` rule (step 2) is only for a **truly lone** scoped assertion — nothing else touches that scope.
     **At most one interaction per `within`, and it is the block's *last* statement.** A second interaction — or *any* assertion that would come after an interaction — starts a **new** `within` (re-resolving the scope fresh). Rationale, not just neatness: `within('sel')` resolves `sel` **once** at entry, so after an interaction the scoped element may be gone. Capybara auto-reloads a *re-rendered* same-selector scope (so an in-place toggle then a re-assert happens to work), but it **cannot** reload after a **navigation or removal** — a later scoped read then raises `StaleElementReferenceError` / `ElementNotFound`. Making the interaction last, one per block, makes this safe regardless of what the interaction did. And **never put `visit` inside a `within`** — it always leaves the scoped element behind.

  **Exception — a run of *non-navigating* field interactions may share one `within`.** When several consecutive `fill_in`/`choose`/`select`/`check` calls target the **same** scope and none of them navigates away or re-renders/removes the scope (a plain form that isn't rebuilt between fields — e.g. nine address fields `within('.billing-address')`), keep them in a **single** `within('sel') do … end` rather than one block per field: the stale-scope rationale doesn't apply, and N one-line blocks are pure boilerplate. The moment an interaction *does* re-render or navigate (a submit, an `up-validate` that swaps the fragment), end the block there and start fresh.

  **Reordering to group is safe for *reads* only.** Pure assertions read the already-settled DOM and don't change it, so reordering them to group is behavior-neutral — but **never reorder across an *action*** (`click_on`, `check`, `fill_in`, `visit`, …); that's a new beat. Only pull an assertion *into* a `within` if its content truly lives in that fragment — scoping it is *stricter* (a real semantic change), so keep genuinely page-level checks in the page-level chain. (And never write `within(sel) { have_content('…') }` for a lone scoped check — that's step 2's `have_css`.)

  **`within_frame` follows the same rules as `within`.** It's just a different kind of scope — apply the one-interaction-per-block, merge-consecutive-same-scope, and reorder-reads-only rules to `within_frame` exactly as to `within`.

  **A lookup carrying an explicit `:wait` is its own group — never merge it.** Keep any assertion with a non-default `:wait` (`have_css(…, wait: 5)`, `have_content(…, wait: 5)`, …) as a **standalone** statement: don't fold it into a `.and` chain — Capybara's compound wraps both matchers in one `synchronize` at the *default* wait and silently swallows the inner `:wait` — and don't bury it among other assertions in a shared `within`. If a *scope* itself appears asynchronously, put the wait on the scope find — `within('sel', wait: 5) do … end` — which is a different thing (the wait locates the scope; inner lookups keep their defaults).

  **A leading comment is a label on the statement beneath it — treat the two as one atom.** When you reorder or merge, a narrative comment travels with the assertion/interaction it sits above. And for mergeability it is *transparent*: a comment between two same-selector `within`s does **not** separate them (only an interaction or a differently-scoped assertion does) — so merge those blocks and fold the comment inside, above its statement.

  **Regrouping changes layout, never assertions.** Merging/reordering/scoping rearranges *how* checks are grouped — it never changes *what* is asserted. Don't swap an assertion for a "simpler" matcher or a foundation helper, especially one carrying an explanatory comment or edge-case note (e.g. an empty Rails password field renders `value=nil`, so it needs `expect(find_field('Password').value).to be_blank`, **not** a generic `expect_field_blank`). If the author special-cased it, there was a reason: regroup *around* the assertion and leave it intact.

  **Don't over-chain large matchers.** Clustering (step 2) is for *related* page-level reads. A **single** big multi-line matcher (a `have_table_with_rows` with many rows, a long `have_content_in_order`) may join the chain — but stacking **two or more** of them into one `.and` chain hurts readability more than the clustering helps, so leave those as separate `expect(page)` statements. Chain the small matchers (paths, flashes, `have_content`/`have_no_content`, a lone `have_css`) freely. **A matcher carrying a *chained modifier* must be its own statement — this one's correctness, not just readability.** `expect(page).to have_content('X').and have_table_with_rows(...).exactly` parses as `have_content('X').and(have_table_with_rows(...)).exactly` — the `.exactly` binds to the **compound** matcher, so your row-count constraint is **silently dropped** and the spec passes laxer. The same trap hits any `chain(...)`-based modifier (`.in_any_order`, custom ones); keep the modifier-carrying matcher standalone. **A matcher whose *only* constraint is a filter option, with no positional locator** — `have_link(text: 'X')`, `have_button(title: …)` — must **also** stand alone: Capybara's compound `and` re-targets the node and re-runs each matcher, and such a filter-only matcher **silently loses its filter** in that re-run (a `have_link(text: 'X')` starts matching *any* link, so it passes or fails for the wrong reason — the failure message never even mentions the text). Give it its own `expect`. (A matcher with a positional locator — `have_link('X')`, `have_css('a', text: …)` — is fine in a chain.)

  **Two easy misses inside one observation.** (a) **Field-value pairs are a cluster too** — consecutive `have_field(...)` checks belong in one chain, even though they don't "look like a list" the way a `have_content` run does. (b) **A non-chainable assertion does not end the observation** — only an *interaction* does. A custom-helper assertion (e.g. `expect_datetime(...)`) or an `expect(find_field(...).value).to …` only *reads* the page, so it stays inside the same observation: cluster the surrounding page-level matchers into one chain and let the non-chainable assertion sit as its own statement (order among pure reads is free).

  **Example — field-value pairs are one chain:**

  ```ruby
  # ✗ two statements for one observation
  expect(page).to have_field('Title', with: 'Annual report')
  expect(page).to have_field('Description', with: 'Figures for the year')

  # ✓
  expect(page)
    .to have_field('Title', with: 'Annual report')
    .and have_field('Description', with: 'Figures for the year')
  ```

  **Example — a non-chainable assertion doesn't split the observation** (only an interaction would):

  ```ruby
  # ✗ expect_datetime (a custom helper — can't join a matcher chain) mistaken for a beat
  #   boundary, leaving two separate expect(page) chains around it
  expect(page).to have_field('Title', with: 'My photo collection')
  expect_datetime('Available from', '23.05.2342', '13:37')
  expect(page).to have_content('Sunsets').and have_content('Mountains')

  # ✓ one observation: page-level matchers cluster into one chain; the non-chainable
  #   assertion is its own statement in the same beat (pure reads reorder freely)
  expect(page)
    .to have_field('Title', with: 'My photo collection')
    .and have_content('Sunsets')
    .and have_content('Mountains')
  expect_datetime('Available from', '23.05.2342', '13:37')
  ```

  **Example — different selectors, each asserted once → one flat `have_css` chain, no `within`** (the common case; don't reach for `within` here):

  ```ruby
  expect(page)
    .to have_css('.thumbs-up', text: '0')
    .and have_css('.thumbs-down', text: '0')
  ```

  **Example — page-level clustering (step 2) + nested sub-fragments (step 3):**

  ```ruby
  # ✗ page-level check stranded after the block; .thumbs-up/.thumbs-down each repeated in a flat chain
  expect(page).to have_current_path(review_path(review), ignore_query: true)

  within('up-modal-content') do
    expect(page)
      .to have_css('.thumbs-up', text: 'Rated')
      .and have_css('.thumbs-up', text: '1')
      .and have_css('.thumbs-down', text: '0')
      .and have_css('.thumbs-down', text: 'Rate')
  end

  expect(page).to have_content('Ratings update nightly.')

  # ✓ page-level assertions clustered into one chain; each 2×-asserted sub-fragment its own nested within
  expect(page)
    .to have_current_path(review_path(review), ignore_query: true)
    .and have_content('Ratings update nightly.')

  within('up-modal-content') do
    within('.thumbs-up') do
      expect(page)
        .to have_content('Rated')
        .and have_content('1')
    end

    within('.thumbs-down') do
      expect(page)
        .to have_content('0')
        .and have_content('Rate')
    end
  end
  ```

  **Example — fold a scoped interaction into its fragment's block (step 4):**

  ```ruby
  # ✗ two withins on the same selector — one asserts, the next acts
  within('.event-card') do
    expect(page)
      .to have_checked_field('All day')
      .and have_link('Reschedule')
  end

  within('.event-card') do
    click_on 'Reschedule'
  end

  # ✓ one within: scoped assertions, blank line, then the scoped interaction
  within('.event-card') do
    expect(page)
      .to have_checked_field('All day')
      .and have_link('Reschedule')

    click_on 'Reschedule'
  end
  ```

  Also use `within('sel') do … end` for a scope wrapping an *interaction* or a *non-content* assertion (`have_checked_field`, a custom matcher, …) that can't take a selector directly.

### Helpers & selectors

- **Call the foundation's helpers by name** (`sign_in`, `have_flash`, `have_table_with_rows`, plus whatever the app defines — modal/navigation/etc.); they were built in Phase 3/4. Don't inline what the foundation already provides.
- **Scope with `within('…') do … end`** — always the block form, never one-line braces — for interactions, field/checkbox assertions, and multi-statement scopes. For a scoped *content* assertion, use `have_css('…', text: '…')` instead (see *Expectations*). Prefer stable hooks (test-ids, semantic selectors) over brittle CSS. For JS confirm dialogs use `accept_confirm('…?') do … end`.
- **Factories:** `create(:model, :trait, attr: …)` — traits right after the model, named attributes for clarity, nested `create(...)` for associations, trailing commas on multi-line creates.

### Deliberate deviations — keep these; do **not** "correct" them to match the reference apps

A few helpers/matchers this migration uses differ from the reference apps on purpose, to keep the conversion mechanical. Follow the reference apps for how specs *read*; use **these** for what they *call*:

- **`have_flash('text')`** (text only), or **`have_flash(:success, 'text')`** when the app's flash steps carry a meaningful type — a lighter take on the reference apps' `have_flash_message(:type, 'text')`. Default to text-only when the steps only state text; add the type when they consistently state one (see the Spreewald guide's `have_flash`).
- **`have_table_with_rows(...)`** with lax subsequence-column matching — *not* the reference apps' stricter `have_table_with_contents(...)`. Lets Cucumber table data migrate unchanged.
- **Matchers retry internally** (via `patiently_wait_until`) rather than relying on capybara-lockstep alone as the reference apps do.
- **DatabaseCleaner** as this guide sets it up — keep whatever cleaning strategy the app already has (Phase 3a) and use the guide's only for gaps; don't switch to the reference apps' transactional fixtures.

So in the examples below, matcher *names* like `have_page_header`, `within_modal`, `have_modal`, `be_signed_in` are illustrative of the reference apps' own helpers — use them only if the app you are migrating actually defines equivalents; otherwise fall back to plain Capybara.

### Canonical examples

Study the **shape, rhythm and story**, not the exact helper names.

**1 — a simple form flow that reads as a story** (arrange → act → assert):

```ruby
feature 'sign-in' do

  scenario 'users can sign in' do
    user = create(:user, email: 'user@example.com', password: 'secret123', first_name: 'Bruce', last_name: 'Wayne')

    visit new_user_session_path
    fill_in 'Email', with: 'user@example.com'
    fill_in 'Password', with: 'secret123'
    click_button 'Sign in'

    expect(page)
      .to have_current_path(root_path)
      .and have_flash(:success, 'Signed in successfully.')
      .and have_content('Bruce Wayne')
  end

end
```

- one `create` → **blank line** → act → assert; no other blank lines needed in a short scenario.
- related assertions chained with `.and`, not stacked as separate `expect`s.

**2 — a multi-beat narrative asserting UI *and* model state** (act → assert → change → re-assert):

```ruby
feature 'session' do

  scenario 'a user is signed out when their account is locked' do
    user = create(:user, name: 'Batman')
    sign_in user

    visit admin_users_path
    expect(user.sessions.size).to eq(1)
    expect(page).to have_current_path(admin_users_path)

    user.update!(locked: true)
    expect(user.sessions.size).to eq(0)

    visit admin_users_path
    expect(page).to have_current_path(sign_in_path)
  end

end
```

- a genuine act → assert → change-state → re-assert story — the shape many Cucumber scenarios have.
- blank lines separate the beats (sign in & verify → lock → re-check); within a beat, statements are packed.

**3 — a JS scenario with a modal and a confirmation dialog** (`js: true`, scoped interaction):

```ruby
feature 'manage projects', js: true do
  let(:admin) { create(:user, :admin) }

  before { sign_in admin }

  scenario 'an admin can delete a project' do
    create(:project, name: 'Example Project')

    visit projects_path

    within '.projects' do
      click_on 'Example Project'
    end

    accept_confirm 'Delete project "Example Project"?' do
      click_on 'Delete'
    end

    expect(page)
      .to have_current_path(projects_path)
      .and have_flash(:success, 'Project deleted.')
      .and have_no_content('Example Project')
  end

end
```

- `js: true` on the scenario; interaction scoped with `within`; the confirm dialog handled by `accept_confirm { … }`.

**4 — a table assertion** (using this guide's `have_table_with_rows`):

```ruby
scenario 'the list shows all projects' do
  create(:project, code: 'ALPHA', name: 'Alpha Project')
  create(:project, code: 'BETA',  name: 'Beta Project')

  visit projects_path

  expect(page).to have_table_with_rows(
    ['Code',  'Name'],
    ['ALPHA', 'Alpha Project'],
    ['BETA',  'Beta Project'],
  )
end
```

**5 — an email assertion** (mail goes straight against `ActionMailer::Base.deliveries`; see the Spreewald mail guide):

```ruby
scenario 'signing up sends a verification email' do
  visit new_registration_path
  fill_in 'Email', with: 'bruce@example.com'
  click_button 'Create account'

  expect(last_mail.subject).to eq('Verify your email address')
  expect(last_mail.to).to contain_exactly('bruce@example.com')
end
```

- the app needs a global `config.before { ActionMailer::Base.deliveries.clear }` so mail doesn't leak across examples (Phase 3).

**6 — validation errors keep the user on the form:**

```ruby
scenario 'submitting an empty form shows errors' do
  visit new_registration_path

  click_button 'Create account'

  expect(page)
    .to have_current_path(new_registration_path)
    .and have_field_error('Email', "can't be blank")
end
```


## Support code during fan-out — edit shared support directly, and log it

If you are a **fan-out worker**, you share one **live** `spec/support/` tree with the other workers — it is not frozen. When a feature needs a helper or matcher the foundation doesn't provide, or an existing one needs changing:

- **Add it to, or edit it in, the shared support tree directly** — a real helper module or `RSpec::Matchers.define` matcher with a clear name. No per-worker files, no inlining-for-isolation. Two workers *could* touch the same support code at once; with a stabilized foundation that's unlikely to matter, and we accept the small risk rather than block workers on a mid-fan-out merge. (The final verification run, plus CI, catch conflicts.) The **Phase 6 clean-up** later consolidates *duplication* across the tree — but it is not a conflict-fixer and not a crutch for sloppy code, so **write clean, final-quality helpers now.**
- **Log every support-code change** to your **own** `tmp/mandoline/support-changes-<your-id>.md` — one line each: `timestamp · file · helper/matcher name · what changed`. Your own file (not a shared one) so concurrent logging never clobbers. The orchestrator reads all of these at the final verification to know where to look if something breaks.
- **If you change an *existing* shared helper/matcher** (its signature or behavior), **grep for its other call sites** — in features outside your own batch — and fix them too. Keep this narrow: adjust the call sites you find, don't launch a broad refactor.
- **Don't edit `step-mapping.md`** — it's the orchestrator's record. Note any new step→method mappings in your completion summary instead.


# Phase 4 — Converting step definitions

Every step definition begins with `When`, `Then` or `Given`. A file named like `features/step_definition/$topic_steps.rb` usually groups multiple step definitions for a topic (`$topic` in the example). Note that every step definition can be called with either `When`, `Then`, `Given`, `And` or `But`, regardless of the leading word used in its definition.

### Convert steps on demand — don't bulk-convert every file up front

Don't bulk-convert the step-definition files up front (there can be 40+, many unused or single-use). **The same goes for a cross-cutting *helper file*** — porting a whole `features/support/*_steps.rb` module up front (say, all 12 form helpers) reliably leaves **speculative dead helpers** whose steps no migrated scenario exercises (the Phase 6 census will flag them, but it's better not to write them): port each method **on demand**, exactly like a step def. Convert on demand:

1. **Up front, convert only the obvious infrastructure** — typically the auth/sign-in helper and any shared custom matcher (e.g. flash messages); the first feature needs these.
2. **Convert everything else on demand:** the first time you hit an unconverted step while migrating a feature (Phase 5), convert it then.
3. **Record every conversion in `step-mapping.md`** (see *State, progress, and resuming*), and **reuse the mapping** on every later feature — never re-convert. A step used by many features is thus converted once and becomes a shared helper naturally.

**Helper vs. inline — decide per step, with a quick grep.** When you convert a step on demand, the real choice is whether to make a named helper or inline the Capybara call. Check how widely the step is used (run from inside the migrating repo, where `features/` is a normal directory):

```bash
rg -l 'I sign in as' features/ | wc -l   # how many distinct feature files use it (use a distinctive literal slice of the prose)
rg -c 'I sign in as' features/           # total occurrences, per file
```

- Used in **many files** → make a named helper (done once, then reused via `step-mapping.md`).
- Used in **one file and trivial** → inline it (see *Convert trivial step definitions* below).

### How to convert one step definition

Convert each step definition into a Ruby method. Each step definition should become one Ruby method in a module. The goal is to use these methods as helpers in an RSpec feature spec.

**Name that module so it cannot collide with an application constant — give it a `…Steps` suffix.** A step-definition file named after a domain concept invites a module named after it too (`module Invoices`, `module Reports`), and a bare model/namespace name **reopens the application's own constant** instead of defining a new one (or, under Zeitwerk, pre-empts its autoloading). That corrupts the *app*, not just the suite, and the failure surfaces far from `spec/support/`. So always `module InvoiceSteps` / `module ReportSteps`, and before settling on a name, grep `app/` for it.

Go through each step definition and derive a Ruby method name. The method should be named after what the step performs or asserts. You can derive meaning from the definition pattern (the first argument to `When`, `Then` or `Given`) or from the step definition's block argument. 

The step definition's block should become the body of the generated method.

Do **not** carry the Gherkin step pattern into a comment. Instead, where the method name doesn't already say what the method does, place a short **plain-English** comment over it describing the *mechanics* or *intent* (the "how"/"why"). If the name already says it, write **no** comment — and never write one that merely restates the name (a bare `# Signs in as Joe` over `sign_in_as_joe` is noise, arguably worse than the step pattern because it pretends to add value). Never leave a `…_steps.rb`/Spreewald/Cucumber reference in a comment.

Record which step definition maps to which method in `step-mapping.md` (see *State, progress, and resuming*), as we are going to need this mapping later. That file **is** the step→method mapping; the inline comment is not — comments are for human readers only, so don't keep a Gherkin signature "for traceability."

Example INPUT:

```ruby
When /^I sign in as Joe$/ do
  fill_in 'E-mail', with: 'Joe'
  fill_in 'Password', with: 'secret'
  click_button 'Sign in'
end
```

Desired OUTPUT:

```ruby
# Fills in Joe's credentials and submits the sign-in form.
def sign_in_as_joe
  fill_in 'E-mail', with: 'Joe'
  fill_in 'Password', with: 'secret'
  click_button 'Sign in'
end
```

Each capture group in the definition pattern should become a keyword argument of the generated Ruby method.

Example INPUT:

```ruby
Then /^I should( not)? see an? (.+?) flash with message "(.+?)"$/ do |negate, type, text|
  expectation = negate ? :should_not : :should
  page.send expectation, have_css(".alert.alert-#{type}", text: text)
end
```

Desired OUTPUT:

```ruby
# Asserts a Bootstrap `.alert-<type>` flash containing the text is shown
# (or, with `negate:`, that it is not).
def expect_flash_message(text:, type:, negate: false)
  if negate
    expect(page).to have_no_css(".alert.alert-#{type}", text: text)
  else
    expect(page).to have_css(".alert.alert-#{type}", text: text)
  end
end
```

Perform this transformation for each step definition in the INPUT code.


### Rewrite old `should` syntax to `expect` syntax

When you copy a step definition's body into a generated method, **convert any RSpec `should`/`should_not` syntax to the modern `expect` syntax.** Cucumber step definitions are old and frequently use `obj.should` / `obj.should_not` / `page.send(:should, …)`.

We do this for **house-style consistency** (the reference apps use `expect` throughout). Whether a verbatim `.should` would actually *work* is app-dependent: some apps disable the `should` syntax (then `.should` raises `NoMethodError`), while others still enable both syntaxes (e.g. `config.expect_with(:rspec) { |c| c.syntax = [:should, :expect] }` in `spec_helper.rb`, where `.should` keeps working). Convert to `expect` either way — don't rely on `should` being available, and don't migrate any `require '.../should_syntax'`.

Translate mechanically:

| Old `should` syntax | Modern `expect` syntax |
| --- | --- |
| `page.should have_css('.x')` | `expect(page).to have_css('.x')` |
| `page.should_not have_css('.x')` | `expect(page).to have_no_css('.x')` (preferred) or `expect(page).not_to have_css('.x')` |
| `result.should == 5` | `expect(result).to eq(5)` |
| `obj.should be_present` | `expect(obj).to be_present` |

(The `expect_flash_message` example above shows this: the original `page.send expectation, have_css(...)` becomes a positive/negative `expect(page)` pair, with `have_no_css` for the negation — see convention #5 in `spreewald-guide.md` for why `have_no_*` is preferred over `not_to have_*`.)


### Mapping of English to route paths

Cucumber scenarios have a mapping of English prose to a Rails route in `features/support/paths.rb`.
E.g. `the list of users` becomes `users_path` or `"/users"`.

Cucumber step definitions can call this mapping using `path_to(english) # returns path string`.

RSpec feature specs don't use such a mapping and just call the route helper directly. E.g. `When I go to the list of users` becomes just `visit(users_path)`.

**Always inline the *result*; never port `paths.rb` to a helper**, however elaborate its prose-to-route inference — the result is always a plain route helper or path string (`new_user_path`, `users_path`, `"/users"`). For a record the resolver looked up at runtime (`the note` → `note_path(Note.last)`):

- **Factory-created record** → you already hold it as a local var (from the cucumber_factory conversion): write `note_path(note)`.
- **Record created through the UI** (a CRUD "create" flow, no local var) → keep a runtime lookup: `note_path(Note.last!)` or `Note.find_by!(title: 'Foo')`.

The same rule applies to `selectors.rb` (below).


### Mapping of English to selectors

Cucumber scenarios have a mapping of English prose to a CSS selector in `features/support/selectors.rb`.
E.g. `the logout button` becomes `#sign-out-button`.

Cucumber step definitions can call this mapping using `selector_for(english) # returns CSS selector string`.

RSpec feature specs don't use such a mapping and just mention the selector directly. E.g. `When I click on the logout button` becomes just `find('#sign-out-button').click`.

(Note: `click_button` / `click_on` locate buttons by visible label, value, id, name or title — **not** by CSS selector. So a `selector_for` alias that resolves to a CSS selector like `#sign-out-button` must be clicked via `find('#sign-out-button').click`, mirroring the Spreewald guide's `click_on_element` rule.)

**Always inline the *result*; never port `selectors.rb` to a helper** — same rule as `paths.rb`. However elaborate the prose-to-selector mapping (some are BEM/ARIA auto-mappers: `the foo's bar` → `.foo--bar, [aria-label="…"]`), the result is always a concrete CSS selector string — resolve it and inline that string.

**Expand a *composed* selector by hand and check what it actually matches.** When an alias interpolates another alias, a comma inside the inner one silently turns a compound selector into extra top-level alternatives (a CSS *group* selector) — e.g. a `menu_list` that already contains a comma makes `"#{menu_list} li.a, #{menu_list} li.b"` match four things, one of them the whole list, so the assertion is far laxer than the prose reads. Inlining it verbatim bakes that in; if the result is weaker than the step's wording, say so in the summary. A safe way to inline a genuinely *complex* selector is to wrap it in `:is(...)`, which neutralises the comma-grouping — **but only in `js: true` specs** (Selenium's native CSS); under rack-test Capybara translates CSS via Nokogiri, which **raises** on `:is(...)`, so don't use it in non-JS specs (and don't bother for simple selectors — it's just noise).


### Standard web app steps are defined by the spreewald gem

Spreewald is a gem with predefined step definitions for common E2E tasks in web apps. E.g. clicking links, completing forms, asserting presence of text or DOM elements. In many ways it's a wrapper around Capybara, with some extra step definitions for things like checking e-mail dispatch.

The Cucumber test suite uses Spreewald **HEAVILY**, often choosing to write scenarios almost entire from predefined steps.

There is an extensive guide for recognizing and migrating Spreewald-based steps in `./spreewald-guide.md`. You must read and apply the rules found in that file.


### Factory steps are defined by the cucumber_factory gem

Cucumber Factory is a gem that allows to call factory methods from predefined step definitions.

The Cucumber test suite uses Cucumber factory **HEAVILY**, and rarely writes a custom step definition that only calls a factory.

There is an extensive guide for recognizing and migrating cucumber_factory steps in `./cucumber_factory-guide.md`. You must read and apply the rules found in that file.


### Remove redundant `patiently`

Many step definitions are wrapped in a `patiently do ... end` block.

This is often unnecessary (and can be dropped), because (1) Capybara automatically retries failed element lookups internally and (2) most apps use capybara-lockstep to wait for AJAX requests between test commands. These are two orthogonal mechanisms that each independently make many `patiently` wraps redundant.

**When an origin step used `patiently` to wait out AJAX-driven state** (a button disabled while data loads, a loading overlay that arrives late), the stable replacement is a plain **Capybara matcher on the DOM marker** that state produces — `expect(page).to have_css('.loading-overlay')` — not a `patiently` wrap. **Capybara's own matchers already retry — that's the real reason `patiently` is redundant**: point one at the settled marker and it waits. capybara-lockstep is a *complementary, layered* sync (it waits out the AJAX so the matcher usually finds the marker immediately), easing the load on Capybara's retry — not the mechanism you depend on. (And recall `patiently` retries *every* exception, so a stray `patiently` wrap can also hide a real error.)

In the rare cases where we *do* need an explicit retry mechanism for a block of multiple Ruby commands (that must be retried as a block, not individually), RSpec example apps provide a similar `patiently do ... end` command.


### Convert trivial step definitions to one-line Capybara commands

The default rule above generates one helper method per step definition and groups them in a module. For **trivial** step definitions, prefer **inlining** the Capybara call directly at each call site in the feature spec instead of generating a helper. This keeps the spec readable as plain Capybara — the same philosophy the Spreewald guide applies, where most Spreewald steps map directly to a Capybara call with no helper at all.

A step definition is "trivial" when its body is essentially a **single, self-evident Capybara call** with no app-specific logic, and the prose adds no meaning a reader of the Capybara call wouldn't already have.

Example INPUT step definition:

```ruby
When /^I save the form$/ do
  first('[type=submit]').click
end
```

Used in a scenario as:

```cucumber
When I save the form
```

Instead of generating a `save_form` helper, inline the call in the feature spec:

```ruby
first('[type=submit]').click
```

**When to keep the helper instead of inlining:**

- The body is more than a line or two, or contains non-obvious logic.
- The step is used in **many** scenarios, so a named helper documents intent and removes duplication (e.g. `sign_in_as_joe`).
- The prose carries domain meaning that the raw Capybara call would lose (e.g. `I sign in as Joe` is clearer than three `fill_in`/`click_button` lines).

When in doubt, keep the helper — it's easy to inline later, and a named helper is never wrong. The point of this section is only that you are **not required** to manufacture a helper for a step whose body is a single trivial Capybara call.

Steps defined by Spreewald and cucumber_factory are **always** mapped directly per their guides (`./spreewald-guide.md`, `./cucumber_factory-guide.md`) and never become helpers in your generated module.


### Step definitions that call other steps

Some step definitions invoke *other* steps by their Gherkin prose instead of calling Ruby directly. Two forms:

```ruby
step 'I should be logged in'           # one step

many_steps <<~GHERKIN                   # several steps (also seen as `steps "..."`)
  When I am logged in
  Then I should see "Welcome"
GHERKIN
```

**Replace each invoked step with the Ruby it maps to** — look the prose up in `step-mapping.md` (or convert it now), then call that helper / Spreewald / cucumber_factory mapping. So `step 'I should be logged in'` → `expect_logged_in`; a `many_steps`/`steps` block → the sequence of mapped calls. **Never leave `step`/`steps`/`many_steps` in the output** — those don't exist outside Cucumber.

### A step body may depend on Spreewald's *support* helpers

Beyond predefined *steps*, app step definitions sometimes call Spreewald's internal *support* helpers — e.g. `patiently`, `with_scope`, `_selector_for`, `javascript_capable?` (from `spreewald_support/*`). These vanish along with Cucumber, so a copied body that calls them will break. When a step body depends on such a helper, recreate the needed helper in your support tree (e.g. `spec/support/feature_steps/spreewald_compat.rb`) — the Spreewald guide already inlines a `patiently` implementation you can reuse; read Spreewald's `lib/spreewald_support/` (find it with `bundle show spreewald`) for the others. **Read the source and reimplement — don't `require` the Spreewald file:** some end in a top-level `World(...)` call (e.g. `tolerance_for_selenium_sync_issues.rb`) that raises `NoMethodError: undefined method 'build_rb_world_factory' for nil` outside a Cucumber process. And the recreated helper must be **self-contained** anyway: Cucumber-removal deletes Spreewald later, so it can't depend on `spreewald_support` at runtime. Prefer eliminating the dependency where the rules here already give a direct Capybara equivalent (e.g. dropping `patiently`, inlining `with_scope` as `within`).

### Watch for app overrides of predefined steps

An app can shadow a Spreewald or cucumber_factory step with its **own** definition in `features/step_definitions/` (cucumber_priority registers the gem steps as `.overridable`). So if a predefined-step mapping you applied **fails after migration**, suspect an override: check that app's `features/step_definitions/` for a step whose regexp also matches the line, and if one exists, convert per that app-specific definition instead of the guide's generic mapping. (Both sub-guides note this; it's easiest to spot when a "should have just worked" Spreewald/factory step behaves unexpectedly.)

**To find overrides cheaply, resolve which step definition each line binds to — but don't reach for `--format usage` naively.** `cucumber --dry-run --format usage` prints usage for **every** step definition in the *project* (a wall of output), and a `… within …` line binds to Spreewald's wrapper regex so its *inner* step shows up as "NOT MATCHED" — which is exactly where an app override matters. Instead: use `cucumber --dry-run --format stepdefs`, or `cucumber --dry-run --format usage --no-color > /tmp/usage` and pair *your* feature's lines with their defs (an `awk` pass keyed on the feature's path), and **resolve a `… within …` line's inner step by hand** against the app's step definitions. Scoped that way it stays a cheap static check (no browser, no execution): an app step shadowing a Spreewald/predefined one (e.g. `form_steps.rb` shadowing `"X" should be selected for "Y"`) is then visible before you map against the wrong semantics.


# Phase 5 — Converting features and scenarios

With the support code and the cross-cutting step definitions in place (Phases 3–4), translate the `.feature` files themselves into feature specs. Convert any remaining app-specific steps **on demand** as you reach them (Phase 4), recording each in `step-mapping.md` so it's reused, not re-derived.


### Mechanical formatting rules

Beyond mapping steps correctly, the generated specs must *look* hand-written in the **house style** above. This section is the complete set of **mechanical formatting rules** — the purely mechanical layout of a spec (blank lines, expectation chaining, variable naming). Each **worker applies this section in its final whole-file normalization pass** (the last step before it marks a feature done, over the settled grouping); RuboCop and the Phase 6 verification run are the backstops.

**RuboCop handles some of these and not others.** Quote style, trailing commas, indentation and alignment all get normalised by `bundle exec rubocop -A` in Phase 6, so don't fuss over them. But the blank-line layout and the variable naming below are **yours to get right** — no linter understands them (see *You must enforce these yourself*, at the end of this section). They are consistent across the reference apps.

#### Blank lines separate the beats

A scenario reads as a sequence of blank-separated *beats* (arrange → act → assert). **Within a beat, statements are packed together** with no blank line between them — an action and the assertion(s) about its result sit together. Put a blank line:

- **after the test-data setup**, before the first action;
- **between each act→assert cycle** (after an assertion, before the next action), and around any mid-scenario re-setup;
- **after a `visit`** — a page navigation is its own beat. It's *recommended* (not required) to follow a `visit` with a single-line assertion that you reached the destination (title / `current_path` / a heading): a cheap sync anchor that fails *clearly* if navigation was redirected (e.g. access-denied), instead of a confusing error later when an interaction acts on the wrong page. **Pack that arrival assertion directly onto the `visit`, no blank line between them** — it observes the `visit`'s result, so the two are one beat; the blank line goes *after* the assertion, before the next beat. `visit` stands alone only when its follower is *not* that arrival assertion — a multi-line block, or an interaction. (WebDriver already blocks `visit` until the `load` event, so this is about error quality, not correctness.)

#### Multi-line statements are always isolated by blank lines

A **multi-line statement** (one that spans more than one line) *always* gets a single blank line **before and after it** — even in the middle of a beat that would otherwise be packed. **This beats the "pack a beat together" rule.** The two you'll see most are a chained `expect(...).to.and.and…` and a `within(…) do … end` block, but the rule applies to **any** multi-line statement (a multi-line `stub_request(...).to_return(...)`, a multi-line `create(...)`, and so on).

- **In a run of several multi-line statements, each neighbour is also blank-separated** — consecutive `within … do … end` blocks each stand alone, with a blank line between them.
- **Never emit more than one consecutive blank line.** Where a blank-line boundary already exists (e.g. a multi-line statement that also happens to end a beat), don't add a second — one blank line *is* the boundary.
- **The body of a `do … end` block never begins or ends with a blank line** — no blank after the opening line, none before the closing `end` — *even when* its first or last statement is itself multi-line. **This exception beats every rule above.** (The same goes for `feature`/`scenario`/`context` bodies — see *Structural blank lines*.)

Canonical example — every rule above at work:

```ruby
scenario 'Release a held seat and free it for others', js: true, perform_jobs: true do
  sign_in_as(role: 'visitor')
  concert = create(:concert, name: 'Summer Gala')
  create(:seat_hold, concert: concert, user: User.last!, held_at: '2020-07-27 01:00')
  travel_to_time('2020-07-27 06:00')

  webhook = stub_request(:post, 'https://hooks.example.com/notify')
    .to_return(body: '{ "ok": true }', status: 200)

  visit concert_path(concert)

  within('.seat-row') do
    uncheck 'Hold'
  end

  expect(page)
    .to have_current_path(concert_path(concert), ignore_query: true)
    .and have_flash(:success, 'Seat released.')
    .and have_no_css('.seat-row.-active')
    .and have_no_link('Change seat')

  within('.seat-row') do
    expect(page).to have_unchecked_field('Hold')
  end

  expect(page).to have_css('.concert-summary', text: '1 seat free')

  # perform the enqueued jobs and assert releasing the hold triggers no notification
  perform_enqueued_jobs
  expect(webhook).not_to have_been_made
end
```

Read the whitespace: the single-line setup calls are packed into the opening beat; the multi-line `stub_request` is fenced by blanks on both sides; `visit` stands on its own line (the `within … do … end` after it is multi-line, so it can't pack onto `visit`); each `within … do … end` block and the `.and`-chain is multi-line and stands alone with blanks around it; the scoped **content** check is a flat `have_css(…, text: …)` (not a `within`), while the scoped **field** check keeps its `within` block; the final beat packs its comment, action and assertion together. No `do … end` body starts or ends with a blank line.

#### Chain related assertions with `.and` — always multi-line

Chain related assertions about the same page state with `.and` rather than stacking separate `expect(page)` lines. **Any `.and`-chain (two or more matchers) is *always* written multi-line** — never fold even a two-matcher chain onto one line. The layout is fixed: the subject (`expect(page)`) on its own line, then `.to <matcher>` on the next line, then one `.and <matcher>` per line, each `.to`/`.and` at a 2-space indent:

```ruby
expect(page)
  .to have_flash('Welcome')
  .and have_current_path(root_path)
  .and have_no_content('Error')
```

A **single** matcher — no `.and` — stays on one line (`expect(page).to have_content('Welcome')`); the multi-line form kicks in the moment you add a `.and`.

- BAD — a two-matcher chain folded onto one line:
  ```ruby
  expect(page).to have_content('Selected').and have_content('1')
  ```
- GOOD — subject / `.to` / `.and` each on their own line:
  ```ruby
  expect(page)
    .to have_content('Selected')
    .and have_content('1')
  ```

Because a chain is always multi-line, it is also a **multi-line statement** — so it takes a blank line before and after it (see *Multi-line statements are always isolated by blank lines*).

#### Block form: `within` uses `do … end`

Write every `within(...)` (and `accept_confirm(...)`) as a `do … end` block, **never** the one-line brace form `within(...) { … }` — even for a single statement. (This is the purely *syntactic* form rule; **whether** a scoped assertion should be a `within` at all vs. a `have_css(sel, text:)` is a house-style decision, under *Expectations*.)

#### Structural blank lines

One blank line after `feature '...' do`, one before the closing `end`, and one between consecutive `scenario` blocks; **no** blank line between adjacent `let`/`let!`/`before` declarations.

#### Variable naming

Local variable names are **snake_case, including numbers** (`user_1`, `order_2`, not `user1`/`order2`). RuboCop's `Naming/VariableNumber` flags these, but **`rubocop -A` will not auto-rename them** — so this one is on you.

#### You must enforce these yourself — linters won't

RuboCop (and every other linter) does **not** understand the blank-line rules or the variable-naming rule above; `rubocop-rspec`'s structural cops only cover `feature`/`scenario` boundaries, never the beats *inside* a scenario. **Even if RuboCop and all linters report full compliance, applying these rules is still your job.** Verify them by reading the spec, not by trusting a green lint.


### Scenario structure and narration

These shape *what* goes into a scenario, rather than how it's laid out:

- **Multiple act→assert cycles in one scenario are normal and expected.** A typical migrated scenario is 15–50 lines with several interact-then-assert cycles. Do **not** split one Cucumber scenario into many examples, and do **not** force a single expectation per example.
- **Keep each scenario self-contained; don't hoist shared setup.** Inline each scenario's own `create(...)` at its top. The **only** shared setup is a Cucumber `Background` → a `before` at the top of the feature (with `let!` for any records scenarios reference by name — see *`Background` becomes a `before(:each)`*). Do **not** extract setup that several scenarios merely happen to share into a common `let`/`before`/`context` — it couples them and blocks later scenarios that need different setup. This is a migration, not a refactor: mirror the Cucumber structure — flat `scenario`s plus a `before` only where there was a `Background`.
- **Exception — extract only *large* duplicated setup into a feature-local helper.** If many scenarios repeat a *big* setup block, `def` a helper **inside the `feature` block** (isolated to that feature — see [makandra card 13079](https://makandracards.com/makandra/13079-rspec-defining-helper-methods-example-group)) and **call it explicitly from each scenario** (e.g. `account = a_configured_account`). Each scenario still invokes it, so its setup stays visible and it remains self-contained — this is **not** a `before(:each)`, and you must not auto-run it in one. Reserve this for genuinely large chunks; don't do it for a few repeated lines.
- **Repeated non-trivial expression → a group-local `def`, never copy-paste.** If translating a scenario (or inlining a single-use step) makes you repeat a *non-trivial* expression several times — e.g. a compound locator like `find('.note-card', text: 'Draft announcement')` used four times — extract a small **`def` inside the `feature` block** (a group-local helper, [card 13079](https://makandracards.com/makandra/13079-rspec-defining-helper-methods-example-group)) and call it, rather than duplicating the expression. Prefer a `def` over a lambda. Keep it group-local while it's specific to one file; if the same helper turns out useful **across** files, it belongs in the shared support tree (Phase 3/4), not copy-pasted per file.

  ```ruby
  # ✗ the same compound locator duplicated at each use
  find('.note-card', text: 'Draft announcement').find('.note-card--pin').click
  expect(find('.note-card', text: 'Draft announcement')).to match_css('.-pinned')

  # ✓ a group-local def (defined in the feature block, alongside the scenarios) names it once
  def draft_note
    find('.note-card', text: 'Draft announcement')
  end

  def toggle_pin_for_draft
    draft_note.find('.note-card--pin').click
  end

  # …the scenario then reads:
  toggle_pin_for_draft
  expect(draft_note).to match_css('.-pinned')
  ```
- **Comments — carry the intent, in plain prose.** Add comments that convey **intent** ("why") or **narrate** ("what's happening now") wherever a run of Capybara calls doesn't tell the story on its own, so the intent the Cucumber prose used to carry survives. But every comment must *earn its place*: it must add something the code and the method name don't already say — otherwise omit it (don't comment `visit users_path`, and never restate a method name). Write **hand-written prose**: never a Gherkin step signature (`/^…$/`) and never a `…_steps.rb`/Spreewald/Cucumber provenance reference — those read as machine-migrated and are exactly what a strict reviewer flags.


### `.feature` files become feature specs

**Keep the same directory structure**, appending `_spec` to the filename:

```
features/users/list.feature   →   spec/features/users/list_spec.rb
```

A Cucumber `Feature:` becomes a **`feature '...' do ... end`** block. `feature` is the Capybara/RSpec alias for `describe '...', type: :feature` (provided by `require 'capybara/rspec'`); the reference apps use it for E2E specs. Don't use a bare `describe` — `feature` makes the file's purpose obvious and carries the `type: :feature` metadata our hooks and includes rely on.

The Cucumber feature narrative (`In order to … / As a … / I want …`) carries no assertions — drop it, or keep a one-line summary as a comment if it adds context.

A `@javascript` tag on the `Feature:` (all its scenarios are JS) becomes `js: true` on the `feature` block; a `@javascript` on a single `Scenario:` becomes `js: true` on that `scenario`. (Driver details — the *Understanding @javascript and js: true* section — are in `app-migration-guide.md`, Phase 3.)

Example INPUT `features/users/list.feature`:

```cucumber
Feature: Managing users

  Background:
    Given I am signed in as an admin

  Scenario: Listing users
    When I go to the list of users
    Then I should see "Alice"
```

Example OUTPUT `spec/features/users/list_spec.rb`:

```ruby
feature 'Managing users' do

  before do
    sign_in_as_admin
  end

  scenario 'Listing users' do
    visit users_path
    expect(page).to have_content('Alice')
  end

end
```


### Scenarios become examples in feature spec

A Cucumber `Scenario:` becomes a **`scenario '...' do ... end`** block (the Capybara/RSpec alias for `it`). Keep the scenario name as the example description.

Translate each step line **in order** into the Ruby it maps to:

- For an **app-specific step**, call the helper method you generated from its step definition (or inline its Capybara call if it was trivial — see above), passing each captured value as a keyword argument.
- For a **Spreewald step**, use the mapping from `./spreewald-guide.md`.
- For a **cucumber_factory step** (`Given there is …`), use the mapping from `./cucumber_factory-guide.md` (usually a `create(:model, …)` call assigned to a local variable).

`And` / `But` lines just continue with the next step's mapping — the leading keyword (`Given`/`When`/`Then`/`And`/`But`) has no effect on which method is called. A `@javascript` tag on the scenario becomes `js: true` on the `scenario` block.

**Carry the scenario's other tags across too — don't drop them.** Behavioral tags map per their own rules (`@allow-rescue` → `allow_rescue` metadata, etc.). **Purely organizational/topical tags** — `@smoke`, `@search`, `@billing`, and the like, which developers use to run subsets (`cucumber --tags @smoke`) — carry over as RSpec **metadata symbols** so `rspec --tag smoke` keeps working: `scenario 'Signing in', :smoke do`. Only the Spreewald debug tags (`@slow-motion`, `@single-step`) are dropped. See the tag rules in `spreewald-guide.md`.

Example INPUT:

```cucumber
@javascript
Scenario: Signing in
  Given there is a user with the email "joe@example.com"
  When I sign in as Joe
  Then I should see a flash message "Welcome"
```

Example OUTPUT:

```ruby
scenario 'Signing in', js: true do
  _user = create(:user, email: 'joe@example.com')
  sign_in_as_joe
  expect(page).to have_flash('Welcome')
end
```


### `Background` becomes a `before(:each)`

A Cucumber `Background:` runs before every scenario in the feature. How to map it depends on whether scenarios need its records **by name**:

- **Records not referenced by name (the common, simplest case)** → put everything the background does — record creation, navigation, sign-in — in a **single `before do … end`** at the top of the `feature` block (plain `before`, not the `background` alias; each step translates like a scenario step). No `let`s, so ordering never bites: do things in the order you need (e.g. time-travel *then* create).
- **Records the scenarios reference by name** (created via cucumber_factory) → promote those to a `let!` (eager — matches the background's "always created" semantics) or `let` (on-demand), so scenarios reach them by name. Now hook **ordering** matters — see below.

**When you use `let!`, order the setup `let!`s → `before`, not the reverse.** A `before { … }` placed immediately *above* a `let!` trips `RSpec/EmptyLineAfterHook` (makandra-rubocop) and reads backwards; keep the `let!`s first and the `before` last, with a blank line after it before the first scenario. Then pick the hook by *when* any time-travel must happen relative to record creation:

- **No time-travel** → `let!`s, then a plain `before` for navigation/sign-in (the example below).
- **Travel must precede record creation** → wrap the example in an `around { |example| travel_to_time(t) { example.run } }`. Group `around` hooks run *outside* the `let!`-generated `before` hooks, so records are created under the travelled clock; a `before` runs *after* the `let!`s and would be too late.
- **Travel after records exist** → do the travel in the `before`, after the `let!`s.

Example INPUT:

```cucumber
Background:
  Given there is a user with the email "admin@example.com"
  And I am signed in as that user
```

Example OUTPUT:

```ruby
feature 'Managing users' do

  let!(:admin) { create(:user, email: 'admin@example.com') }

  before do
    sign_in(admin)
  end

  scenario '...' do
    # ...
  end

end
```

The example above uses `let!` because the scenarios reference `admin` by name. If nothing in the background is referenced by name, collapse it to the single `before` described above — no `let`s needed.


### Scenario Outline becomes a shared example group, used once per row

A Cucumber `Scenario Outline` runs the same steps once per row of its `Examples:` table, substituting `<placeholders>`. Map it to a **`shared_examples` group** holding the steps (with the placeholders as keyword parameters), then **`it_behaves_like` once per row**, passing that row's values explicitly.

**Do not use a loop or any metaprogramming to generate the examples** (`Examples.each { … scenario … }`, `define_method`, etc.). Looping over data to emit examples is bad karma in tests: it hides the cases behind code, mangles failure output, and reads nothing like the reference apps. One explicit `it_behaves_like` line per row keeps every case visible and greppable — and matches the house style (`shared_examples_for 'name' do |keyword:, …|` + `it_behaves_like 'name', keyword: …`, as in the reference apps' `spec/features/shared_examples/`).

Example INPUT:

```cucumber
Scenario Outline: Sign-in validation
  When I sign in with email "<email>" and password "<password>"
  Then I should see a flash message "<message>"

  Examples:
    | email           | password | message              |
    | joe@example.com | secret   | Welcome              |
    | joe@example.com | wrong    | Invalid credentials  |
```

Example OUTPUT:

```ruby
feature 'Sign-in validation' do

  shared_examples 'sign-in validation' do |email:, password:, message:|
    scenario "signing in with #{email.inspect} / #{password.inspect}" do
      sign_in_with(email: email, password: password)
      expect(page).to have_flash(message)
    end
  end

  it_behaves_like 'sign-in validation', email: 'joe@example.com', password: 'secret', message: 'Welcome'
  it_behaves_like 'sign-in validation', email: 'joe@example.com', password: 'wrong',  message: 'Invalid credentials'

end
```

The shared group's keyword parameters mirror the outline's placeholders; each `it_behaves_like` line is one `Examples:` row. Interpolating a value into the `scenario` description keeps the rows distinguishable in output.

**Where to put the shared group:** define it inline (in the same feature file) when the outline is confined to one feature. When the **same** outline is exercised from more than one feature, move the `shared_examples` into `spec/features/shared_examples/` (loaded by the support glob) and `it_behaves_like` it from each feature.

**When a placeholder is a *model name*** it varies the factory, an attribute, *and* the route at once, so you can't inline one literal route. Pass the factory symbol and attribute as keywords, build the record with a dynamic hash key, and pass a **`path:` lambda per row** so each caller supplies its own route:

```ruby
shared_examples 'keyword links to its search page' do |model:, name_attribute:, path:|
  scenario "keywords on a #{model}'s show page link to its search page" do
    record = create(model, name_attribute => "#{model}_name")
    visit instance_exec(record, &path)   # NOT path.call(record) — see note
    # …assert the link…
  end
end

it_behaves_like 'keyword links to its search page', model: :post,  name_attribute: :title, path: ->(r) { post_path(r) }
it_behaves_like 'keyword links to its search page', model: :event, name_attribute: :name,  path: ->(r) { event_path(r) }
```

**Use `instance_exec(record, &path)`, not `path.call(record)`.** A `path:` lambda passed to `it_behaves_like` is defined in **example-group** scope, but Rails route helpers (`event_path`, …) are only mixed into the **example instance** — so `path.call(record)` raises *"event_path is not available on an example group. Use `let` or `subject`…"*. `instance_exec(record, &path)` runs the lambda against the example's own binding, where the route helpers exist.

Each row still inlines its own route via the lambda (no metaprogrammed `send("#{model}_path", …)`); `polymorphic_path(record)` is one option when the mapping is conventional. This is the one place the *inline the resolved route* rule bends — the route genuinely differs per row.


### Work scenario for scenario

**Migrate and verify one scenario at a time. Do not batch-convert a whole feature and run it only at the end** — a single early mistake (a wrong selector, a misremembered step mapping) cascades into many confusing failures, and on a big feature (some have 100+ scenarios) a whole-file run takes so long you can't iterate on your own mistakes.

For each scenario:

1. Translate the scenario into a `scenario` block.
2. Run just that example: `DISABLE_SPRING=1 bundle exec rspec spec/features/users/list_spec.rb:12 --format doc` — take the line from `grep -n '^  scenario' <spec>` (not a mental count), re-derive it after any edit that shifts lines, and read back the printed example name to confirm the scenario you meant actually ran (see the `:line` gotcha below). **Always prefix Rails-booting commands with `DISABLE_SPRING=1`** — otherwise Spring serves a cached process and you'll see stale behavior after edits (and misleading per-`TEST_ENV_NUMBER` DB readings).
3. Make it **green** before moving on. If it fails, fix the translation (or the helper/matcher it depends on), then re-run just that example.
4. **Review the migrated scenario** (see below).
5. Mark it done — orchestrator: in `progress.md`; fan-out worker: track it internally (see the worker note below) — then move to the next scenario.

**A scenario is done when it's verified green individually — do not re-run the whole feature or batch at the end.** Each per-scenario run already proved its scenario; a redundant full re-run only burns time (and on a 100+-scenario feature would hang). The **feature** is done only once *all* its scenarios are green **and** you've made the whole-file normalization pass (see *Finish a feature with a whole-file normalization pass*, below). The single verification run happens later, once, in Phase 6 (orchestrator).

**When a whole `.feature` file is migrated and green, annotate the original.** (When you later *report* how many features you marked, verify each marker is actually on disk — `head -1 <file>.feature` — rather than trusting a count from memory; a claimed-but-missing marker silently under-removes coverage at Cucumber-removal time.) Prepend one comment line to the top of the `.feature` file recording where it went and when — so that during a multi-day migration (Cucumber and RSpec running side by side) anyone can see at a glance which features are already done:

```cucumber
# Migrated to spec/features/users_crud_spec.rb (by mandoline on 2026-07-02 09:25)
Feature: Users CRUD
```

Get the timestamp with `date '+%Y-%m-%d %H:%M'`. This annotation is the **only** edit you may make under `features/`; leave everything else there untouched. If the marker already exists (a re-migrated feature), update it in place rather than adding a second.

Run everything through `bundle exec` so you use the app's pinned gem versions (see Phase 1). JavaScript (`js: true`) scenarios run in headless Chrome; if Chromedriver complains about a version mismatch, update it (see *Verifying the setup*).

**If you are a fan-out worker** (the orchestrator spawned you with a job and a `TEST_ENV_NUMBER`), three things differ from the above:
1. **Isolate your database.** Prefix *every* `rspec` command with your `TEST_ENV_NUMBER=<id>` (and `DISABLE_SPRING=1`) — e.g. `DISABLE_SPRING=1 TEST_ENV_NUMBER=2 bundle exec rspec spec/features/users/list_spec.rb:12`. Without `TEST_ENV_NUMBER` you'd hit a database another worker is using; without `DISABLE_SPRING=1` a cached Spring process may ignore it and connect every worker to the same DB.
2. **Don't write `progress.md`.** The orchestrator owns it. Track your scenarios internally and report the tally in your completion summary instead.
3. **You can't pause to ask the human.** Surface any blocker, ambiguity, or scenario you had to `skip` in your **completion summary** (the orchestrator batches questions), and append genuine guide problems to `guide-feedback.md`. **Put every skipped/unverified scenario and any feature you left without a migration marker in a loud, dedicated block at the *top* of your summary** (e.g. a `⚠️ NEEDS ATTENTION` heading) — the summary is long, and these must not get lost in it.
4. **Run every rspec command in the foreground and wait — never background it** (no `run_in_background`, no trailing `&`). You are a short-lived sub-agent: a backgrounded run **orphans the instant you return** — leaking a headless Chrome process and, because you share a `TEST_ENV_NUMBER` slot, risking corruption of a sibling worker's DB. Wait for each run to finish and read its result yourself. *(This is a **worker** rule, born of your ephemerality. The **orchestrator** persists across the whole run, so it is free to run rspec however it likes — including its Phase-6 verification as a tracked background task it awaits; see *Now — and only now — run the specs*.)*
5. **Never boot or install a service.** A connection error to a known service host (Postgres, OpenSearch, Redis, …) is an **environment fault** — put it in your completion summary and stop; do **not** work around it by starting your own copy (you'd orphan a stray process and produce non-reproducible state). Booting a *documented, not-yet-running* service is the orchestrator's job, never yours.

> **Never re-run the whole E2E suite mid-migration.** Running it as a "safe checkpoint" after each change is prohibitively expensive. Only ever run a **targeted selection**: the single scenario you just migrated, or — when a change to a shared helper/matcher could affect others — the **specific** features you believe are affected (e.g. `bundle exec rspec spec/features/a_spec.rb spec/features/b_spec.rb`). The **single verification run** happens at the very end, in Phase 6 (over this session's migrated specs; CI runs the full suite after the push).

If you hit something the guides don't cover or you're unsure how a step should map, **flag it** rather than guessing — a worker surfaces it in its completion summary; the orchestrator batches questions for the human.

**If a scenario can't be verified green because of a *system-environment* fault (not a migration bug)**, the last-resort branch applies — but two things gate it. **First, the fault's *shape*** — either a **genuinely-absent** system dependency (a binary the app shells out to — `zbarimg`, `wkhtmltopdf`, … — or an unprovisioned service/DB the box can't provide), **or one that's *installed but sandboxed away from the workspace*** (an AppArmor/SELinux-confined daemon, or a service running as another user that can't read the project's files — e.g. `clamd` rejecting a file under `/home` with "Permission denied"). In both cases **do not install, reconfigure, or `sudo`** — that's the human's project setup, out of mandoline's scope (see *Phase 1 → scope*). Migrate the spec faithfully, **leave the `.feature` file without its migration marker**, and surface it in the loud block above. It will pass in CI where the dependency exists. **Second, the *scale*** — deferring to CI is fine when the fault blocks only a **handful** of scenarios; but when a bad environment would leave a **large fraction** of the suite unverifiable (a Postgres version mismatch, no Node, a broken shared service), **stop and escalate to the human to fix the environment** — deferring "almost all tests" to CI defeats local verification, so it's not an acceptable hand-off.

> **This is a last resort, not a routine branch** (see *The contract: parity, not improvement* in `app-migration-guide.md`). It does **not** cover a scenario that fails because the **RSpec suite is configured more strictly than Cucumber was** — a globally-mocked network (`WebMock.disable_net_connect!` / VCR, which the Cucumber suite never loaded — see *Global mocks* in `app-migration-guide.md`), a stricter global config, or a CI-exclusion tag. Those are reproducible, not missing dependencies: opt out of the global mock per-scenario, wait out the race, or read the origin to see how it worked. If the Cucumber suite ran it, it is verifiable here — don't downgrade it to "unverified".

#### Review each scenario (a green spec is not enough)

A passing spec is necessary but not sufficient — a spec that quietly dropped a `Then` still passes. After a scenario is green, review it against these three checks before marking it done:

1. **Completeness of the migration.** Every original step is represented in the spec, in order — especially every `Then`/assertion. Nothing was silently dropped, and no step was reduced to a no-op. Cross-check against the original `.feature` and `step-mapping.md`. **Do this by *reading* the `.feature` against the spec — not with a regex/grep/Python auditor**, which silently under-counts (a line-continued `js: true`, a renamed-but-equivalent step, a table nuance) and manufactures false confidence for exactly the drop that otherwise passes green. (A mechanical *tag-count* audit is fine as a coarse backstop — see the Phase-6 *Tag-parity audit* — but completeness is a reading task.)
2. **Intent is preserved.** The chief advantage of Cucumber was that its English prose documented *what* and *why*. Make sure that intent survives the translation to Ruby. Where a Capybara call is less self-explanatory than the original prose, **add a short comment** carrying the lost intent. For example:

   ```ruby
   # "When I confirm the deletion" — the click triggers a JS confirm() we must accept
   accept_confirm { click_on 'Delete' }
   ```

   Don't over-comment the obvious (`visit users_path` needs no comment); add comments only where prose meaning would otherwise be lost.
3. **The code reads well (house style).** It matches the **house style** above and the **[*Mechanical formatting rules*](#mechanical-formatting-rules)** — the blank-line beats (including a blank line *before and after* every multi-line statement, which `rubocop -A` won't add, so verify them *here*) and snake_case-with-numbers variable names (`user_1`, not `user1`/`order2`), which RuboCop flags but won't auto-fix. Plus: `expect`-syntax assertions, `have_no_*` for negatives, sensible use of `let`/`before`, no leftover `patiently`/`should`/Cucumber-isms, no dead variables (prefix deliberately-unused records with `_`). **A blank line follows every `visit`** unless the very next line is its arrival assertion (which packs onto it); a `visit` before an *interaction* gets the blank line — *grep:* `grep -nA1 'visit ' <file>`.

If a review turns up a problem you can't cleanly resolve, note it in `progress.md` and flag it for the human.

#### Finish a feature with a whole-file normalization pass

The per-scenario review above gets each scenario *individually* right. It does **not** catch the most common defect: the grouping rules applied **unevenly across the file** — the same situation folded one way in scenario 1 and left flat in scenario 3. Each scenario looks fine alone, so a per-scenario glance misses it. (Asking workers to "check your own work" as they went is exactly what produced this inconsistency before.)

So once **every** scenario in a feature is green, make **one deliberate pass over the whole file** — a distinct step, top to bottom, **not** the as-you-go review. **A feature is not done until this pass is complete.** The checklist is *what to verify across the whole file* — each item points to the rule it enforces (defined once, with rationale, exceptions and full examples, in *Expectations* and *Mechanical formatting rules*); several are *greppable*, so run the grep rather than eyeballing:

1. **Consistency is the goal.** For every selector / shape that recurs across scenarios, pick the one correct grouping and make it **identical everywhere** in the file. Most fixes below are really "make scenario 3 match scenario 1."
2. **Merge consecutive same-selector `within` blocks *that aren't separated by an interaction*** into one (*Expectations* step 4) — e.g. two *assertion-only* `within('.card') do … end` with nothing (or only a comment) between. Two same-selector blocks that **each end in an interaction** stay separate — that's the one-interaction-per-`within` rule (item 3), not a merge candidate (`check "A"` then `check "B"` in the same scope = two blocks). *Grep:* `grep -n 'within(' <file>`, then scan for the same selector on adjacent blocks.
3. **One interaction per `within`, as its last statement** (*Expectations* step 4).
4. **Lone scoped content check → page-level `have_css`** (*Expectations* step 2) — `within('sel') { … have_css('child', text:) }` → `have_css('sel child', text:)`; field matchers and negations may stay scoped.
5. **Cluster consecutive page-level assertions** into one `.and` chain (*Expectations* step 2) — a single big matcher may join, don't stack two. (Exceptions: a positive sync point placed before a post-`visit` negation stays its **own** statement — see the *NegationMatcherAfterVisit* gotcha; and any assertion carrying a non-default `:wait` stays standalone — see *Expectations*.)
6. **`.and` chains are multi-line** (*Mechanical formatting rules*). *Grep:* `grep -nE '\.to .*\.and ' <file>` finds folded one-liners.
7. **Blank-line isolation** (*Mechanical formatting rules*) — a blank line before *and* after every multi-line statement. RuboCop can't check this, so it's the easiest to miss — verify every multi-line statement.
8. **No Cucumber leftovers in comments** — every comment reads hand-written, not machine-migrated: no Gherkin step signatures, and no `…_steps.rb`/Spreewald/Cucumber provenance. *Grep:* `grep -nE '#.*/\^.*\$/' <file>` must return nothing; also scan for `mirrors …_steps.rb` / `Migrated from` / `(spreewald)` / **`origin`** (workers write "faithful to the origin" / "the origin spelled…" constantly, and it reads as migration provenance too). Rewrite each hit as plain prose that adds real information, or delete it if the method name already says it. (Nothing here is load-bearing — the step→method mapping lives in `step-mapping.md`.)
9. **Whole-file fidelity** — no assertion dropped or weakened vs the `.feature`, no over-globbed matcher. **Regroup and reformat only — never rewrite an assertion** into a different matcher/helper (*Regrouping changes layout, never assertions*).

Then **re-run the scenarios you changed** (`DISABLE_SPRING=1 … rspec …:line --format doc` — re-derive the line after your edits and confirm the printed example name, per the `:line` gotcha below) to confirm the edits didn't change behavior. Only now mark the feature done. This pass is why no separate normalization stage is needed — but it earns that only if you treat it as a real, distinct pass, not a quick glance.


### Migration gotchas (learned the hard way)

These recur across apps. Watch for them while translating and reviewing:

- **A Ruby-level read after a browser interaction does *not* wait for the browser — put a page-level sync point before it.** `expect(ActionMailer::Base.deliveries).to have_mail(...)` (and any `deliveries.find`/`deliveries.last` read) read `ActionMailer::Base.deliveries` **once**, and a matcher **argument** like `Thing.last!` in `expect(page).to have_content('Saved').and have_current_path(thing_path(Thing.last!))` is evaluated when the chain is **built** — both run before the browser's request has landed (even with a synchronous `after_commit` + `deliver_now`), so they see the *previous* state and fail (or raise `RecordNotFound`). Fix by asserting a **waiting page-level read first**: reorder an existing one (a `have_flash`, `have_table_with_rows`, `have_current_path`) ahead of the Ruby read — free, keeps parity — or, if the observation had none, add a single `expect(page).to have_flash(:success)` sync point (an *added* assertion — flag it). Hit independently across apps and workers.
- **`text-transform: uppercase` breaks `have_link('X')` but not `have_link(text: 'X')`.** `have_link('X')` matches the **locator** (the untransformed DOM text node); `have_link(text: 'X')` / `have_css('a', text:)` filter on the **rendered** text (CSS transform applied). So an ALL-CAPS `.feature` literal (`"READ MORE"`) over an uppercased `.btn` fails `have_link('READ MORE')` and passes `have_link(text: 'READ MORE')` (which also keeps `Capybara/SpecificMatcher` happy, unlike `have_css('a', …)`). Rule of thumb: if the literal is ALL CAPS but the markup isn't, use the `text:` form. (Some suites sidestep the whole class by adding `* { text-transform: none !important }` in the test environment so tests match the markup text — worth suggesting if the app leans on transforms.)
- **A negation against CSS-transformed or unscoped text is *vacuous* under Selenium — use a locator-based matcher and probe it.** `have_no_content('Assign to me')` / `have_no_css('a', text: 'Assign to me')` compare the **rendered** text, so a `text-transform: uppercase` button (renders `ASSIGN TO ME`) passes the negation **while the element is right there**; and `have_no_css('.scope', text: 'X')` also passes when `.scope` is simply **missing**. Being *faithful to the origin* is no defence — the origin was vacuous the same way. For a negation in a JS spec, prefer a **locator-based** matcher (`have_no_link('L')`, `have_no_button`, `have_no_field`), or **scope it** (`within('.scope') { expect(page).to have_no_content('X') }`), and **probe it once**: run with the element present (drop the action, or flip the role) and confirm the check *fails* — a throwaway `page.has_no_content?('…', wait: 0)` with the element on screen settles it in seconds. When a fixed negation then fails on CI, **investigate before reverting** (`git log -S`): it usually exposes a genuinely outdated expectation — a link now shown, or present-but-**disabled** (the right check is `disabled`, not `absent`) — which you fix to the app's intended behaviour, not by restoring the vacuous form.
- **`.feature` literals can hide non-breaking spaces (U+00A0)** that match the app's rendered text but are invisible in your editor — retyping the label with a normal space then fails the lookup. Before migrating a feature, `grep -nP '\xA0' <feature>`; carry any hit across as a ` ` escape in the string (e.g. `check "Special use"`).
- **A `have_no_*` right after `visit` needs a positive anchor — whether or not `Capybara/NegationMatcherAfterVisit` is enabled.** Many Cucumber beats end `When I go to … / Then I should not see "X"`. The cop (opt-in; some repos fail the build on it) objects for a *timing* reason that is mostly a false positive on a server-rendered app — `visit` completes a full page load, so the content is already there. **The real reason to anchor is the wrong-page case:** a page that 404s, raises, or renders a different screen satisfies *every* `have_no_*` in the example, so an unanchored `visit` → `have_no_css('aside.ad')` proves only that the response didn't contain that selector — which an error page also doesn't. This was the single largest post-migration cleanup seen in the field: unanchored negations had to be fixed by hand after merging, adding `have_content(record.title)` (or `have_content('Access denied')` where denial was the point) before each. The Cucumber originals were equally unanchored, so faithful porting is what carried it over — the port is the moment to fix it. So: **reorder a positive assertion of the same observation ahead of the negation**, or if there's no natural positive, **add one that proves the intended page rendered** — its heading or the record's title, *not* `current_path` alone, which a 404 or a denied request keeps. Never "fix" it by dropping the negation, and **don't `rubocop:disable` a cop the project chose to enable.** **Keep the positive and the negation as two separate `expect(page)` statements** — the positive is a sync point that must settle *before* the negation is meaningful, so it's exempt from the "cluster consecutive page-level assertions into one `.and` chain" rule.
- **A waiting `have_no_*` is vacuous whenever the element's presence is *asynchronous* — treat it as its own review category.** A waiting negation can pass for the wrong reason in **both** directions. For a **self-removing** element (a loading indicator, a toast, an auto-dismissing flash) it waits out the disappearance and passes **even though the element did appear**. For an element that **appears late** (a JS-compiled widget, an overlay positioned after render) it passes simply by **running before the element shows up** — and the tell is a failure *later and elsewhere*: the negation passes, then the spec dies a few lines down (e.g. `ElementClickInterceptedError` on the very overlay the negation "proved" absent). Reproduce the origin's approach either way: a short fixed `sleep` (≈ 0.5 s, long enough for the element to appear if it would) **then a non-waiting read** — `have_no_css('.spinner', wait: 0)`. One of the few sanctioned bare-`sleep` uses. When auditing a converted suite, treat every **`have_no_*` on a JS-rendered element** as a review category of its own — sanity-check each by making the condition true once.
- **Two vacuity patterns that *look* correct and can never fail.** (1) **An attribute read comes back as a *string*:** under Selenium `node['disabled']` is the string `"false"` for an enabled element, which is *truthy*, so `node['disabled'] || …` always passes. (2) **A wrong array index in a filter:** filtering tracked events on `a[1] == 'trackEvent'` instead of `a[0]` compares `[] == []` and can never fail. When a faithful port goes **red where the origin was green**, don't assume the port is wrong — **instrument the origin**: run the Cucumber scenario with a throwaway `AfterStep` probe that prints the step's own inputs (`cucumber … -r features -r tmp/probe/x.rb`) and confirm whether the origin was actually asserting anything. A red port often just means the origin's check was vacuous.
- **A step regexp with a captured *leading space* silently never matched — so the step always ran its fallback branch.** A pattern like `/^the screening( in the morning| in the evening)? on …/` (the capture includes the leading space) compared against the text `in the evening` never hits the intended branch, so the step quietly fell through to its default. When a faithful port of the *intended* branch goes red where the origin was green, inspect the step's capture groups for stray whitespace before concluding the port is wrong — the origin may never have taken that branch at all.
- **A factory association that mints a *fresh parent per record* can make an "other user's X" scenario vacuous.** If each created child builds its own parent (a new team per project, say), then a screen scoped to one parent shows **none** of the others' records — so an assertion about "user A's view of user B's drafts" holds trivially, because B's record lives under a different parent entirely and was never on the page. When porting such a scenario, check the factory wiring: put the records under a **shared** parent where the scenario means them to meet, and anchor the check with a **positive** assertion (`have_css('.draft', visible: true)`) so an empty page can't pass it.
- **A ported negation whose literal can never appear asserts nothing — prove each one is *falsifiable*.** The previous bullet is about negations that pass for a *timing* reason; this one is about negations that could never fail at all, and it recurred in every migration reviewed so far. The shapes, all faithfully carried over from `.feature` files: a **regex written as a string** — `have_no_content('Budget .* exceeded')` matches literally, so the `.*` guarantees a pass; **text the app never renders** — an English cookie-banner string in an app that only ships German, or a label the view spells differently (`have_no_content('Orders')` where the nav says "Purchases"); and **a scenario that only ever exercised the negative branch**, so the element was never present in any state. The check is mechanical: for every `have_no_*`, **grep the views and locale files for the literal** and confirm the positive form can match *somewhere*; flag any argument containing regex metacharacters (`.*`, `\d`, `|`, `^`, `$`) or a language the app doesn't render. If you can't show it could fail, say so in `needs-attention.md` rather than porting it green.
- **`have_content` cannot see a value that lives in a form control — port those to `have_field(..., with:)`.** When the Cucumber step asserts a value that the app renders into `<input value="…">` or a `<select>`, `have_content` is the wrong matcher: an `<input>`'s value is **not** part of `page.text`, so the assertion silently passes (as a negation) or fails for the wrong reason (as a positive). Confusingly, a **`<textarea>`'s** content *is* text under rack-test, so `have_content` "works" there and then breaks the moment the spec runs under Selenium — equally wrong. Check the view for which element renders the value, and emit `have_field('Name', with: …)` / `have_no_field('Name', with: …)` accordingly.
- **A `:line` filter can silently run the *wrong* example and report green.** `rspec file:N` runs the example block *starting at or before* N — so a line landing on the blank gap between two `scenario`s, or a line gone stale after an edit shifted the file, runs a **neighbouring** scenario and passes. (Prefer `:line` over `-e '<name>'`, whose substring matching brings its own wrong-example failures.) The defence isn't the filter syntax, it's **confirming which example ran**: take the line from `grep -n '^  scenario' <spec>`, re-derive it after every edit, and run with `--format doc` so the printed example name proves the intended scenario executed. This matters most when **mutation-probing** an assertion — a mis-targeted filter "proves" a live assertion is dead when it never ran at all.
- **Unpoly hydrates a fragment *before* it enters the DOM**, so a found element is already interactable — don't wrap clicks in `patiently` "just in case." The rare exception is a custom compiler or 3rd-party library that defers its *own* hydration via `setTimeout()` after insertion (element present, not yet wired up). Fix it by making the element **signal readiness** and waiting on that — a `loaded`/ready class you can assert, or (if you control the client) bracketing the work with `CapybaraLockstep.startWork()/stopWork()` — not by blanket-retrying the interaction.
- **A scenario that tests Unpoly *revalidation* has two preconditions a naive port drops.** Unpoly does cache-then-revalidate: a return visit shows the cached copy, then re-fetches and swaps in fresh content *if it changed*. So the revalidation only actually runs if (1) the page was first loaded **through Unpoly** (an `up-`navigation) — a full `visit` never enters Unpoly's cache, so there's nothing to revalidate — and (2) the content **changed** before the return visit — Unpoly skips rendering an unchanged revalidated response. Miss either and the "it updated" assertion is a silent no-op. Confirm revalidation fired with a counter on `up:fragment:loaded` where `e.revalidating` is true.
- **Capybara's field finders exclude *disabled* fields by default.** `find_field`/`fill_in`/`have_field` skip a disabled input (the error even says *"…that is not disabled"*), so a plain `find_field('X')` on a legitimately-disabled field **raises `ElementNotFound`**. Pass `disabled: :all` (or `disabled: true`) **only** when you actually need the disabled field — e.g. a matcher locating one to inspect it — never as a blanket habit.

- **HTML5 date/time inputs — always *assert* with ISO `yyyy-mm-dd`, but *fill* in a driver-dependent format.** For `<input type="date">` (and `time`/`datetime-local`/`month`/`week`), the element's **value** is always ISO 8601 regardless of display locale, so `have_field('Date', with: '2022-11-28')` is locale-independent — **assert ISO, always.** **Filling is the tricky half, and it depends on the driver:**
  - **rack-test / any driver that sets the value directly** → `fill_in 'Date', with: '2022-11-28'` (ISO). This is the case the guide long assumed, and the one **exception to "carry quoted strings verbatim"**: normalize the localized date from the step (`"28.11.2022"`) to ISO.
  - **Selenium/Chrome (`js: true`)** → `fill_in` sends **keystrokes segment-by-segment in the browser's *display* locale**, so an ISO string garbles (on an en-US browser, `with: '2020-07-31'` types as `0731-02-02` and an autosubmit form never fires). Here you must fill with the **localized string the Cucumber step already used** (`'07/31/2020'`, `'28.11.2022'`) — i.e. carry it verbatim, *don't* normalize. The field still reads back as ISO, so the assertion stays ISO.

  So: **assertions are always ISO; the fill format follows the driver** — ISO for rack-test, the browser-locale literal for Selenium. If a `js: true` date fill mysteriously garbles or the form won't submit, this is why. (Rendered localized dates depend on `I18n.locale`, not the OS, so asserting on rendered *text* like `28.11.2022` is fine either way.)

- **A step-def helper that shadows an included test-helper module (Warden/Devise) — rename the app's version.** An app can define its own helper (e.g. `login_as(user, on:)`) in `features/step_definitions/` while the suite *also* pulls in a module that defines the same name — commonly `World(Warden::Test::Helpers)`, whose `login_as` signs a user in without the UI. Cucumber's `World` merged both harmlessly; in RSpec **both get `config.include`d into feature specs and include-order silently decides which wins** — fragile and confusing. When you spot this clash while migrating support code, **rename the app's version to something unambiguous** (e.g. `enqueue_login`) and update its call sites, rather than relying on include order. Watch for it with any Warden/Devise helper name (`login_as`, `sign_in`, `logout`). **And if the app's mechanism is a *global* Rack/Warden hook** (e.g. `Warden::Manager.on_request` reading a queue of users-to-sign-in-on-a-path), remember it fires on **every** request — request/controller specs, and any pre-feature request in a random-order / sharded run — not just feature specs. So initialize any state it reads **at load** (not only in a `before(:each, type: :feature)` reset) **and nil-guard the read** (`state&.[](…)`); otherwise it raises `NoMethodError` the moment a non-feature spec hits the hook — a failure your feature-spec verification never sees.

- **A migrated feature sign-in helper often collides with a pre-existing request/controller one.** Apps being migrated usually already have request/controller specs carrying a Devise/Warden sign-in helper — very often named `sign_in` or `sign_in_as`. Your converted feature step (e.g. `sign_in_as`, the UI sign-in flow) then shares that name, and if the app's version is a **bare top-level `def` in `spec/support/**`** it's global (defined on `Object`), so it silently shadows/clashes everywhere with no error. **Before naming a converted auth step, grep `spec/support/**` for the name.** When both must coexist — the feature UI flow and the request/controller Devise flow are genuinely different mechanisms — co-locate them as **two scoped modules in one file** and `config.include` each by spec type; give them **distinct names** if signatures/semantics differ, so a reader is never unsure which one a call hits:

  ```ruby
  # spec/support/authentication.rb  — modules AND their RSpec wiring in one file
  module Authentication
    module Feature          # UI sign-in (drives the browser)
      def sign_in_as(role_or_factory) … end
    end
    module Direct           # Devise/Warden, no UI
      def sign_in_directly_as(user_account_type) … end
    end
  end

  RSpec.configure do |config|
    config.include Authentication::Feature, type: :feature
    config.include Authentication::Direct,  type: :request
    config.include Authentication::Direct,  type: :controller
  end
  ```

  And treat **any** bare top-level `def` in `spec/support` as a smell — wrap helpers in modules and `config.include` them by type; never rely on a global method on `Object`.

- **A sign-in helper must *end by asserting the sign-in took* — don't assume the session stuck.** Two mechanisms make this fail intermittently, and both produce failures that look like anything but an auth problem. (a) **Warden's `login_as`** installs a **one-shot `on_next_request`** callback: a stray in-flight request left over from the *previous* example can consume it, so the example's own `visit` arrives unauthenticated. (b) **Cookie-rewriting auth** (Clearance and friends re-issue `remember_token` on *every* response): a late response from the screen you just left restores the **previous** session after your test sign-in. Either way the spec proceeds as the wrong user — or as nobody — and dies later on a missing element, a redirect to an external identity provider, or a bare `$ is not defined`, several lines from the cause. So: after signing in, **synchronize (`Capybara::Lockstep.synchronize` if the app bundles it) and assert the session belongs to the intended user** (a nav element bearing their name, or the session cookie) before returning; retry the sign-in a bounded number of times if it didn't take. Also prefer a **UI sign-in** flow over `login_as` in feature specs for exactly this reason.

- **Don't add navigations the original didn't have.** Many Cucumber assertions check the *already-rendered* page with no new request (e.g. `Then I should be signed in as "X"` after a time-travel step). Inserting a `visit`/`page.refresh` triggers a fresh request that can re-evaluate state (e.g. the session under time-travel) and fail a test that should pass. Translate step-for-step; add a `visit` only where the original navigated.

- **Hardcoded record IDs in expected output.** Cucumber reset auto-increment sequences per scenario, so scenarios sometimes hardcode `id 1` (`/acme/1/attachments/1`). RSpec + DatabaseCleaner `:deletion` does **not** reset sequences, so ids keep climbing and `…/1/…` no longer matches. Fix: pass the id explicitly in the factory — `create(:note, id: 1)`.

- **A local variable goes stale after the UI changes its record — `reload` before you update it.** Cucumber steps like `Given the note above has X` re-fetch the record (`Note.last.update!`). The literal `record.update!(attr: value)` on an earlier local var acts on a **stale** object if the UI mutated that record meanwhile; if `value` equals the stale attribute, ActiveRecord sees nothing dirty and issues **no `UPDATE`** — a silent no-op that fails the later assertion with nothing to trace. Fix: `record.reload.update!(...)` (or re-fetch via `Model.last`) whenever the UI changed the record between creating the var and updating it. **`reload` isn't always enough:** it refreshes columns and associations but **not plain instance variables** a setter or factory stashed (which a `before_save` may write back) — e.g. a `tags=` setter that stores `@pending_tags`. When a callback reads such ivar-stashed state, a later `update!` silently reverts it and `reload` doesn't help; load a **fresh object** instead (`Model.find(record.id)`).

- **Real-browser relative / auto-ticking time — absorb the timing, don't skip.** Assertions like "1 minute ago" depend on the browser's wall clock, which Capybara can't freeze (Timecop freezes *Ruby* time, not the browser's JS `Date`). This is a race to **wait out**, not a reason to drop coverage: the scenario passed in Cucumber, so it must pass here (see *The contract: parity, not improvement* in `app-migration-guide.md`). Absorb it — (a) lean on Capybara's **waiting matchers**: `have_content('1 minute ago', wait: 3)` retries until the browser clock crosses the boundary (the test page typically seeds a time a second or two before the tick, so it flips inside the wait window); (b) **loosen tolerance** — accept a small set of acceptable strings, or ±1s; (c) bump `default_max_wait_time` / use `:patiently`. Do **not** freeze the clock for a scenario that tests *ticking* — a frozen clock never advances (freezing is for exact-countdown *reads*; see the next bullet). **Never `skip`/`pending` a relative-time scenario the origin ran** — that is silent coverage loss.
  - **Pick a generous-but-bounded wait — E2E timing is chronically unreliable.** A sub-second wait/`sleep` will flake some of the time; ~**2–3 s** is generous enough to observe the effect reliably. Don't over-inflate it (the old `wait: 15` was excessive): a bloated window is wrong in the other direction — when the effect is genuinely *missing*, the waiting matcher burns the whole window before failing, so a too-long wait just makes a legitimate failure slow. This applies wherever you wait out real time (a waiting matcher, a poll, or the deliberate-`sleep` case in the next bullet).
- **Exact relative-date assertions need a *frozen* clock, not a *travelling* one.** Even with no browser (rack-test), a countdown like "Auto-destruct in 60 days" is nondeterministic if the clock keeps running: `Timecop.travel` / a travelling `travel_to_time` lets real time elapse, so the sub-day gap between `create` and the `visit`/render floors "60 days" to "59" — green when authored at one time of day, red in the full run at another. **Freeze** the clock (`Timecop.freeze`) for any assertion on an exact relative date or countdown, so zero time elapses. (Travelling is fine when you only assert *state*, not an exact elapsed figure.) **Exception — don't freeze when the scenario intentionally waits out real time** (a `sleep`, a poll it lets fire, a debounce) and then asserts that time *has* elapsed: a frozen clock reports zero elapsed no matter how long you wait, so the assertion never comes true. Let the real clock run there (as with the auto-ticking case above).

- **Interleave actions and observations — required around debounced/autosubmitting controls, a flakiness remedy everywhere else.** Flaky E2E specs have three complementary defences: Capybara's internal retry, capybara-lockstep, and **interleaving** — after an action, observe that it took effect before the next action (act → observe → act → observe). Leaning on any one overloads it; all three together drive the flake rate to near zero. You don't need to interleave everywhere — filling several fields, submitting, and only *then* asserting success is perfectly fine. **For one shape, though, it is a precondition and not a remedy: any control that is *debounced* or *autosubmits*** — a live filter, a submit-on-change `select`, a search box that replaces a table. Don't wait for those to flake. This is by far the most common residual defect class in migrated suites — it has shown up in most apps migrated so far, and it is the defect that has turned default branches red *after* a migration landed. So: **(a) between an interaction with such a control and the *next* interaction, assert something that is false on the pre-action DOM.** The subtlety that makes naive fixes fail: asserting the action itself (`have_field('Search', with: 'N')`) is still worth doing for *attribution* — it turns an unattributable failure into a specific one — but it is **not a gate**: it's satisfied the instant the keystroke lands, *before* the debounce timer fires; likewise an assertion on a row that was already visible. Gate on the **consequence**: a row that must *disappear*, a result counter that must change (`'Showing 1 – 1 of 2'`), a field that only exists after the fragment swap. And note that **capybara-lockstep does not cover this** — it tracks in-flight requests, not a pending `setTimeout`, so during the debounce window nothing is waiting at all. **(b)** firing several JS interactions in a row on an app **without** capybara-lockstep (consecutive `select`s on a submit-on-change form, click-then-click), where Capybara acts on a torn/previous DOM. Because adding observations deviates from the faithful origin, it's an *improvement* bounded by the *Repairing a bad test* rule in `app-migration-guide.md` (welcome, not required, kept proportional). For a submit-on-change **GET** form, rack-test + clicking the (hidden) submit after each field is an even simpler route. **Don't add capybara-lockstep during the migration** to fix this — it has side effects; leave that as a separate follow-up. ([makandra card 47336](https://makandracards.com/makandra/47336-fixing-flaky-e2e-tests#section-interleave-actions-expectations))

- **Capybara auto-retries a single *expression*, not an interdependent *sequence* — wrap the sequence in `patiently do … end`.** Capybara's waiting is powerful and treats a whole chained expression as one retry unit — e.g. `expect(find('#sidebar').find('h1')).to have_content('Something')` re-runs the *entire* chain until it passes, so a re-render mid-flight is fine. What it **cannot** do is coordinate **separate statements that depend on each other**: it retries each in isolation and has no idea they form a unit. Two shapes hit this, especially when a fragment re-renders *on its own* (Unpoly `up-validate`/`up-poll`, a polling widget, a debounced auto-submit):
  - a **`within('sel') do … end`** — `sel` is resolved **once**, then the block's later commands run against a now-stale node → `StaleElementReferenceError`. (Distinct from the post-*interaction* staleness in the *Expectations* `within` rule: there *you* triggered the re-render; here it's autonomous.)
  - a **sequence that threads state between finds**, where a later lookup uses data read from an earlier element — Capybara can't know `el2` depends on `el1` still being valid:
    ```ruby
    el1 = page.find('#el1')
    ref = el1['data-reference']     # el1 may go stale, or ref be read, mid-swap
    el2 = page.find("##{ref}")
    ```
  Fix: wrap the whole interdependent unit in **`patiently do … end`** — that is exactly what it's for; it re-runs the entire block until it stops raising (the `patiently` gem — see `spreewald-guide.md`):
    ```ruby
    patiently do
      el1 = page.find('#el1')
      ref = el1['data-reference']
      el2 = page.find("##{ref}")
    end
    ```
  (Where a fragment isn't needed as a *scope* and one expression suffices, a page-level waiting matcher sidesteps it — but `patiently` is the general tool whenever a *block/sequence*, not a single expression, must retry as a whole.)
- **A background poller trips a strict per-scenario JS-error check during teardown — disable the poller in the test env.** If the app has an auto-refresh widget (Unpoly `up-poll`, a `setInterval`, any polling component) **and** you ported a strict per-scenario "no JS errors" check (an `assert_no_errors!`-style `after` hook), the two collide: a poll tick eventually fires during teardown (racing the server shutdown) or on a page that no longer holds the poll's target fragment, throws (e.g. Unpoly's `up.CannotMatch`), and the JS-error check reports it — **failing an unrelated scenario, and only on CI** (fast local runs finish before the timer, often 10–20 s, ever fires). The clean fix is a **feature flag that disables the poller in the test environment** — no scenario should be asserting on a background auto-refresh anyway. Do **not** instead (a) add the error to the JS-check's ignore-list — that masks real target-mismatch bugs — or (b) fight `after`-hook ordering to drain the timer. Note the standard `conclude_browser_requests` teardown does **not** save you: it runs *after* the JS-error check (reverse `after`-hook order) and doesn't clear JS timers, so it can't stop a poll that already logged.
- **Selenium returns HTML attributes as strings.** `element[:checked]` / `element[:disabled]` come back as strings (`"true"`, `"disabled"`) under Selenium, so a truthiness test is always-true and silently wrong. Use Capybara's boolean predicates (`element.checked?`, `element.disabled?`) or matchers (`have_checked_field`, `have_field(disabled: true)`), never the raw attribute.

- **Explicit fixture ids are a red flag that the origin reset pk-sequences — preserve that invariant.** When migrated fixtures carry hardcoded ids (`create(:post, id: 10)`, a helper that pins a record's id, ids asserted verbatim in the UI like "ID 10012"), the Cucumber suite very likely reset every table's primary-key sequence per scenario (a `Before` hook in `features/support/env.rb`). RSpec's `:transaction`/`:deletion` cleaning does **not** reset sequences and `nextval` is non-transactional, so the sequence climbs across a run until it collides with a fixture id → intermittent, order-/shard-dependent `PG::UniqueViolation` on a `*_pkey`. Don't assume DatabaseCleaner covers it — **port the reset** (see *Port any per-scenario primary-key-sequence reset* in `app-migration-guide.md`).
- **Reset global/thread-local state a step sets — random order exposes leaks Cucumber hid.** Specs run `config.order = :random`, surfacing cross-example leaks Cucumber's ordering masked. A step migrated verbatim that sets process-global/thread-local state (`User.current`, `Time.zone`, `RequestStore[...]`, `I18n.locale`, a class attribute) and never restores it leaks into later examples — it may fail under random order though the code came straight from Cucumber (**pre-existing, not migration-caused — flag it as such**). Fix with a reset hook:
  ```ruby
  config.after(:each, type: :feature) { User.current = nil }
  ```

- **Carry quoted strings over verbatim — never "correct" them.** Labels, captions, and expected text matched what the app renders, and it renders the same HTML after migration — so the original literal is correct by definition. The classic trap: `select "group role for john doe"` looks mis-cased, but the app's label helper lowercases it, so "fixing" it to `"John Doe"` breaks the locator. Keep the exact string.
  - **Match the app's *typographic* glyphs, not the `.feature`'s ASCII.** German flash/text uses curly quotes — `„` (U+201E, open) … `"` (U+201C, close), **not** the straight `"` or the English `"` (U+201D). The `.feature` source sometimes carries an ASCII `"` that doesn't match what the app actually renders; assert on the exact glyphs the app produces (check the view/locale, or the rendered page), or the matcher silently won't find the text.
  - **Edit files with non-ASCII via the Write tool, not `sed -i` / `perl -i`.** In-place stream edits on a UTF-8 file containing typographic quotes/umlauts can **double-encode** the bytes (mojibake). Rewrite the whole file with Write instead.

- **Searchable Select2/Tom Select — plain `select` silently doesn't stick.** On a *searchable* Select2 the native `<select>` is hidden, so `select 'X', from: 'Y'` reverts to blank and never round-trips (a submit-on-change form then never fires). *Non-searchable* Select2 works with plain `select`. Use a `select_from_select2(text, from:)` helper — open the widget, then click the individual option `li.select2-results__option` by **exact text** (the `li`, not the `.select2-results__options` container), **then confirm the commit on *that* field — assert its selected value (scoped to the widget) before returning**, a deterministic sync point so the async `change`/dependent request can't race a later step on CI. Common across makandra apps; full recipe in `spreewald-guide.md` §`select_from`.

- **Asserting a disabled `<select>`'s value.** `have_field(label, disabled: true, with: 'V')` **fails** on a `<select>` — for a select it matches the selected *option text* (often a placeholder like "Please choose…"), not `with:`. Use `have_select(label, disabled: true, selected: 'V')` instead.
