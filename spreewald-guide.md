# Spreewald → RSpec/Capybara migration guide

## What this guide is

We are migrating legacy Rails apps from **Cucumber** feature tests (which lean heavily on the
[`spreewald`](https://github.com/makandra/spreewald) gem's canned step definitions) to **RSpec feature specs**
that call Capybara directly. This document maps each Spreewald step to its idiomatic RSpec/Capybara
equivalent, so a downstream conversion agent can translate `.feature` files into `spec/features/*_spec.rb`
mechanically and consistently.

You (the conversion agent) convert the Cucumber + Spreewald prose in the **target repo's own `features/**`**. When a rule below isn't enough, read the source of the gems the app bundles (`bundle show <gem>`, run inside the target repo):

- **Spreewald** — `bundle show spreewald`; every rule below cites the exact `file:line` it maps (`lib/spreewald/*_steps.rb`, and `lib/spreewald_support/*` for internal helpers).
- **Capybara** — `bundle show capybara`, if you need to confirm an API.

For house-style precedent when in doubt about idiom, grep the target app's **own** already-migrated `spec/features/**` and existing `spec/support/` — not another project's code.

> **Support files: the target `spec/` is light on *feature-spec* helpers — but never truly empty.** The app
> already runs RSpec for model/controller/request specs, so `spec/support/` has support code (some of it
> feature-adjacent), just usually no feature-spec helpers/matchers. So whenever a mapping below recommends a
> helper or custom matcher (because the direct Capybara translation would be too verbose), this guide **inlines
> the full support-file source** — but treat it as a **fallback for when the app has no equivalent**, not a
> "paste verbatim" order:
> - If the app **already defines an equivalent** helper (e.g. its own `DownloadHelpers`/`MailHelpers` used by
>   other specs), **migrate/extend *that* — it's usually richer — and never overwrite it** (overwriting regresses
>   the existing specs that depend on it; see the app-guide's Phase 3a audit). Unify existing + needed into one
>   file serving all callers.
> - Only when there's no equivalent, create the file from the inlined source here.
>
> Helper *modules* are mixed in for feature specs only (`config.include(SomeHelper, type: :feature)`); custom
> *matchers* defined with `RSpec::Matchers.define` register globally and need no `include`. (Our matchers are
> named to coexist — e.g. `have_table_with_rows` deliberately differs from a stricter app `have_table_with_contents`
> — so create them as given rather than reusing a same-named app matcher with different semantics.)
>
> **Define a negated alias for every custom matcher** so its `have_no_*` form exists — after each `RSpec::Matchers.define`,
> add e.g. `RSpec::Matchers.define_negated_matcher :have_no_flash, :have_flash`. `match_when_negated` only makes
> `expect(page).not_to have_flash` work; it does **not** create a `have_no_flash` *method*, so
> chaining `.and have_no_flash` onto an expectation raises `NoMethodError` without the alias. (Capybara's
> built-in matchers get their `have_no_*` for free; your custom ones don't.)

### How to read a rule

Each rule has a **Step regexp** (+ source location), an **Intent**, a **Mapping** (usually a *before* Cucumber
line and an *after* RSpec snippet), and optional **Notes / trade-offs**. Rules are grouped by the Spreewald
`*_steps.rb` file they come from.

### Cross-cutting conventions (read first — they apply to almost every rule)

> **Conventions shared with `app-migration-guide.md` are owned there — not repeated here.** This guide is
> always used alongside the app-migration guide, so for the cross-cutting rules it defines (dropping
> `patiently`, `path_to`/`selector_for` inlining, `@javascript` → `js: true`, `feature`/`scenario`/`background`
> structure, override detection) the app-guide is the single source of truth. The notes below are brief
> pointers plus the **Spreewald-specific** detail (e.g. the `patiently` helper source, which steps need which
> driver). Apply the full rule from the app-guide.

1. **Drop `patiently do … end`.** Almost every Spreewald step wraps its body in `patiently`; you normally drop
   it — see *Remove redundant `patiently`* in `app-migration-guide.md` for the rationale (Capybara retries
   internally and these apps run [capybara-lockstep](https://github.com/makandra/capybara-lockstep)). Only keep
   (or add) an explicit retry when a **multi-statement block must re-run atomically** — the prime case is a
   `within` over a fragment that re-renders *on its own* (Unpoly `up-validate`/`up-poll`, a polling widget),
   which raises `StaleElementReferenceError` mid-block because Capybara can retry a single command but not the
   whole block (see the *auto-retries a single expression, not an interdependent sequence* gotcha in `conversion-guide.md`). If a conversion genuinely
   needs it, use the **[`patiently` gem](https://rubygems.org/gems/patiently)** — the extracted form of the
   helper mandoline used to vendor, with the same `patiently` / `patiently_wait_until` methods. Add it to the
   test group and wire it into RSpec (don't re-vendor the module):
   ```ruby
   # Gemfile — test group
   gem 'patiently'
   ```
   ```ruby
   # spec/support/patiently.rb
   require 'patiently/rspec'   # provides `patiently` and `patiently_wait_until` in feature specs
   ```

   **How the gem behaves** (it was extracted from a *later* makandra `patiently` that no longer discriminates by
   error class — older apps may still have a custom `patiently` / `ToleranceForSeleniumSyncIssues` with a
   `RETRY_ERRORS` allowlist): it **retries the block on any exception** until it stops raising or the timeout
   expires. So whatever an app pushed into a `RETRY_ERRORS` allowlist is already covered — **nothing to port**.
   The flip side: it also retries errors that should *fail fast* (a real bug, a genuine assertion failure), so a
   legitimately-failing block spends the whole timeout before surfacing and can obscure the error — **keep
   `patiently` blocks tight** (wrap only the racy read). Configure via `Patiently.configure { |c| c.timeout = …;
   c.max_retries = … }`; its default timeout is its own, so set `c.timeout = Capybara.default_max_wait_time`. But
   that value is read **when you configure it** — if some examples widen Capybara's wait via metadata (a `:slow`
   tag bumping `Capybara.default_max_wait_time`), a config pinned at load time won't see it, so pass the wait at
   the **call site** instead: `patiently(Capybara.default_max_wait_time) { … }`.

   The gem also provides **`patiently_wait_until`**, which the internally-retrying matchers below
   (`have_table_with_rows`, `have_content_in_order`, `have_field_error`) rely on — so add the gem whenever you
   ship any of those matchers, not only for an explicit `patiently do … end`. *(Rails 2 / RSpec 1 apps can't use
   `patiently/rspec` — it calls `RSpec.configure`; those vendor the module instead, see `rails2-guide.md`.)*

   The inlined custom matchers that read **live page state** (`have_table_with_rows`, `have_content_in_order`, `have_field_error`) use `patiently_wait_until` so they **retry internally**, just like Capybara's built-in matchers — so you do **not** wrap their call sites in `patiently`. (`have_flash` already waits via Capybara's `has_css?`, and `have_downloaded_a_file` already wraps in `patiently`.) The mail matchers are the exception: `have_mail_attributes` asserts on a **mail object you pass in**, so retrying it re-checks the same object — if delivery is asynchronous (e.g. via a job), retry the *selection* at the call site instead, e.g. `mail = patiently { ActionMailer::Base.deliveries.last.tap { |m| raise 'no mail yet' unless m } }`.

   > **The rule, not just these three: every custom matcher that reads live page state must retry.** This applies to any **ad-hoc** matcher or helper you write during the migration too (e.g. one that reads a `<meta name=robots>` content, a header, or a computed style) — read the DOM **once** and it returns a transient `nil`/stale value under load (an in-flight Unpoly head-swap, the extra latency of parallel browsers), so it flakes only in the full parallel run, never when you author it. Wrap the read in `patiently`/`patiently_wait_until` so it retries like a Capybara matcher — never a single non-retrying `page.evaluate_script` / `find(...)[:content]` read. **And it must fail *soft* (return false), never raise:** inside an `.and` chain a raised `Capybara::ElementNotFound` (e.g. from a bare `find_field`) aborts the *whole* compound expectation instead of just not-matching, so Capybara never retries the chain and the reported failure names a *downstream* matcher. `patiently_wait_until` returns a boolean, which keeps the matcher composable. (Relatedly, a lookup used only to *locate* an element must pass `disabled: :all` if that element can be disabled — field finders skip disabled fields and would otherwise raise; see the *Migration gotchas* in `conversion-guide.md`.)

2. **`path_to(...)`** → inline the resolved route helper / path. See *Mapping of English to route paths* in
   `app-migration-guide.md` (always inline, never port the resolver).

3. **`selector_for(...)`** → inline the resolved CSS selector. See *Mapping of English to selectors* in
   `app-migration-guide.md`.

4. **`step "..."` chaining / `with_scope`.** Some Spreewald steps call other steps. In RSpec you inline the
   equivalent Capybara call rather than re-dispatching prose.

5. **Negation.** Most assertion steps carry an optional `( not)?`. Map the positive form to `expect(page).to …`
   / `have_…` and the negative form to `expect(page).not_to …` or the matching `have_no_…` matcher (Capybara
   provides `have_no_content`, `have_no_css`, `have_no_field`, `have_no_select`, etc.). `have_no_*` is preferred
   over `not_to have_*` for negative assertions because it waits correctly (it retries until the element is
   *absent* instead of returning immediately).

6. **`feature` / `scenario` / `background`.** Structural conversion, not a Spreewald step — see Phase 5 of
   `app-migration-guide.md`.

7. **`@javascript` → `js: true`.** See *Understanding @javascript and js: true* in `app-migration-guide.md` for
   the mapping. **Spreewald-specific:** several steps **only work under `js: true`** (a real browser) — browser
   dialogs (`accept_confirm` …), browser tabs, iframes, `go_back`, and Tier 2 of `download_filename`; conversely
   rack-test-only assertions (`page.status_code`, `page.response_headers`) require a *non*-`js` scenario. Keep
   that in mind when carrying the tag across.

8. **Ignore `@slow-motion` and `@single-step`.** These Spreewald tags are developer debugging aids (they slow
   down or pause the browser between steps) that should never have been committed. **Drop them** — do **not**
   migrate them to `js: true`-style metadata or any RSpec hook.

9. **Organizational / topical tags → RSpec metadata; never drop them silently.** Tags with no behavior that
   developers use to run subsets (`@smoke`, `@search`, `@billing`, `@wip`, …) — the Cucumber equivalent of
   `cucumber --tags @smoke` — must carry over as RSpec metadata symbols, so the same filtering works with
   `rspec --tag smoke`. Put the symbol on the `scenario` (or on the `feature` block for a feature-level tag):
   `scenario 'search returns results', :search do`. They carry no hook — they're pure labels — but dropping
   them would silently break developers' `--tag` workflows. (Contrast item 8: only the *debug* tags are dropped.)

   **A CI-*exclusion* tag is the same deal, in both directions.** When Cucumber CI ran `--tags 'not @real-api-requests'`, that exclusion reflects what the CI *container* can't do (typically real outbound network) — it says **nothing** about the scenario's validity, and it must **never** gate *local* migration or verification (you migrate and verify 100% of scenarios locally; see *The contract: parity, not improvement* in `app-migration-guide.md`). Preserve it for **CI parity**: keep the tag as metadata (`:real_api_requests`) so RSpec CI can exclude the same scenarios (`rspec --tag ~real_api_requests`). Parity runs both ways — if the origin did *not* tag a scenario, it stays un-excluded in RSpec CI too (it ran in Cucumber CI → it runs in RSpec CI). So: carry the tag for CI behaviour, but verify the scenario locally regardless.

10. **Grepping for a tag can match email addresses.** A bare search for `@foo` also hits `user@foo.com` in test
   data — inflating tag counts and matching the wrong lines. Anchor the tag to where tags actually sit (line
   start or after whitespace, never mid-token), e.g. `rg '(^|\s)@foo\b' features/`.

---

## Scope & coverage (important — read before converting)

This guide is **not exhaustive of the Spreewald gem**. It maps only the Spreewald steps that were observed
**actually in use** across a large sample of makandra Cucumber apps. (Authoring process: enumerate all
step definitions in Spreewald's `lib/spreewald/*_steps.rb`, then keep only those whose regexp
matches at least one real `.feature` line.) Of 87 step definitions, **74 are used and mapped here**; 13 unused
ones are deliberately omitted (listed below).

**When you (the conversion agent) encounter a step this guide does not map, do NOT guess or assume the guide is
exhaustive. Flag it** — surface it to a human and request a mapping — then map it on demand. This includes:
- The **13 unused Spreewald steps omitted below**, should they appear in an app you convert.
- **App-specific steps** defined in each app's `features/step_definitions/` (e.g. `I am signed in`,
  `I save the form`, `I switch the language to "…"`). These are *not* Spreewald and are out of scope —
  the app's own step definitions are the source of truth for them. (One near-universal app-specific pattern —
  **flash messages** — has a ready matcher in the [Appendix](#appendix-shared-matchers-for-common-non-spreewald-steps),
  since it recurs in every app.)
- **`cucumber_factory` steps** (`Given there is a user with …`, `Given there are the following …`). These
  create FactoryBot records; convert them to direct `create(:model, attrs)` / `FactoryBot.create` calls by
  reading the factory — out of scope for this Spreewald guide.
- **`cucumber_priority` overrides.** An app may shadow a Spreewald step with its own definition in
  `features/step_definitions/` (marked `.overridable`). This guide ignores overrides; before applying a
  Spreewald mapping in a given app, **check that app's `features/step_definitions/` for a step whose regexp
  also matches the line** — if one exists, convert per that app definition instead.

### Omitted (unused) Spreewald steps

These exist in the gem but matched no feature line in the example apps, so they have no rule here. If you meet
one, flag it (a few have a hint in parentheses):

- `web_steps.rb`: `attach the files [...] to "..."` (multi-file upload — like `attach_file` with an array),
  `should have the following query string:`, `follow "..." inside any "..."` (→ `within(...) do click_on end`),
  `fill in "..." with "..." inside any "..."`, `enter "..." into the browser dialog` (→ `accept_prompt(with:) { … }`,
  noted under `web_steps`).
- `email_steps.rb`: `show me the emails`, `show me the emails with:` (debugging — inspect
  `ActionMailer::Base.deliveries`).
- `browser_tab_steps.rb`: `there should be at least (\d+) browser tabs` (→ `expect(page.windows.size).to be >= N`).
- `frame_steps.rb`: **the entire file is unused** — `... inside the ... iframe`, `I switch to the ... iframe`,
  `I switch back to the whole page`. (If iframe steps appear later, the Capybara equivalents are
  `within_frame(:css, 'iframe#id') { … }` and `page.driver.switch_to_frame(...)` / `switch_to_frame(:top)`.)
- `session_steps.rb`: the doc-string variant `... in the browser session "...":`.

---

## `web_steps.rb`

The largest group: navigation, form interaction, clicking, and page/field assertions. 60 steps live here;
the 55 used across the example apps are mapped below (`enter "..." into the browser dialog` is also covered as
a bonus since it's the sibling of the confirm/cancel dialog steps).

### Navigation

#### `am_on`

**Step regexp** — `/^(?:|I )am on (.+)$/` (`web_steps.rb:67`)

**Intent** — Visit a page identified by an English page name.

**Mapping**
- before: `Given I am on the user list`
- after: `visit users_path`

Resolve the page name via the app's `features/support/paths.rb` (see convention #2).

#### `go_to`

**Step regexp** — `/^(?:|I )go to (.+)$/` (`web_steps.rb:71`)

**Intent** — Same as "am on" — visit a page by English name. (`Given`/`When` keyword is irrelevant.)

**Mapping**
- before: `When I go to the homepage`
- after: `visit root_path`

#### `should_be_on`

**Step regexp** — `/^(?:|I )should be on (.+)$/` (`web_steps.rb:75`)

**Intent** — Assert the current path (ignoring query string; tolerant of trailing-slash differences).

**Mapping**
- before: `Then I should be on the sign-in form`
- after: `expect(page).to have_current_path(new_user_session_path, ignore_query: true)`

**Notes** — **Default to `ignore_query: true`.** Spreewald's step compares only the `path` (+ fragment) and
*always* discards the query string, whereas Capybara's `have_current_path` matches the **full** URL (path + query)
by default — so without `ignore_query: true`, a stray param the app appends (`?from_search=true`, `?query=…`)
fails a check that passed under Cucumber. Only drop `ignore_query` in the rare case a scenario genuinely asserts a
specific query param. **But `ignore_query: true` strips the query only from the *page* URL, not from the *expected* path you pass** — so if the expected path itself carries a query (e.g. an engine without a locale segment turns `foo_path(locale: :de)` into `/foo?locale=de`), it never matches. Compare paths only: `expect(URI.parse(page.current_url).path).to eq(URI.parse(expected).path)`. `have_current_path` waits/retries, so no `patiently` is needed. (Seen widely in the reference RSpec apps.)

#### `reload_page`

**Step regexp** — `/^I reload the page$/` (`web_steps.rb:531`)

**Intent** — Reload the current page.

**Mapping**
- after (JS / Selenium scenario): `page.refresh`
- after (non-JS / rack-test scenario): `visit current_path`

**Notes** — On **Selenium**, `page.refresh` is the closest built-in and preserves the full URL incl.
query/params. On **rack-test**, prefer **`visit current_path`**: `page.refresh` there does *not* re-issue the
request in a way that re-runs the controller's `before_action`s (e.g. a locked-out user stays on the page after
`page.refresh`, but `visit current_path` re-runs the filters and redirects).
`visit current_path` drops the query string (matching one of Spreewald's own branches); if the scenario depends
on query params, rebuild the path with them.

**Exception — a page with a `beforeunload` handler:** `page.refresh` is a WebDriver navigation that **blocks until any BeforeUnload dialog is answered**, so on a scenario that inspects that dialog it dies with `Selenium::WebDriver::Error::TimeoutError` (and then poisons teardown with `Unexpected dialog type beforeunload`). Reload from *inside* the page instead — `page.execute_script('window.location.reload()')` — which returns immediately and leaves the dialog standing. (Spreewald's own JS branch does exactly this; the recommended `page.refresh` differs, so *Watch for app overrides* won't catch it — it's the guide idiom that's wrong here.)

#### `go_back`

**Step regexp** — `/^I go back$/` (`web_steps.rb:727`)

**Intent** — Navigate to the previous page (browser history back).

**Mapping**
- before: `When I go back`
- after: `go_back`  *(Capybara built-in for JS drivers; equivalent to `page.go_back`)*

**Notes** — Spreewald falls back to visiting the `Referer` on non-JS (rack-test) drivers. Feature specs are
almost always JS/Selenium, so `go_back` is fine. If the spec is rack-test, use `visit` with the previous path.

#### `basic_auth`

**Step regexp** — `/^I perform basic authentication as "([^"]*)\/([^"]*)" and go to (.*)$/` (`web_steps.rb:709`)

**Intent** — Visit a page with HTTP Basic Auth credentials.

**Mapping**
- before: `When I perform basic authentication as "admin/secret" and go to the RSS feed`
- after (JS/Selenium driver — credentials in the URL):
  ```ruby
  visit "http://admin:secret@#{Capybara.current_session.server.host}:#{Capybara.current_session.server.port}#{rss_path}"
  ```
- after (rack-test driver):
  ```ruby
  page.driver.header('Authorization', ActionController::HttpAuthentication::Basic.encode_credentials('admin', 'secret'))
  visit rss_path
  ```

**Notes** — Rarely used (2 occurrences). Pick the branch matching the spec's driver. The two-line mapping
above is enough; no support file is needed. **Don't use `page.driver.basic_authorize('u', 'p')`** for the
rack-test branch — it's gone on modern Capybara (raises `NoMethodError: undefined method 'basic_authorize'
for Capybara::RackTest::Driver` on Capybara 3.40); set the `Authorization` header explicitly as above.

### Form input

#### `press`

**Step regexp** — `/^(?:|I )press "([^"]*)"$/` (`web_steps.rb:91`)

**Intent** — Click a button (by label, value, id, or title).

**Mapping**
- before: `When I press "Save"`
- after: `click_button 'Save'`

**Notes** — Spreewald's `press` is **strictly `click_button`** (`web_steps.rb:91` calls `click_button(button)`), so
map it to `click_button`, **not** `click_on`. This matters: `click_on` also matches links, and pages very often
have a nav link whose text equals a submit button's label (e.g. a "Sign in" nav link beside the "Sign in" submit
button). `click_on 'Sign in'` can then click the *link* — silently re-rendering the form instead of submitting —
a confusing failure that looks like the action did nothing. Reserve `click_on` for the `follow` (link) step.

#### `follow`

**Step regexp** — `/^(?:|I )follow "([^"]*)"$/` (`web_steps.rb:97`)

**Intent** — Click a link (by text, id, or title).

**Mapping**
- before: `When I follow "Edit"`
- after: `click_on 'Edit'`  *(or `click_link 'Edit'` to restrict to links)*

**Notes — apps that set `Capybara.match = :prefer_exact`.** Spreewald's `follow`/`press` click the label with `:prefer_exact`, so `follow "Invoice"` hits the exact "Invoice" link even when an "Invoices" one also exists. If you disambiguate a duplicate with `match: :first`, you **defeat** prefer_exact (a substring match like "Invoices" can win) — use **`exact: true`** instead: `click_on 'Invoice', exact: true` (add `match: :first` too only if several *exact* matches remain). Reach for `exact: true` over `match: :first` whenever the app uses `:prefer_exact`.

#### `fill_in_with`

**Step regexp** — `/^(?:|I )fill in "([^"]*)" (?:with|for) "([^"]*)"$/` (`web_steps.rb:104`)

**Intent** — Type a value into a text field (by label, name, placeholder, or id).

**Mapping**
- before: `When I fill in "Email" with "foo@bar.com"`
- after: `fill_in 'Email', with: 'foo@bar.com'`

#### `fill_in_with_squote`

**Step regexp** — `/^(?:|I )fill in "([^"]*)" (?:with|for) '(.*)'$/` (`web_steps.rb:128`)

**Intent** — Same as above; single-quoted value variant (used when the value contains double quotes).

**Mapping**
- before: `When I fill in "Snippet" with '<iframe src="...">'`
- after: `fill_in 'Snippet', with: '<iframe src="...">'`

**Notes** — Identical semantics to `fill_in_with`; only the quoting differs. In Ruby just use whichever quotes
keep the string readable (or a `%q`/heredoc).

#### `fill_in_with_multiline`

**Step regexp** — `/^(?:|I )fill in "([^"]*)" (?:with|for):$/` (`web_steps.rb:121`)

**Intent** — Fill a (text-area) field with a multi-line doc-string value.

**Mapping**
- before:
  ```cucumber
  When I fill in "Body" with:
    """
    Apple
    Banana
    """
  ```
- after:
  ```ruby
  fill_in 'Body', with: "Apple\nBanana"
  ```

**Notes** — The Cucumber doc-string becomes a Ruby string; a heredoc (`<<~TEXT`) reads well for longer values.

#### `select_from`

**Step regexp** — `/^(?:|I )select "([^"]*)" from "([^"]*)"$/` (`web_steps.rb:135`)

**Intent** — Select an option from a `<select>` (by visible option text, select identified by label/name/id).

**Mapping**
- before: `When I select "Germany" from "Country"`
- after: `select 'Germany', from: 'Country'`

**Notes** — Plain `select` works for native `<select>` elements, and for **non-searchable** Select2/Tom Select
(the native `<select>` is still driven). But a **searchable** Select2 hides the native `<select>`, so
`select 'X', from: 'Y'` silently doesn't stick — the value reverts to blank and (on a submit-on-change form)
the change never round-trips. This is common across makandra apps, so keep a small helper for it: open the
widget, then click the individual option **`li.select2-results__option`** by exact text — click the `li`,
**not** the `.select2-results__options` container:

```ruby
# spec/support/feature_steps/select2_steps.rb
def select_from_select2(option_text, from:)
  field = find_field(from, visible: :all)   # the (hidden) native <select> for this label
  field.sibling('.select2').click           # open THIS field's widget (adjust to the app's markup)
  find('li.select2-results__option', text: option_text, exact_text: true).click

  # Sync before returning: wait until THIS field actually holds the value. Select2/Tom Select
  # commit the value and fire `change` asynchronously; asserting the committed value — scoped to
  # this widget so it can't match another select on the page — is a deterministic sync point.
  # (Tom Select / tail.select: scope to the field's widget and check its `.item` / `.label-inner`.)
  expect(field.sibling('.select2')).to have_css('.select2-selection__rendered', text: option_text)
end
```

**The helper must both select *and* confirm the commit on *that* field — a deterministic sync point, not a timing guess.** A searchable select commits its value and fires `change` asynchronously; a dependent request (submit-on-change, or a `data-on-change-render` fragment reload) fires only then, and returning on the option-click alone lets it race a later step — observed on **CI** as spurious validation errors / a form that never saved (local runs are fast enough to hide it). So before returning, **assert the value on the field you just set**, scoped to *that* widget (or its native `<select>`) so you can't match another select on the page. That blocks until the commit has actually happened on that specific field — you move to the next step already in sync, with no dependence on framework timing.

Reach for this only when a plain `select` fails (most selects are native); for other JS-widget selects, write
the equivalent against that widget's markup.

#### `check`

**Step regexp** — `/^(?:|I )check "([^"]*)"$/` (`web_steps.rb:142`)

**Intent** — Check a checkbox (by label/name/id).

**Mapping**
- before: `When I check "Accept terms"`
- after: `check 'Accept terms'`

**Notes** — Spreewald passes `allow_label_click: true` (so a visually-hidden checkbox can be toggled via its
label). If a custom-styled checkbox doesn't respond to a plain `check`, add it back:
`check 'Accept terms', allow_label_click: true`.

#### `uncheck`

**Step regexp** — `/^(?:|I )uncheck "([^"]*)"$/` (`web_steps.rb:149`)

**Intent** — Uncheck a checkbox.

**Mapping**
- before: `When I uncheck "Accept terms"`
- after: `uncheck 'Accept terms'`

**Notes** — Same `allow_label_click: true` caveat as `check`.

#### `choose`

**Step regexp** — `/^(?:|I )choose "([^"]*)"$/` (`web_steps.rb:156`)

**Intent** — Select a radio button (by label/name/id).

**Mapping**
- before: `When I choose "Express shipping"`
- after: `choose 'Express shipping'`

#### `attach_file`

**Step regexp** — `/^(?:|I )attach the file "([^"]*)" to "([^"]*)"$/` (`web_steps.rb:163`)

**Intent** — Attach a file to a file-input field.

**Mapping**
- before: `When I attach the file "spec/fixtures/files/avatar.png" to "Avatar"`
- after: `attach_file 'Avatar', Rails.root.join('spec/fixtures/files/avatar.png')`

**Notes** — Spreewald passes `make_visible: true` on JS drivers so a CSS-hidden file input can still be set.
If the input is hidden, keep it: `attach_file 'Avatar', path, make_visible: true`. Capybara also offers
`file_fixture('avatar.png')` (rspec-rails) when the file lives under `spec/fixtures/files`.

**Multi-file** (`attach the following assets to "…":`) → `attach_file(field, [path1, path2], …)`, and the input must carry `multiple`. If you unify the single- and multi-file steps behind one helper, **unwrap a one-element array** — `attach_file(field, paths.many? ? paths : paths.first, …)` — because Capybara 3.40 raises `ArgumentError: Value cannot be an Array when 'multiple' attribute is not present` for a single-file input **even when the array holds exactly one path**.

### Clicking arbitrary elements

#### `click_on_text`

**Step regexp** — `/^I click on "([^"]+)"$/` (`web_steps.rb:569`)

**Intent** — Click the *innermost* element containing the given text — even when it isn't a link or button
(e.g. a `<span>`, a toggle, a custom widget).

**Mapping**
- before: `When I click on "Collapse"`
- after (default — safe for any target): `click_on_text 'Collapse'`
- after (only when the target is *definitely* a link or button): `click_on 'Collapse'`

**Notes / trade-offs** — **Default to `click_on_text`.** Spreewald's step (`web_steps.rb:569`) finds the
*innermost* element whose text contains the string (`.//*[contains(., "…") and not(./*[contains(., "…")])]`) and
clicks it — so it works on non-interactive elements (a `<span>`, a toolbar item, a custom widget). Mapping it to
`click_on` is **not** equivalent: `click_on` only matches links and buttons, so it fails on those non-interactive
targets (e.g. a toolbar "Share"). Only simplify to `click_on 'X'` when you're sure the target is a real link
or button; when in doubt, use `click_on_text`, which mirrors Spreewald exactly.

**Support file — create in the target app** (`spec/support/click_helpers.rb`), needed only if a conversion
uses `click_on_text`:
```ruby
# spec/support/click_helpers.rb
module ClickHelpers
  # Clicks the innermost element whose text contains `text`, even when it is not a
  # link or button (mirrors Spreewald's `When I click on "..."`). Prefer Capybara's
  # `click_on` when the target is a real link or button.
  def click_on_text(text)
    literal = xpath_string_literal(text)
    find(:xpath, ".//*[contains(normalize-space(.), #{literal}) " \
                 "and not(.//*[contains(normalize-space(.), #{literal})])]").click
  end

  private

  # Builds an XPath string literal that safely quotes embedded ' and " characters.
  def xpath_string_literal(string)
    return %("#{string}") unless string.include?('"')
    return "'#{string}'" unless string.include?("'")

    parts = string.split('"', -1).map { |part| %("#{part}") }
    %(concat(#{parts.join(%(, '"', ))}))
  end
end

RSpec.configure { |config| config.include(ClickHelpers, type: :feature) }
```

#### `click_on_element`

**Step regexp** — `/^I click on the element "([^"]+)"$/` (`web_steps.rb:584`)

**Intent** — Click the element matching a CSS selector.

**Mapping**
- before: `When I click on the element ".sidebar-toggle"`
- after: `find('.sidebar-toggle').click`

#### `click_on_element_for`

**Step regexp** — `/^I click on the element for (.+?)$/` (`web_steps.rb:595`)

**Intent** — Click the element matching a **selector alias** from `selectors.rb`.

**Mapping**
- before: `When I click on the element for the main menu`
- after: `find('#main-menu').click`

**Notes** — Resolve the alias `the main menu` → CSS via the app's `features/support/selectors.rb` (convention #3).

### Text assertions

#### `should_see`

**Step regexp** — `/^(?:|I )should( not)? see "([^"]*)"$/` (`web_steps.rb:191`)

**Intent** — Assert visible text is / isn't present on the page.

**Mapping**
- before: `Then I should see "Welcome back"`
- after: `expect(page).to have_content('Welcome back')`
- before (negated): `Then I should not see "Error"`
- after: `expect(page).to have_no_content('Error')`

**Notes** — `have_content` matches visible text only (matches Spreewald). Use `have_no_content` for the
negative form (see convention #5).

#### `should_see_squote`

**Step regexp** — `/^(?:|I )should( not)? see '([^']*)'$/` (`web_steps.rb:249`)

**Intent** — Same as `should_see`, single-quoted (used when the expected text contains double quotes).

**Mapping**
- before: `Then I should see 'He said "hi"'`
- after: `expect(page).to have_content('He said "hi"')`

#### `should_see_regexp`

**Step regexp** — `/^(?:|I )should( not)? see \/(.*)\/$/` (`web_steps.rb:202`)

**Intent** — Assert the page text matches a regular expression.

**Mapping**
- before: `Then I should see /Order #\d+ confirmed/`
- after: `expect(page).to have_content(/Order #\d+ confirmed/)`

**Notes** — `have_content` (and `have_text`) accept a Regexp directly. Negated → `have_no_content(/…/)`.

**A *quoted* `should see "…"` is a literal `have_content`, not a regex** — the regex form is the *unquoted* `should see /…/` above. So a quoted negation carrying regex metacharacters — `Then I should not see "Budget .* exceeded"` → `have_no_content('Budget .* exceeded')` — is **vacuous**: the literal `.*` never appears in the rendered text, so it always passes. Carry it over **verbatim** for parity, but **flag it** as a vacuous literal negation (see *Repairing a bad test* in `app-migration-guide.md`) — it's the same class as a vacuous *waiting* negation, just hidden inside a quoted string rather than in the matcher's timing.

#### `should_see_html`

**Step regexp** — `/^I should( not)? see "([^"]*)" in the HTML$/` (`web_steps.rb:258`)

**Intent** — Assert the raw HTML source contains a string (including markup / hidden content).

**Mapping**
- before: `Then I should see "<meta name=\"robots\">" in the HTML`
- after: `expect(page.body).to include('<meta name="robots">')`
- negated: `expect(page.body).not_to include('...')`

**Notes** — Asserts on `page.body` (raw markup), unlike `have_content` which sees rendered text only. Does not
auto-retry; fine for synchronous content. If the markup is rendered after AJAX, wrap in `patiently { … }`.

#### `should_see_in_order`

**Step regexp** — `/^I should see in this order:?$/` (`web_steps.rb:312`)

**Intent** — Assert several strings appear in the page text in the given top-to-bottom order.

**Mapping** — Use the `have_content_in_order` matcher below (**add the support file**); it reads cleanly and
mirrors Spreewald's whitespace-collapsing behaviour:
- before:
  ```cucumber
  Then I should see in this order:
    | Augsburg |
    | Berlin   |
    | Cologne  |
  ```
- after:
  ```ruby
  expect(page).to have_content_in_order('Augsburg', 'Berlin', 'Cologne')
  ```
- for a one-off you can inline instead: `expect(page.text).to match(/Augsburg.*Berlin.*Cologne/m)`

**Notes** — Spreewald collapses runs of whitespace and joins the expected lines with `.*?` before matching the
page text. The matcher below does the same, so values that wrap across lines in the rendered HTML still match.

**Support file — create this matcher in the target app** (`spec/support/matchers/have_content_in_order.rb`).
Registers globally, so no `config.include` is needed:
```ruby
# spec/support/matchers/have_content_in_order.rb
#
# Asserts that the given strings appear in the page's visible text in the given
# order (top to bottom), allowing other content between them. Mirrors Spreewald's
# "I should see in this order:" step (whitespace is collapsed before matching).
RSpec::Matchers.define :have_content_in_order do |*expected|
  match do |page|
    patiently_wait_until do
      @text = page.text.gsub(/\s+/, ' ')
      pattern = expected.map { |line| Regexp.escape(line.to_s.gsub(/\s+/, ' ').strip) }.join('.*?')
      @text.match?(Regexp.new(pattern))
    end
  end

  failure_message do |_page|
    "expected page text to contain, in order:\n#{expected.inspect}\nbut got:\n#{@text}"
  end

  failure_message_when_negated do |_page|
    "expected page text NOT to contain #{expected.inspect} in order, but it did"
  end
end
```

#### `should_see_number`

**Step regexp** — `/^I should( not)? see the (?:number|amount) ([\-\d,\.]+)(?: (.*?))?$/` (`web_steps.rb:227`)

**Intent** — Assert a number/money amount appears, guarding against a stray leading minus and respecting
word/unit boundaries (so "5" doesn't match inside "150", and "-5" isn't satisfied by "5").

**Mapping** — Amounts almost always sit in their own element (a `<td>`, `<span>`, badge, etc.). Assert the
amount is the **exclusive** text of some element using Capybara's `exact_text` — it strips enclosing
whitespace and inherently rejects `-600 EUR` and `1600 EUR` (their element text isn't exactly `600 EUR`), so it
solves the leading-minus / boundary concern without a hand-rolled regexp:
- before: `Then I should see the amount 600 €`
- after: `expect(page).to have_selector(:element, exact_text: '600 €')`
- negated: `expect(page).to have_no_selector(:element, exact_text: '600 €')`

**Notes / trade-offs** — Rarely used (2 occurrences, both trivial). `have_selector(:element, exact_text: …)`
matches any element whose whitespace-normalised text equals the value exactly. If a particular amount is *not*
isolated in its own element (it appears mid-sentence), fall back to `have_content('600 €')`; only when the
scenario is specifically testing the sign/boundary behaviour is an inline regexp warranted
(`expect(page.text).to match(/(?:[^\-]|^)\b600/)`). No custom matcher needed.

### Element / link presence assertions

#### `should_see_element`

**Step regexp** — `/^I should( not)? see (?:an|the) element "([^"]+)"$/` (`web_steps.rb:279`)

**Intent** — Assert an element matching the CSS selector is present.

**Mapping**
- before: `Then I should see an element ".panel"`
- after: `expect(page).to have_css('.panel')`
- negated: `expect(page).to have_no_css('.sidebar')`

**Notes** — Spreewald's `have_css` here does **not** require visibility (matches Capybara default of visible
elements). For a strict presence-regardless-of-visibility check use `have_css('.panel', visible: :all)`.

#### `should_see_element_for`

**Step regexp** — `/^I should( not)? see (?:an|the) element for (.*?)$/` (`web_steps.rb:294`)

**Intent** — Same as above but using a **selector alias** from `selectors.rb`.

**Mapping**
- before: `Then I should see the element for the cookie banner`
- after: `expect(page).to have_css('#cookie-banner')`

**Notes** — Resolve the alias via `features/support/selectors.rb` (convention #3). Negated → `have_no_css`.

#### `should_see_field`

**Step regexp** — `/^I should( not)? see a field "([^"]*)"$/` (`web_steps.rb:212`)

**Intent** — Assert a form field (input/select/textarea, by label or id) exists. The positive form also
matches disabled fields.

**Mapping**
- before: `Then I should see a field "Email"`
- after: `expect(page).to have_field('Email', disabled: :all)`
- negated: `expect(page).to have_no_field('Email')`

**Notes** — Spreewald uses `disabled: :all` on the positive check (so a disabled field still counts as
"seen"), and plain `have_no_field` on the negative. Keep `disabled: :all` only if scenarios assert presence of
disabled fields; otherwise a plain `have_field('Email')` is usually what's meant.

#### `should_see_link_labeled`

**Step regexp** — `/^I should( not)? see a link labeled "([^"]*)"$/` (`web_steps.rb:327`)

**Intent** — Assert a link with the given text **or** `title` attribute exists.

**Mapping**
- before: `Then I should see a link labeled "Home"`
- after: `expect(page).to have_link('Home')`
- negated: `expect(page).to have_no_link('Home')`

**Notes** — `have_link` matches link text, `title`, and `aria-label`, covering Spreewald's text-or-title
lookup. If a scenario specifically relies on matching via `title`, you can be explicit:
`have_link(title: 'Home')`.

#### `should_link_to`

**Step regexp** — `/^"([^"]*)" should link to "([^"]*)"$/` (`web_steps.rb:612`)

**Intent** — Assert a link with the given label points at the given href (ignoring a trailing query string).

**Mapping**
- before: `Then "Sponsor" should link to "https://example.com/"`
- after: `expect(find_link('Sponsor')[:href]).to match(%r{https://example\.com/(\?[^/]*)?$})`
- simpler, and the default when an exact href is fine: `expect(page).to have_link('Sponsor', href: 'https://example.com/')`

**Notes** — Prefer the clean `have_link(href:)` string form; for a typical link whose markup is an **absolute path** (`/sponsors/1`, no host) the raw attribute and the browser-resolved URL are identical, so it just works. Reach for the regexp form in the cases where they differ: `have_link(href:)` compares the **raw `href` attribute**, while `find_link(...)[:href]` (the regexp form) reads the **browser-resolved** URL — so `href="http://example.com"` *fails* `have_link(href: 'http://example.com/')` but *passes* the regexp (and the origin step was always green because Spreewald read the resolved property). So use the regexp form for a full host URL the browser may normalize (trailing slash), or when the href carries a query string Spreewald tolerated (cache-busting `?ts=…`).

### Visibility assertions

#### `should_be_visible`

**Step regexp** — `/^(the tag )?"([^"]+)" should be visible$/` (`web_steps.rb:546`)

**Intent** — Assert an element (by **text** by default, or by **selector** when prefixed with `the tag`) is
present *and* actually visible (CSS-aware on Selenium).

**Mapping**
- before (by text): `Then "Sign out" should be visible`
- after: `expect(page).to have_content('Sign out')`  *(visible text; `have_content` already excludes hidden text)*
- before (by selector): `Then the tag ".flash" should be visible`
- after: `expect(page).to have_css('.flash', visible: true)`

**Notes** — Capybara's default visibility filtering already implements "visible". The text form maps to
`have_content`; the `the tag` form maps to `have_css(selector, visible: true)`.

**Scope it when the origin said `within`.** Spreewald's text-form visible/hidden step runs `document.querySelectorAll('*')`, so `"A3" should be visible within the 3rd menu level` really only checks that "A3" is visible *somewhere* — it ignores the `within`. Map it **scoped** anyway — `within('.menu-3') { expect(page).to have_content('A3') }`: **our matchers respect the `within` scope**, and a Spreewald step that ignored it was a Spreewald bug we don't reproduce. Scoping is deliberately stricter than the (buggy) origin, which is the correct behaviour — not a risky bet.

#### `should_be_hidden`

**Step regexp** — `/^(the tag )?"([^"]+)" should be hidden$/` (`web_steps.rb:556`)

**Intent** — Assert an element is present in the DOM but **not** visible (hidden via CSS).

**Mapping**
- before (by selector): `Then the tag ".flash" should be hidden`
- after: `expect(page).to have_css('.flash', visible: :hidden)`
- before (by text): `Then "Secret" should be hidden`
- after: `expect(page).to have_css('*', text: 'Secret', visible: :hidden)` *(or simply `have_no_content('Secret')` if "present-but-hidden" vs "absent" doesn't matter)*

**Notes / trade-offs** — `visible: :hidden` asserts the node exists but is invisible (this is the precise
analogue of Spreewald's `assert_hidden`). If the scenario really just means "the user can't see this", the
simpler `have_no_content` is usually intended — pick based on whether the DOM node is expected to still exist.

**The by-text `visible: :hidden` form is vacuous when a *second*, hidden copy of the text exists elsewhere** (two locale keys rendering identical help text, one shown and one hidden, is a common cause). `have_css('*', text: 'X', visible: :hidden)` keeps passing even after the text became visible, because *some* hidden match is always present. When "hidden" is genuinely the point, assert both halves: the text is present somewhere **and** not visible — `expect(page).to have_text(:all, 'X')` together with `expect(page).to have_no_text(:visible, 'X')`. (The positive `should be visible` by-text is the mirror: `have_text(:visible, 'X')`, i.e. `have_content('X')`.)

### Field value / state assertions

#### `field_should_contain`

**Step regexp** — `/^the "([^"]*)" field should( not)? contain "([^"]*)"$/` (`web_steps.rb:334`)

**Intent** — Assert an input/textarea/select's current value (for a select: its selected option's text).
Supports `*` as a wildcard.

**Mapping**
- before: `Then the "Email" field should contain "foo@bar.com"`
- after: `expect(page).to have_field('Email', with: 'foo@bar.com')`
- before (select): `Then the "Country" field should contain "Germany"`
- after: `expect(page).to have_select('Country', selected: 'Germany')`
- negated input: `expect(page).to have_no_field('Email', with: 'foo@bar.com')`

**Notes** — Spreewald auto-detects the control type; in RSpec you pick the matcher:
- **Text input / textarea** → `have_field(..., with:)`. **Select** → `have_select(..., selected:)` (compares the selected option's text).
- **Wildcard:** if the expected value uses `*`, translate to a regexp — `have_field('Email', with: /foo.*bar/)`.
- **Disabled field:** `have_field(label, disabled: true, with: value)` works for an `<input>`/`<textarea>` — the `disabled:` and `with:` filters are independent — and reads well in an `.and` chain: `expect(page).to have_field('Email', disabled: true, with: 'foo@bar.com')`. The `find_field` form (`expect(find_field('Email', disabled: :all).value).to eq('foo@bar.com')`) is only needed for a **`<select>`**, where you'd instead use `have_select(label, disabled: :all, selected: …)`.
- **JS-enhanced selects** (Tom Select, Tail Select, Slim Select, Select2) render their own DOM but **auto-sync to the underlying (hidden) native `<select>`**, so `have_select` / `select` / `find_field` work against that native element as usual. Only if you must drive or read the *widget's own* DOM (several elements) do you need a small custom helper — reach for that rather than inlining.
- **Empty field** (`should contain ""`): **`have_field('X', with: '')` never matches** — an empty `<input>` reads its value back as `nil`, and neither `''` nor a regexp matches `nil` (verified against Capybara 3.38). There's no built-in for it, so ship a small **retrying** `have_empty_field` matcher alongside the other foundation matchers and use `expect(page).to have_empty_field('X')`. **Don't "simplify it away" as a no-op** — Spreewald's matcher did `field_value.to_s`, so it genuinely asserted emptiness:
  ```ruby
  RSpec::Matchers.define :have_empty_field do |locator|
    match { |page| patiently_wait_until { page.find_field(locator, disabled: :all).value.to_s.empty? } }
  end
  # + a negated alias (define_negated_matcher), per the matcher note above
  ```

#### `field_should_contain_ml`

**Step regexp** — `/^the "(.*?)" field should( not)? contain:$/` (`web_steps.rb:354`)

**Intent** — Like `field_should_contain` but with a multi-line doc-string expected value (textareas).

**Mapping**
- before:
  ```cucumber
  Then the "Body" field should contain:
    """
    Line 1
    Line 2
    """
  ```
- after: `expect(page).to have_field('Body', with: "Line 1\nLine 2")`

**Notes** — Spreewald `chomp`s the field value. Same wildcard caveat as above.

#### `should_be_selected`

**Step regexp** — `/^"([^"]*)" should( not)? be selected for "([^"]*)"$/` (`web_steps.rb:486`)

**Intent** — Assert which option is selected in a `<select>` (delegates to `field should contain`).

**Mapping**
- before: `Then "Germany" should be selected for "Country"`
- after: `expect(page).to have_select('Country', selected: 'Germany')`
- negated: `expect(page).to have_select('Country', selected: 'Germany')` → use `have_no_select('Country', selected: 'Germany')`

**Disabled select:** this step (like `field should contain` and `should_be_an_option`) goes through Spreewald's `find_with_disabled` (`disabled: :all`), so a `<select>` the app renders **disabled** (e.g. "Supplier" until "External order" is checked) needs `have_select('Supplier', disabled: :all, selected: 'Example Corp')` — a plain `have_select` raises `ElementNotFound`.

#### `nothing_selected`

**Step regexp** — `/^nothing should be selected for "([^"]*)"$/` (`web_steps.rb:490`)

**Intent** — Assert that **no non-blank option is selected**. Spreewald finds the selected option and passes
when its **value** is blank (or when nothing is selected at all — it rescues "not found").

**Mapping** (single-value select — the common case)
- before: `Then nothing should be selected for "Country"`
- after: `expect(page.find_field('Country').value).to be_blank`

`find_field(…).value` returns the **selected option's value**, so this stays faithful whether the placeholder
option's *text* is blank or something like `"Please choose"`. Prefer it over `have_select('Country', selected: '')`,
whose `selected:` matches the option **text**, not its value — so a placeholder with visible text slips through.

**Notes — multiple selects behave differently.** A `multiple` select's `.value` is an **array** (`[]` when
nothing is selected), so `be_blank` still holds — but "nothing selected" then means genuinely *no* option is
chosen, with **no implicit first-option fallback** (that fallback is right only for a single select without a
blank option). Don't reuse a single-select helper for a multiple one.

#### `should_be_an_option`

**Step regexp** — `/^"([^"]*)" should( not)? be an option for "([^"]*)"$/` (`web_steps.rb:503`)

**Intent** — Assert a `<select>` does / doesn't offer an option with the given text.

**Mapping**
- before: `Then "Germany" should be an option for "Country"`
- after: `expect(page).to have_select('Country', with_options: ['Germany'])`
- negated: `expect(page).to have_no_select('Country', with_options: ['Germany'])`

**Notes** — `with_options:` checks the listed options are present (subset); it's the canonical RSpec form, so
prefer it. For an exact option-set assertion use `options:` instead. **Disabled select:** same as `should_be_selected` above — a `<select>` rendered disabled needs `have_select('Supplier', disabled: :all, with_options: [...])`, or it raises `ElementNotFound`. **Caveat — `with_options:` matches option
text by *substring*, while Spreewald uses `exact_text`.** So the **negated** form gives a false failure when a
sibling option shares a prefix: `have_no_select('Region', with_options: ['North'])` fails if the list also
holds `"North East"`. When a negation could hit a prefix-sharing sibling, assert exactly instead —
`expect(find_field('Region')).to have_no_css('option', exact_text: 'North')` (positive:
`have_css('option', exact_text: …)`).

#### `select_sorted`

**Step regexp** — `/^the "(.*?)" select should( not)? be sorted$/` (`web_steps.rb:741`)

**Intent** — Assert a select's (non-blank) options are in sorted order.

**Mapping**
- before: `Then the "Country" select should be sorted`
- after:
  ```ruby
  option_texts = find_field('Country').all('option').map(&:text).reject(&:blank?)
  expect(option_texts).to eq(option_texts.sort)
  ```

**Notes** — Very rare (1 occurrence). Spreewald uses `natural_sort` if available, else `sort`. Plain `sort` is
usually fine; if a natural/locale sort is required, sort with an explicit comparator. Inline is acceptable.

#### `checkbox_checked`

**Step regexp** — `/^the "([^"]*)" checkbox should( not)? be checked?$/` (`web_steps.rb:417`)

**Intent** — Assert a checkbox is / isn't checked.

**Mapping**
- before: `Then the "Accept terms" checkbox should be checked`
- after: `expect(page).to have_checked_field('Accept terms')`
- negated: `expect(page).to have_unchecked_field('Accept terms')`

**Notes** — Use `have_unchecked_field` for the negative form (not `have_no_checked_field`), to assert the box
exists and is unchecked — matching Spreewald, which finds the field then asserts `be_checked` / not.

#### `radio_checked`

**Step regexp** — `/^the radio button "([^"]*)" should( not)? be (?:checked|selected)$/` (`web_steps.rb:426`)

**Intent** — Assert a radio button is / isn't selected.

**Mapping**
- before: `Then the radio button "Express shipping" should be checked`
- after: `expect(page).to have_checked_field('Express shipping')`
- negated: `expect(page).to have_unchecked_field('Express shipping')`

#### `should_be_disabled`

**Step regexp** — `/^the "([^"]*)" (field|button|checkbox|radio button) should( not)? be disabled$/` (`web_steps.rb:671`)

**Intent** — Assert a field/button/checkbox/radio is / isn't disabled.

**Mapping**
- before: `Then the "Save" button should be disabled`
- after: `expect(page).to have_button('Save', disabled: true)`
- before (field): `Then the "Email" field should not be disabled`
- after: `expect(page).to have_field('Email', disabled: false)`

**Notes** — Use `have_button(..., disabled:)` for the `button` kind, `have_field(..., disabled:)` for
`field`/`checkbox`/`radio button`. Capybara's `disabled:` filter takes `true`/`false`/`:all`.

#### `field_should_be_visible`

**Step regexp** — `/^the "([^"]*)" field should( not)? be visible$/` (`web_steps.rb:688`)

**Intent** — Assert a form field is visible / hidden (CSS-aware).

**Mapping**
- before: `Then the "Coupon" field should be visible`
- after: `expect(page).to have_field('Coupon')`  *(Capybara only finds visible fields by default)*
- negated: `Then the "Coupon" field should not be visible`
- after: `expect(page).to have_field('Coupon', visible: :hidden)` *(present but hidden)* — or `have_no_field('Coupon')` if it may be absent entirely.

**Notes** — Spreewald finds the field even when hidden (`visible: false`) and then asserts the visibility, so
"not visible" specifically means "present but hidden". Use `visible: :hidden` to preserve that nuance.

### Form-values table

#### `form_with_values`

**Step regexp** — `/^I should see a form with the following values:$/` (`web_steps.rb:368`)

**Intent** — Assert several label→value pairs at once (delegates to `field should contain` per row).

**Mapping**
- before:
  ```cucumber
  Then I should see a form with the following values:
    | E-mail | foo@bar.com   |
    | Role   | Administrator |
  ```
- after:
  ```ruby
  expect(page).to have_field('E-mail', with: 'foo@bar.com')
  expect(page).to have_select('Role', selected: 'Administrator')
  ```

**Notes** — Expand the table into one assertion per row, choosing `have_field(with:)` or
`have_select(selected:)` per the control type (see `field_should_contain`). Rare (5 occurrences).

### Field error assertions

> These two steps assert a field's validation-error state, which depends on the app's error markup. Rather
> than hand-coding markup-specific selectors per scenario, **add the one `have_field_error` matcher below**
> (full source after the rules). It locates the error element via a configurable default selector that covers
> the markup of most Rails apps, and handles both "has an error" and "has the error '…'". Both rules use it.
>
> **First check for an app override, though.** This is a step apps frequently redefine in
> `features/step_definitions/` (e.g. mapping it to `have_field('X', class: 'is-invalid')`). Per the override
> rule, if the app has its own definition, convert *that* — you won't need this matcher at all. Only add
> `have_field_error` when the app relies on Spreewald's built-in.

#### `field_have_an_error`

**Step regexp** — `/^the "([^"]*)" field should( not)? have an error$/` (`web_steps.rb:407`)

**Intent** — Assert a field is (not) in a validation-error state.

**Mapping**
- before: `Then the "Email" field should have an error`
- after: `expect(page).to have_field_error('Email')`
- before (negated): `Then the "Email" field should not have an error`
- after: `expect(page).not_to have_field_error('Email')`

**Notes** — Used moderately (≈436×, concentrated in a few apps), so a single shared matcher pays off. Add the
`have_field_error` matcher below.

#### `field_should_have_error`

**Step regexp** — `/^the "([^"]*)" field should have the error "([^"]*)"$/` (`web_steps.rb:376`)

**Intent** — Assert a field has a validation error carrying **specific message text**.

**Mapping**
- before: `Then the "Email" field should have the error "is invalid"`
- after: `expect(page).to have_field_error('Email', 'is invalid')`

**Notes / trade-offs** — Spreewald looks for the message inside the field's error element and, failing that,
falls back to asserting `"#{Field.titlecase} #{message}"` (e.g. `Email is invalid`). The matcher below
substring-matches the message inside the located error element, so it passes whether the element renders
`is invalid` or `Email is invalid`. If a particular app's error message lives in an element the default
selector doesn't cover, edit the `error_selector` constant in the matcher (it's deliberately one place to tune).

**Support file — create this matcher in the target app** (`spec/support/matchers/have_field_error.rb`). Used by
both rules above. Registers globally, so no `config.include` is needed:
```ruby
# spec/support/matchers/have_field_error.rb
#
# Asserts a form field is in a validation-error state, optionally carrying a specific
# message. Mirrors Spreewald's `the "..." field should (have an error | have the error "...")`.
#
# The error element is found via ERROR_SELECTOR, which covers the common Rails markups:
#   - Rails default:  <div class="field_with_errors"><input ...></div>  (wrapper)
#   - Bootstrap:      <input class="... is-invalid">                    (class on the field)
#   - generic:        <span class="error">Message</span>               (sibling/nearby)
# The matched element may contain more than the message (we substring-match the message).
# If your app's markup differs, edit error_selector below — it's the single place to tune.
RSpec::Matchers.define :have_field_error do |field_label, message = nil|
  error_selector = '.error_message, .error-message, .field-with-errors, .field_with_errors, ' \
                   '.is-invalid, .is_invalid, .-invalid, .error'
  normalize = ->(text) { text.to_s.gsub(/[[:space:]]+/, ' ').strip }

  # The field's nearest block-level "row" wrapper (the .field_with_errors div for Rails,
  # or the .form-group / row that also holds a sibling error element for Bootstrap).
  find_row = lambda do |field|
    # `[1]` on the reverse `ancestor::` axis picks the CLOSEST matching ancestor.
    # Do NOT wrap the axis step in parentheses — `(ancestor::*[…])[1]` re-sorts the
    # node-set into document order, so `[1]` would pick the OUTERMOST ancestor (the
    # whole form/page) and `have_no_field_error` would match a sibling field's error.
    field.first(:xpath,
                'ancestor::*[self::div or self::li or self::p or self::td or self::fieldset][1]',
                minimum: 0, visible: :all)
  end

  error_elements = lambda do |page|
    field = page.find_field(field_label, disabled: :all, visible: :all)
    row = find_row.call(field)
    elements = []
    elements << field if field.matches_css?(error_selector)
    if row
      elements << row if row.matches_css?(error_selector)
      elements.concat(row.all(:css, error_selector, wait: false, minimum: 0, visible: :all).to_a)
    end
    elements
  end

  match do |page|
    patiently_wait_until do
      @elements = error_elements.call(page)
      next false if @elements.empty?
      next true if message.nil?

      @elements.any? { |element| normalize.call(element.text).include?(normalize.call(message)) }
    end
  end

  match_when_negated do |page|
    # "should not have an error": the field exists but no error element is associated.
    patiently_wait_until { error_elements.call(page).empty? }
  end

  failure_message do |_page|
    if message
      "expected field #{field_label.inspect} to have error #{message.inspect}, " \
        "but found error elements with text: #{@elements.map { |e| e.text.strip }.inspect}"
    else
      "expected field #{field_label.inspect} to be in an error state " \
        "(no element matching #{error_selector.inspect} was associated with it)"
    end
  end

  failure_message_when_negated do |_page|
    "expected field #{field_label.inspect} to have no validation error, but found one"
  end
end
```

### HTTP-level assertions (rack-test / response)

#### `should_see_error`

**Step regexp** — `/^I should see an error$/` (`web_steps.rb:267`)

**Intent** — Assert the HTTP status code is in the 400–599 range.

**Mapping**
- before: `Then I should see an error`
- after: `expect(page.status_code).to be_between(400, 599)`

**Notes** — `page.status_code` is only available on rack-test (not Selenium). Rare (3 occurrences); these are
typically request-style assertions. If the spec runs under Selenium, assert on the rendered error page text
instead (e.g. `have_content('404')`).

#### `response_content_type`

**Step regexp** — `/^I should get a response with content-type "([^"]*)"$/` (`web_steps.rb:463`)

**Intent** — Assert the `Content-Type` response header.

**Mapping**
- before: `Then I should get a response with content-type "application/pdf"`
- after: `expect(page.response_headers['Content-Type']).to match(%r{\Aapplication/pdf($|;)})`

**Notes** — rack-test only. The regexp anchors the start and allows a trailing `; charset=…`, matching
Spreewald.

#### `download_filename`

**Step regexp** — `/^I should get a download with filename "([^"]*)"$/` (`web_steps.rb:470`)

**Intent** — Assert a file download with the given filename. Spreewald reads the `Content-Disposition`
response header (and notes this "doesn't work with Selenium").

> **Testing real downloads is genuinely painful and the solutions keep churning** — see
> [makandra card 71430](https://makandracards.com/makandra/71430-capybara-testing-file-downloads). Pick the
> tier that fits the download; **most apps only need Tier 1.**

**Which tier? Use the scenario's `@javascript` tag.** A non-`@javascript` Cucumber scenario runs on rack-test
(→ Tier 1); a `@javascript` scenario runs on real Chrome (→ Tier 2, and the RSpec example carries `js: true` —
see convention #7).

**Tier 1 — rack-test scenario (no `@javascript`; preferred, works for most apps).** The download is a normal
link/button hitting a controller that `send_file`/`send_data`s. You don't need a real browser — assert the
`Content-Disposition` header, which is exactly what Spreewald does. Simple, fast, not flaky:
- before: `Then I should get a download with filename "report.pdf"`
- after: `expect(page.response_headers['Content-Disposition']).to match(/filename="?report\.pdf"?/)`

`page.response_headers` is only populated on rack-test (hence: no `@javascript`). For a download that's only
reachable after JS interaction, either move just the download assertion into a **request spec**
(`get download_path; expect(response.headers['Content-Disposition'])…`) or use Tier 2.

**Tier 2 — `@javascript` scenario (real Chrome, `js: true`).** Watch the browser's download directory. This
needs **three** pieces wired together (the first is the one people forget):

1. **Configure Chrome to download to a known directory without a prompt** — in the app's Selenium/Chrome
   driver registration (`spec/support/capybara.rb` or wherever the driver is built). *Without this the file
   never lands where the test looks.* This is what the reference apps do:
   ```ruby
   Selenium::WebDriver::Chrome::Options.new(
     # ...other args...
     prefs: { 'download.default_directory': DownloadHelpers.download_path.to_s },
   )
   # (equivalently: options.add_preference(:download, default_directory: DownloadHelpers.download_path.to_s))
   ```
2. **`DownloadHelpers`** — owns the directory, clears it between examples, and waits for the download to
   finish (Chrome writes a `*.crdownload` temp file while in progress).
3. **`have_downloaded_a_file`** matcher — reads cleanly at the call site:
   - after: `expect(page).to have_downloaded_a_file(/report\.pdf/)`

**Create the two support files below** (the target `spec/` won't have them). `last_download` here is the
robust, **polling** version (waits out `.crdownload`), per the makandra card:
```ruby
# spec/support/download_helpers.rb
module DownloadHelpers
  TIMEOUT = 10
  module_function

  def download_path
    path = Rails.root.join("tmp/test_downloads#{ENV['TEST_ENV_NUMBER']}")
    FileUtils.mkdir_p(path)
    path
  end

  def clear_downloads
    FileUtils.rm_rf(download_path)
  end

  # Waits until Chrome finishes writing (no more *.crdownload temp files),
  # then returns the most recently created file (or nil if none).
  def last_download
    downloads = Pathname.new(download_path)
    Timeout.timeout(TIMEOUT) do
      sleep 0.1 until downloads.glob('*.crdownload').empty?
    end
    downloads.children.max_by(&File.method(:ctime))
  end
end

RSpec.configure do |config|
  config.before(type: :feature) { DownloadHelpers.clear_downloads }
  config.after(type: :feature)  { DownloadHelpers.clear_downloads }
  config.include(DownloadHelpers, type: :feature)
end
```
```ruby
# spec/support/matchers/have_downloaded_a_file.rb
# `filename` may be a String or a Regexp.
RSpec::Matchers.define :have_downloaded_a_file do |filename|
  match do |_page|
    # `patiently` (see cross-cutting convention #1) retries until the file appears.
    patiently do
      basename = DownloadHelpers.last_download&.basename&.to_s
      expect(basename).to match(filename)
    end
  end

  failure_message do |_page|
    "expected a download matching #{filename.inspect} in #{DownloadHelpers.download_path}, " \
      "but found: #{Dir.children(DownloadHelpers.download_path).inspect}"
  end
end
```

**Notes / caveats** (from the makandra card):
- Tier 2 is **Chrome-specific** and **breaks when the browser runs in a different container than the test
  process** (common on CI / remote Selenium grids) — the file lands on the browser's filesystem, not where
  `DownloadHelpers` looks. On such setups prefer Tier 1, or assert the download via a request spec.
- The matcher depends on the `patiently` helper from cross-cutting convention #1 (so the file has time to
  appear); `last_download` separately waits out the in-progress `.crdownload` temp file.
- Used ≈47×. Many of those are plain server responses → Tier 1. Reach for Tier 2 only when the download is
  genuinely browser-driven.

**Fallback — if Tier 2 fails when you run the migrated spec.** Directory-watching is the part that churns: it
goes wrong with remote/containerised browsers (no shared filesystem), flakes on timing, or simply can't read
the file's *contents*. When that happens, switch to the **"okayest" download helper** from
[makandra card 512456](https://makandracards.com/makandra/512456-capybara-okayest-helper-download-inspect-files):
instead of watching the download folder, it finds the link and issues a **direct HTTP request to its `href`**,
returning the response for inspection — e.g.
```ruby
details = download_link('Download report')   # finds the link, fetches its href
expect(details[:filename]).to eq('report.pdf')
expect(details[:content_type]).to eq('application/pdf')
expect(details[:text]).to include('Total: 42')   # inspect the actual contents
```
Copy the `download_link` helper from that card into `spec/support/`. It works on **both** rack-test and
Selenium, needs **no** download directory or driver `prefs`, stays on the current page, and lets you assert
file **contents**. Its limitation: it only handles real server-rendered download links (`<a href>`, incl.
`download`/`download=filename` attributes / `send_file`) — it **can't** follow JS-triggered or cross-host
downloads, which still need Tier 2. So the practical order is: **Tier 1** (rack-test header) → **this helper**
(server-rendered link, any driver, content inspection) → **Tier 2** (genuinely browser-driven downloads).

### Window title

#### `window_titled`

**Step regexp** — `/^the window should be titled "([^"]*)"$/` (`web_steps.rb:521`)

**Intent** — Assert the page `<title>`.

**Mapping**
- before: `Then the window should be titled "Dashboard"`
- after: `expect(page).to have_title('Dashboard')`

### Browser dialogs (JS confirm/alert/prompt)

#### `confirm_dialog`

**Step regexp** — `/^I confirm the browser dialog$/` (`web_steps.rb:650`)

**Intent** — Accept a JS confirm/alert dialog.

**Mapping / trade-offs** — Capybara's dialog API is **synchronous around the action that triggers the dialog**,
which is the opposite of Spreewald's "click, then separately confirm" flow. So you must **merge** the
triggering step and the confirm step into one call:
- before:
  ```cucumber
  When I press "Delete"
  And I confirm the browser dialog
  ```
- after:
  ```ruby
  accept_confirm { click_on 'Delete' }
  ```
- If the dialog text is asserted: `accept_confirm('Delete “Example”?') { click_on 'Delete' }`

**Notes** — This is the single biggest structural difference in the whole guide: **the confirm/cancel step and
the immediately-preceding action step collapse into one `accept_confirm { … }` / `dismiss_confirm { … }`
block.** Seen throughout the reference RSpec apps.

#### `cancel_dialog`

**Step regexp** — `/^I cancel the browser dialog$/` (`web_steps.rb:656`)

**Intent** — Dismiss (cancel) a JS confirm dialog.

**Mapping**
- before:
  ```cucumber
  When I press "Delete"
  And I cancel the browser dialog
  ```
- after: `dismiss_confirm { click_on 'Delete' }`

**Notes** — Same merge-with-the-trigger rule as `confirm_dialog`.

#### `enter_into_dialog`

**Step regexp** — `/^I enter "([^"]*)" into the browser dialog$/` (`web_steps.rb:662`) — *(unused in the example
apps; included for completeness since it's the prompt-dialog sibling of the two above.)*

**Intent** — Type text into a JS `prompt()` and accept it.

**Mapping**
- after: `accept_prompt(with: 'my text') { click_on 'Rename' }`

### Scoping meta-step

#### `within`

**Step regexp** — `/^(.*) within (.*[^:])$/` (`web_steps.rb:47`) and the table variant `/^(.*) within (.*[^:]):$/`
(`web_steps.rb:61`)

**Intent** — A meta-step: run any other web step scoped to the first element matching a selector or selector
alias. Heavily used (≈9000×).

**Mapping** — depends on what the inner step does:

- **A scoped *content* assertion** (`I should see "X" within "Y"`) → **`have_css('Y', text: 'X')`**, *not* a `within` — this is the reference-app idiom (they use it hundreds of times and never `within(sel) { have_content }`), and it chains with `.and`:
  - before: `Then I should see "Edit" within ".sidebar"`
  - after: `expect(page).to have_css('.sidebar', text: 'Edit')`
- **Everything else** (interactions, field/checkbox assertions, custom matchers — anything that can't take a selector directly) → wrap the inner step's mapping in a `within(selector) do … end` block, **always the block form, never one-line braces**:
  - before: `When I fill in "Name" with "Alice" within ".user-form"`
  - after:
    ```ruby
    within('.user-form') do
      fill_in 'Name', with: 'Alice'
    end
    ```
  - before: `Then the checkbox "Active" should be checked within ".user-form"`
  - after:
    ```ruby
    within('.user-form') do
      expect(page).to have_checked_field('Active')
    end
    ```

**Notes / trade-offs**
- **Consecutive `see X within Y` steps that share the *same* `Y`** → don't emit a `have_css('Y', text:)` per line (repeating `Y`); scope `Y` once with `within('Y') do … end` and chain the inner checks (one `have_content` per matcher, `.and`-joined and multi-line — see *Mechanical formatting rules*; or `have_css('.sub', text:)` for sub-elements). Use the flat `have_css('Y', text: 'X')` only for a lone scoped check or when the selectors differ.
- The scope argument may be a literal CSS selector **or** a selector alias from `selectors.rb` (e.g.
  `within the modal`). Resolve aliases via convention #3 by reading the app's `features/support/selectors.rb`
  and inlining the resulting CSS — e.g. `within the modal` → `within('up-modal') do … end` (the exact modal
  selector is whatever that app's `selectors.rb` maps it to; common values are `'up-modal'`, `'.modal'`,
  `'dialog'`). Just use the CSS string in `within(...)`; no custom matcher is needed for scoping.
- `within` scopes to the **first** matching element (matching Spreewald). If the inner step is a `should not
  see` style negative, the `within` still scopes correctly.
- The table variant (`… within …:`) wraps a step that takes a doc-string/table argument — convert the inner
  step per its own rule, inside the `within` block.

### "inside any" variant

#### `should_see_inside_any`

**Step regexp** — `/^I should( not)? see "([^"]*)" inside any "([^"]*)"$/` (`web_steps.rb:630`)

**Intent** — Assert some element matching the selector contains the given text. Unlike `within` (which scopes
to the *first* match and would fail if the text is in a *later* match), this passes if **any** matching
element contains the text.

**Mapping**
- before: `Then I should see "Sale" inside any ".product"`
- after: `expect(page).to have_css('.product', text: 'Sale')`
- negated: `expect(page).to have_no_css('.product', text: 'Sale')`

**Notes** — `have_css(selector, text:)` succeeds if any matching element has the text, which is exactly the
"inside any" semantics. (The sibling steps `follow "..." inside any "..."` and `fill in "..." ... inside any
"..."` are unused in the example apps and omitted.)

### Debugging step (lives in `web_steps.rb`)

#### `show_me_the_page`

**Step regexp** — `/^show me the page$/` (`web_steps.rb:451`)

**Intent** — Debugging: open the current page in a browser (via `launchy` / `capybara_screenshot`). Not a
real assertion — should never be committed deliberately.

**Mapping**
- before: `Then show me the page`
- after: `save_and_open_page`  *(Capybara built-in; or `save_and_open_screenshot` on a real browser driver)*

**Notes** — Only 1 occurrence (left in by accident). Convert to `save_and_open_page`, but flag it to a human —
debugging steps usually shouldn't survive into the committed spec at all and can simply be dropped.

---

## `table_steps.rb`

#### `table_with_rows`

**Step regexp** — `/^I should( not)? see a table with (exactly )?the following rows( in any order)?:?$/`
(`table_steps.rb:123`)

**Intent** — Assert an HTML `<table>` contains the given rows. By default this is a **subset** match: the
expected rows must appear, **in order**, but the table may contain additional rows; within a cell, `*` is a
wildcard; cells are compared after whitespace normalisation; the assertion succeeds if **any** table on the
page matches. Modifiers: `exactly` (no extra rows) and `in any order` (rows unordered). Used heavily (≈1378×).

**Mapping** — Use the `have_table_with_rows` matcher below, which **mirrors Spreewald's semantics** so the
conversion is faithful and not brittle — you can carry the Cucumber table's cell data over **unchanged**.
**Add the support file to the target app** (its `spec/` is empty). Map the modifiers to chained methods and copy
any `*` wildcards verbatim:

> **Named `have_table_with_rows`, not the reference apps' `have_table_with_contents`** — because it's deliberately
> laxer (extra rows *and* columns tolerated as a subsequence, like Spreewald, so Cucumber table data migrates
> unchanged). Use it as-is; don't rename it to `have_table_with_contents`.

| Spreewald step | RSpec |
| --- | --- |
| `a table with the following rows:` (default = subset, in order) | `have_table_with_rows(*rows)` |
| `a table with exactly the following rows:` | `have_table_with_rows(*rows).exactly` |
| `a table with the following rows in any order:` | `have_table_with_rows(*rows).in_any_order` |

> **A modifier-carrying `have_table_with_rows` must be its own `expect` — never inside an `.and` chain.** `expect(page).to have_content('X').and have_table_with_rows(...).exactly` parses as `…and(have_table_with_rows(...)).exactly`, so `.exactly` attaches to the **compound** matcher and the row-count constraint is **silently lost** (the spec passes, laxer). Same for `.in_any_order`. Give any `.exactly`/`.in_any_order` call its own statement.
| `a table with exactly the following rows in any order:` | `have_table_with_rows(*rows).exactly.in_any_order` |

> **Visible-only by default.** The matcher asserts only tables the *user can see*. If a scenario genuinely needs to check a table the app renders but hides (an inactive tab pane, `ng-show`), pass `have_table_with_rows(*rows, visible: :all)` — the rare case; don't make it the default. (This deliberately diverges from Spreewald, which parsed the raw `page.body` and matched hidden tables — but an E2E assertion should look at what the user sees.)

- before:
  ```cucumber
  Then I should see a table with the following rows:
    | Name  | Role  |
    | Alice | Admin |
    | Bob   | User  |
  ```
- after (subset, in order — the default; tolerates other rows in the table, so it is **not brittle**):
  ```ruby
  expect(page).to have_table_with_rows(
    ['Name', 'Role'],
    ['Alice', 'Admin'],
    ['Bob', 'User'],
  )
  ```

**Notes / trade-offs**
- **Default is subset matching** — you do **not** have to list every rendered row, exactly like the Spreewald
  default. Add `.exactly` only when the cucumber step said `exactly`.
- **Wildcards.** A `*` inside a cell is an intra-cell wildcard (e.g. `['Alice', 'Admin *']`). Copy it across
  verbatim; the matcher translates it to a regexp. A whole-Regexp cell (`['Alice', /Admin/]`) also works.
- **Extra columns are tolerated by default (subsequence match).** You only list the columns you care about;
  if the table renders extra columns the scenario didn't mention (e.g. a "Created at" / "Status"
  column), the row still matches — because Spreewald's `find_row` matches expected cells as a subsequence of
  the actual cells, not by equal column count. (This is why there is no `.allowing_extra_columns` modifier: the
  default already allows them. `.exactly` constrains only the number of *rows*.)
- **Header row.** Spreewald collects `<th>` and `<td>`, so the header row is part of the table contents — keep
  the header row in the expected rows just as the cucumber table had it.
- **Multiple tables.** The matcher scans **every** `<table>` on the page and passes if any one matches (like
  Spreewald). Scope with a `within('#some-table') do … end` block around `expect(page).to have_table_with_rows(...)` for a
  specific table.
- **Negation** (`should not see a table with …`) → `expect(page).not_to have_table_with_rows(...)`.

**Support file — create this matcher in the target app** (`spec/support/matchers/have_table_with_rows.rb`).
Self-contained (no app-level `HtmlToText` dependency); registers globally, so no `config.include` is needed:
```ruby
# spec/support/matchers/have_table_with_rows.rb
#
# Asserts that an HTML <table> on the page contains the given rows. Mirrors the
# semantics of Spreewald's "I should see a table with ... the following rows" step:
#
#   * SUBSET match by default: expected rows must appear in order; extra rows are OK.
#   * .exactly        -> the table must contain exactly these ROWS (no extra rows).
#   * .in_any_order   -> expected rows may appear in any order.
#
# COLUMNS are always matched as a SUBSEQUENCE (this is what Spreewald's `find_row` does):
# each expected cell matches the next actual cell in order, and extra/interspersed columns
# anywhere in the row are tolerated. So a table that renders an extra "Status" column the
# scenario didn't list still matches. `.exactly` constrains only the number of rows, never
# the number of columns.
#
# A cell may be a String (whitespace-normalized equality; "*" is a wildcard) or a Regexp.
# Succeeds if ANY <table> on the page matches.
RSpec::Matchers.define :have_table_with_rows do |*expected_rows, visible: true|
  chain(:exactly)      { @exactly = true }
  chain(:in_any_order) { @in_any_order = true }

  # NB: these are `define_method` instance methods, NOT lambdas. The comparison must read the
  # per-instance `@exactly` / `@in_any_order` that the `chain(...)` blocks set — lambdas defined
  # in the matcher body don't reliably resolve those against the matcher instance, so `.exactly`
  # / `.in_any_order` would silently become no-ops. (The reference apps' matchers use
  # `define_method` for the same reason.)
  define_method :normalize do |value|
    value.to_s.gsub(/[[:space:]]+/, ' ').strip
  end

  define_method :cell_matches? do |actual, expected|
    case expected
    when Regexp
      actual.match?(expected)
    else
      expected = normalize(expected)
      if expected.include?('*')
        # Split on /\s*\*\s*/, not a bare '*', so whitespace adjacent to the wildcard is absorbed
        # (matches Spreewald's TableStepsHelper#find_row): `up to* €50` then matches a cell rendered `up to€50`.
        pattern = expected.split(/\s*\*\s*/, -1).map { |part| Regexp.escape(part) }.join('.*')
        actual.match?(/\A#{pattern}\z/)
      else
        actual == expected
      end
    end
  end

  # Subsequence column match (mirrors Spreewald's find_row): consume the actual cells left to
  # right, matching each expected cell against the next remaining actual cell. Extra columns
  # anywhere are tolerated; column count is never required to be equal.
  define_method :row_matches? do |actual_row, expected_row|
    remaining = actual_row.dup
    expected_row.all? do |expected_cell|
      index = remaining.find_index { |actual_cell| cell_matches?(actual_cell, expected_cell) }
      if index
        remaining = remaining[(index + 1)..] || []
        true
      else
        false
      end
    end
  end

  # Does one table (an array of rows) contain the expected rows, per the active modifiers?
  define_method :table_matches? do |actual_rows|
    if @in_any_order
      pool = actual_rows.dup
      matched = expected_rows.all? do |expected_row|
        index = pool.find_index { |actual_row| row_matches?(actual_row, expected_row) }
        index && pool.delete_at(index)
      end
      @exactly ? (matched && pool.empty?) : matched
    elsif @exactly
      actual_rows.size == expected_rows.size &&
        actual_rows.zip(expected_rows).all? { |actual_row, expected_row| row_matches?(actual_row, expected_row) }
    else
      # subset, in order
      pool = actual_rows.dup
      expected_rows.all? do |expected_row|
        index = pool.find_index { |actual_row| row_matches?(actual_row, expected_row) }
        if index
          pool = pool[(index + 1)..] || []
          true
        end
      end
    end
  end

  define_method :tables_on_page do |page|
    # `self::table | .//table`, not a plain 'table': inside `within('table.x') { … }` a bare
    # `all('table')` searches only DESCENDANT tables and finds none, silently ignoring the scope.
    # (Spreewald read the whole page.body and ignored a surrounding `within` — that was a Spreewald
    # bug; our matcher respects the scope by also considering the scope element when it is a table.)
    page.all(:xpath, './/table | self::table', wait: false, minimum: 0, visible: visible).filter_map do |table|
      # Selenium exposes the markup via the outerHTML property; only the rack-test (Nokogiri)
      # native node responds to #to_html. Under a polling re-render outerHTML can momentarily read
      # nil / the element goes stale — skip it so the enclosing patiently_wait_until retries rather
      # than calling #to_html on a Selenium::WebDriver::Element (which would raise NoMethodError).
      html = table['outerHTML']
      html ||= table.native.to_html if table.native.respond_to?(:to_html)
      next unless html

      Nokogiri::HTML.fragment(html).css('tr').map do |tr|
        tr.css('th, td').map do |cell|
          cell.text.gsub(/[[:space:]]+/, ' ').strip.presence || cell.at('[title]')&.[]('title') || ''
        end
      end
    end
  rescue Selenium::WebDriver::Error::StaleElementReferenceError
    # a table re-rendered mid-read (e.g. polling) — treat as no readable tables yet; patiently retries
    []
  end

  # Retries internally (like a Capybara matcher) so a table that fills in after an async
  # refresh still matches — no need to wrap the call site in `patiently`.
  match do |page|
    patiently_wait_until do
      @tables = tables_on_page(page)
      @tables.any? { |actual_rows| table_matches?(actual_rows) }
    end
  end

  match_when_negated do |page|
    patiently_wait_until do
      @tables = tables_on_page(page)
      @tables.none? { |actual_rows| table_matches?(actual_rows) }
    end
  end

  failure_message do |_page|
    "expected some table on the page to contain rows (exactly=#{!!@exactly}, in_any_order=#{!!@in_any_order}):\n" \
      "#{expected_rows.pretty_inspect}\nTables found:\n#{@tables.pretty_inspect}"
  end

  failure_message_when_negated do |_page|
    "expected no table on the page to contain rows:\n#{expected_rows.pretty_inspect}\nbut one did"
  end
end
```

---

## `email_steps.rb`

> **Setup prerequisite.** Spreewald clears `ActionMailer::Base.deliveries` before every scenario via a global
> `Before` hook. RSpec does **not** clear deliveries automatically, so the target app needs a global
> `config.before { ActionMailer::Base.deliveries.clear }` — a single global `before` is the faithful port
> of Spreewald's global hook. Ensure that hook exists; otherwise email assertions
> leak across examples. Email assertions go straight against `ActionMailer::Base.deliveries` (no Capybara).

#### `clear_emails`

**Step regexp** — `/^I clear my e?mails$/` (`email_steps.rb:11`)

**Intent** — Reset the sent-mail collection mid-scenario.

**Mapping**
- before: `When I clear my emails`
- after: `ActionMailer::Base.deliveries.clear`

#### `no_email_sent`

**Step regexp** — `/^no e?mail should have been sent$/` (`email_steps.rb:81`)

**Intent** — Assert nothing was sent.

**Mapping**
- before: `Then no email should have been sent`
- after: `expect(ActionMailer::Base.deliveries).to be_empty`

#### `should_see_in_email`

**Step regexp** — `/^I should see "([^"]*)" in the( HTML| plain-text|) e?mail$/` (`email_steps.rb:86`)

**Intent** — Assert the **last** sent email's body (HTML or plain-text part, or default) includes the text.

**Mapping** — Use the `last_mail` / `mail_text` helpers from the shared `MailHelpers` support file (defined
under [`follow_link_in_email`](#follow_link_in_email) below):
- before: `Then I should see "Your order shipped" in the email`
- after: `expect(mail_text(last_mail)).to include('Your order shipped')`
- HTML/plain-text specific part:
  ```ruby
  expect(last_mail.html_part.body.decoded).to include('Your order shipped')   # "HTML email"
  expect(last_mail.text_part.body.decoded).to include('Your order shipped')   # "plain-text email"
  ```

**Notes** — Spreewald strips tags from the chosen body part before matching, which is exactly what `mail_text`
does (it returns the parsed visible text). **But check for an app override first:** if the app defines its own `the … email should …` step, port **its** body-normalization, not the guide's default — some apps read the **plain-text** part (not HTML), collapse runs of blank lines, and rewrite every `http(s)://…` URL to a literal `<URL>`, so the `.feature` doc-strings carry `( <URL> )` placeholders the guide's matcher can never match (see *Watch for app overrides of predefined steps* in `conversion-guide.md`). Such doc-strings often also carry **trailing whitespace that is semantically required** — reproduce it in a heredoc with `#{' '}` at line end, or `Layout/TrailingWhitespace` will fail the lint. For a raw-source check read the part —
`(last_mail.html_part || last_mail).body.decoded` — since plain `last_mail.body.decoded` is **empty for
`multipart/alternative` mail** (e.g. premailer-rails). `mail_text` belongs in the shared **`MailHelpers` support file** defined under
[`follow_link_in_email`](#follow_link_in_email) below — make sure that method is present:
```ruby
def mail_text(mail = last_mail)
  # multipart/alternative mail (e.g. premailer-rails) keeps the body in html_part; mail.body.decoded is then empty
  body = (mail.html_part || mail).body.decoded
  Nokogiri::HTML(body).at('body').text.strip.gsub("\r\n", "\n").gsub(/\n{3,}/, "\n\n")
end
```
Then: `expect(mail_text(mail)).to include('...')`.

#### `email_sent_with`

**Step regexp** — `/^(an?|no)( HTML| plain-text|) e?mail should have been sent with:$/` (`email_steps.rb:38`)

**Intent** — Assert (or, with `no`, refute) that an email matching a header+body description was sent. The
doc-string is a mini-DSL: `From:`/`To:`/`CC:`/`BCC:`/`Reply-To:`/`Subject:`/`Attachments:` header lines, a
blank line, then body text with `*` wildcards. On a positive match the found mail is remembered as `@mail`
(used by `follow_link_in_email`).

**Mapping** — Spreewald *searches* `ActionMailer::Base.deliveries` (MailFinder), so the faithful port is a
collection assertion. Use whichever fits (add the support file below):
- **`have_mail(...)`** — the finder, and the default: asserts the mailbox holds a mail matching the given
  attributes (`expect(ActionMailer::Base.deliveries).to have_mail(to:, subject:, text:)`). This mirrors
  Spreewald's search. Pass only the attributes the docstring pins down — all are optional.
- **`have_mail_attributes(...)`** on a *specific* mail you already hold — `deliveries.last`, or the `@mail`
  you captured for a later "follow the link in the email" step — same criteria, one mail.
- **direct field assertions** when you only care about a field or two.
- before:
  ```cucumber
  Then an email should have been sent with:
    """
    To: john@example.com
    Subject: Welcome
    Thanks for signing up *
    """
  ```
- after (direct field assertions — shortest when only a field or two matters):
  ```ruby
  mail = ActionMailer::Base.deliveries.find do |m|
    m.to == ['john@example.com'] && m.subject.include?('Welcome') # substring, like Spreewald's MailFinder
  end
  expect(mail).to be_present
  expect((mail.html_part || mail).body.decoded).to match(/Thanks for signing up.*/m) # html_part: multipart body.decoded is empty
  @mail = mail # only if a later "follow the link in the email" step depends on it
  ```
- after (matcher — the finder; mirrors Spreewald's search of `deliveries`; `*` is a body wildcard):
  ```ruby
  expect(ActionMailer::Base.deliveries).to have_mail(
    to: ['john@example.com'],
    subject: 'Welcome',
    text: 'Thanks for signing up *',
  )
  ```
- `no … email should have been sent with:` → assert no delivery matches. **Don't reach for
  `none(have_attributes(…))`** — `none` is an rspec-collection-matchers matcher, and many apps don't load
  that gem (`NoMethodError: undefined method 'none'`). Filter and assert empty instead — portable, no extra
  gem:
  ```ruby
  matching = ActionMailer::Base.deliveries.select do |mail|
    mail.to == ['john@example.com'] && mail.subject == 'Welcome'
  end
  expect(matching).to be_empty
  ```

**Notes / trade-offs**
- **Wildcards.** `*` mid-line → `.*` in a Regexp; a line containing only `*` → skip/omit lines (use `/m` and
  `.*`). Translate the body to a Regexp accordingly.
- **Multi-line `text:` — join *every* body line with `*`; don't collapse the body or paste a verbatim block.**
  `have_mail_attributes`' `text:` matches the decoded body after HTML→text normalization, but a mailer that
  renders each line as its own `<p>` (very common) **blank-separates** the lines (`\n\n`), so a verbatim
  multi-line block fails even though every line is present and in order. So anchor **each content line the
  docstring asserted, in order**, joined by the `*` wildcard (→ `.*` across newlines), replacing only the
  dynamic bits (tokens, generated URLs) with `*`:
  `text: 'Hello Bruce *Someone has requested a link *http://…/edit?token=*Please ignore *'`.
  The `*` is for spanning blank-separators and dynamic substrings — **not** for dropping lines you would
  otherwise assert. Collapsing the body to a couple of anchors silently loses coverage versus the Cucumber original.
- **Header-only docstrings — don't assert a body the origin never checked.** Spreewald's `MailFinder` splits
  the docstring on the **first blank line** (`raw_data.split(/\n\n/, 2)`). If there's **no** blank line between
  the header block and the body (and a `^[A-Za-z-]+: ` header line is present), the origin matched **headers
  only** — the visible body text was never asserted. Translate **only the headers**; don't turn that body into a
  `text:` assertion — doing so makes the spec *stricter* than the origin and it typically fails on years-stale
  content. (A docstring *with* a blank line, or one with no header lines at all, does assert a body — translate it.)
- **Single-part mail with no `<html>` tag → Spreewald compares the *raw source*.** For such a mail its
  `MailToPlaintextConverter` does no HTML→text conversion, so expected bodies legitimately contain markup
  (`<p>`, `<a href>`). `have_mail_attributes`' own normalization differs — port Spreewald's converter (or match
  the raw source) for these, since the two disagree exactly where it matters.
- **Headers.** Map `To/CC/BCC/Reply-To/From/Subject/Attachments` to `mail.to`, `mail.cc`, `mail.bcc`,
  `mail.reply_to`, `mail.from`, `mail.subject`, and `mail.attachments.map(&:filename)`. Recipients are arrays.
- **Unknown header keys are silently ignored — verify every docstring key is one the finder understands.** `MailFinder` only recognises `From/To/CC/BCC/Reply-To/Subject/Attachments`; any other `Key: value` line (a localized `Betreff:`/`Von:`, or a typo) is **dropped** rather than rejected, so that condition matches *any* mail and the step quietly asserts less than it looks. Before porting, check each header line maps to one of the fields above.
- **Subject is a substring match.** Spreewald's `MailFinder` matches the subject with `mail.subject.include?(...)`,
  not equality — because the test environment often **prefixes** subjects (e.g. `"[test] Confirm your email"`).
  Assert with `include` (the `have_mail_attributes` matcher already does); only use `eq` if a scenario truly pins
  the exact subject.
- **`have_mail_attributes`** asserts `subject` + `to` (+ optional `from`) and the decoded body `text`. The
  version below supports Spreewald's `*` body wildcards (and a `Regexp` `text:`), so it handles partial bodies
  too — `text: '*'` means "any body". Reach for it when it's shorter than spelling the fields out by hand.
- This is one of the higher-effort conversions (≈178×). Keep `@mail = …` only when a subsequent
  `follow the link in the email` step references it; otherwise drop it.

**Support file — create this matcher in the target app** (`spec/support/matchers/have_mail_attributes.rb`).
It's a custom matcher (registers globally), so no `config.include` is needed:
```ruby
# spec/support/matchers/have_mail_attributes.rb
#
# `text:` may be:
#   - a String for an exact body match, or
#   - a String containing "*" wildcards (mirrors Spreewald's body DSL; "*" -> ".*",
#     so text: "*" matches any body), or
#   - a Regexp matched directly against the body.
RSpec::Matchers.define :have_mail_attributes do |to: nil, subject: nil, text: nil, from: nil|
  match do |mail|
    body_html = (mail.html_part || mail).body.decoded # multipart/alternative: mail.body.decoded is empty
    cleaned_body_html = body_html
      .gsub("\r\n", "\n")
      .gsub(/\s+</, ' <')
      .gsub(/>\s+/, '> ')
      .gsub(/(<\/p>|<\/table>|<\/h\d>)/, "\\1\n\n")
      .gsub(/(<br>|<br\s*\/>|<\/div>|<\/tr>)/, "\\1\n")

    @body_text = Nokogiri::HTML(cleaned_body_html)
      .content
      .gsub(/^ +| +$/, '')
      .gsub(/\n{3,}/, "\n\n")
      .strip

    # Return a boolean — do NOT use expect() inside a match block. A raising match can't be negated
    # (`not_to have_mail_attributes`) and bypasses the failure_message below (you'd get the inner
    # expectation's message instead). Compute each check as a boolean and AND them.
    from_ok = from ? mail.header['From'].value == from : true
    # Substring match, like Spreewald's MailFinder (`mail.subject.include?(...)`): the test env often
    # prefixes subjects (e.g. "[test] Confirm your email address"), which an `eq` match would reject.
    subject_ok = subject ? mail.subject.include?(subject) : true
    to_ok = to ? mail.to.to_a.sort == Array(to).sort : true

    body_ok =
      case text
      when nil
        true                                   # no body criterion given → don't constrain the body
      when Regexp
        @body_text.match?(text)
      else
        if text.include?('*')
          pattern = text.strip.split('*', -1).map { |part| Regexp.escape(part) }.join('.*')
          @body_text.match?(/\A#{pattern}\z/m)
        else
          @body_text == text.strip
        end
      end

    from_ok && subject_ok && to_ok && body_ok
  end

  failure_message do |mail|
    <<~MESSAGE
      Failed to match against this email:

      Subject: #{mail.subject}
      To: #{mail.to}
      Text:

      #{@body_text}
    MESSAGE
  end
end

# Collection finder: does the mailbox hold a mail matching these attributes? This is the faithful port of
# Spreewald's `email_sent_with` (which *searches* deliveries), and it reuses have_mail_attributes so the body
# wildcard / subject-substring logic lives in one place. Pass only the attributes you care about.
RSpec::Matchers.define :have_mail do |**criteria|
  match { |deliveries| Array(deliveries).any? { |mail| have_mail_attributes(**criteria).matches?(mail) } }

  failure_message do |deliveries|
    listing = Array(deliveries).map { |m| "  - to: #{m.to.inspect}  subject: #{m.subject.inspect}" }
    "expected a delivered mail matching #{criteria.inspect}, but the mailbox held:\n" +
      (listing.empty? ? '  (no mail delivered)' : listing.join("\n"))
  end
end

RSpec::Matchers.define_negated_matcher :have_no_mail, :have_mail
```

#### `follow_link_in_email`

**Step regexp** — `/^I follow the (first|second|third)? ?link in the e?mail$/` (`email_steps.rb:76`)

**Intent** — Extract an HTTP(S) link from the relevant email (the `@mail` matched by a preceding
`email should have been sent with`, else the last delivery) and `visit` it.

**Mapping** — Inline it for a one-off, or **add the support file below** if mail-link following recurs
(recommended — it reads much better and visits the *path* to avoid host/port mismatches in tests):
- before: `When I follow the link in the email`
- after (inline, one-off):
  ```ruby
  mail = ActionMailer::Base.deliveries.last
  link = Nokogiri::HTML((mail.html_part || mail).body.decoded).css('a[href]')
    .map { |a| a['href'] }.find { |href| href.start_with?('http') }
  visit link
  ```
- after (with the helper below): `visit mail_link_paths.first`
- "first/second/third" → index into the collected links (`.first`, `[1]`, `[2]`).

**Support file — create in the target app** (`spec/support/mail_helpers.rb`). This is the shared mail helper
module for feature specs; the `mail_text` method from [`should_see_in_email`](#should_see_in_email) lives here
too:
```ruby
# spec/support/mail_helpers.rb
module MailHelpers
  # http(s) links only (Spreewald skips mailto:/ftp:); group 1 is the host-stripped path.
  MAIL_URL_PATTERN = %r{https?://[^/]+([^"'\s]+)}

  def last_mail
    ActionMailer::Base.deliveries.last
  end

  # Visible text of a mail body (prefers the HTML part; see the should_see_in_email rule).
  def mail_text(mail = last_mail)
    body = (mail.html_part || mail).body.decoded
    Nokogiri::HTML(body).at('body')&.text.to_s.strip.gsub("\r\n", "\n").gsub(/\n{3,}/, "\n\n")
  end

  # Full http(s) link URLs in the mail. Mirrors Spreewald's FollowTheLink, which handles BOTH
  # message types: parse <a href> for HTML mails, and *scan the body text* for plain-text mails
  # (which have no anchors at all — a password-reset mail is often plain text).
  def mail_links(mail = last_mail)
    if mail.html_part || mail_html?(mail)
      body = (mail.html_part || mail).body.decoded
      Nokogiri::HTML(body).css('a[href]').map { |a| a['href'] }.select { |href| href.start_with?('http') }
    else
      (mail.text_part || mail).body.decoded.scan(%r{https?://\S+})
    end
  end

  # Host-stripped paths, so `visit` hits the test server rather than the mailer's host/port.
  def mail_link_paths(mail = last_mail)
    mail_links(mail).filter_map { |href| href[MAIL_URL_PATTERN, 1] }
  end

  private

  def mail_html?(mail)
    mail.content_type.to_s.include?('html') || mail.body.decoded.include?('<a ')
  end
end

RSpec.configure { |config| config.include(MailHelpers, type: :feature) }
```

**Notes** — Spreewald only follows `http(s)` links (skips `mailto:`/`ftp:`). Crucially, it handles **both HTML
and plain-text** mails: HTML via `a[href]`, plain text via a URL scan of the body (`FollowTheLink` uses
`%r{(?:https?://[^/]+)([^"'\s]+)}`) — so a plain-text password-reset mail (no `<a>` tags) still yields a link.
The helper above reproduces both branches and returns the **host-stripped path** so `visit` targets the test
server, not the mailer's configured host/port. Spreewald uses the email matched by a preceding `email should
have been sent with` (`@mail`) if present, else the last delivery — pass that mail into `mail_links(mail)` when
it matters. (The inline one-off above only parses HTML; prefer the helper whenever a plain-text mail is possible.)

---

## `browser_tab_steps.rb`

> These steps are **Selenium/JS only** and manage multiple browser windows ("tabs"). Capybara's raw window API
> (`switch_to_window(windows.last)`, `current_window.close`, …) is low-level and obscures intent, and the
> Cucumber apps use tabs *statefully* (open → switch → act → close → continue in the original). So **add the
> `BrowserTabHelpers` module below** (inlined at the end of this section) and map the stateful steps to its
> readable helpers (`switch_to_new_browser_tab`, `close_browser_tab`, …). The "may open / should have opened"
> counter pattern collapses into an `expect { … }.to change` assertion instead.
>
> *(When a scenario opens a tab, does something, and is done — a self-contained interaction — the modern idiom
> `within_window(window_opened_by { … }) { … }` is cleaner than switching statefully. Prefer it there; use the
> helpers for the stateful open→…→close flows the Cucumber apps actually use.)*
>
> **Don't port Spreewald's tab-closing `After` hook.** `browser_tab_steps.rb` closes extra tabs after each scenario, which *looks* like support you must migrate — but it's a **no-op in RSpec**: Capybara's Chrome driver specialization overrides `reset!` to `switch_to_window(window_handles.first)` and close the rest, and that runs after every example. Skip the hook (verify the equivalent for a non-Chrome driver if the app uses one).

#### `may_open_new_tab + should_have_opened_tab`

**Step regexps** — `/^I may open a new browser tab$/` (`browser_tab_steps.rb:57`) and
`/^I should( not)? have opened a new browser tab$/` (`browser_tab_steps.rb:72`)

**Intent** — Paired: the first records the current tab count; the second asserts a new tab was (not) opened by
the action in between.

**Mapping** — Collapse the pair (and the action between them) into one `change`-matcher assertion:
- before:
  ```cucumber
  When I may open a new browser tab
  And I follow "Open in new tab"
  Then I should have opened a new browser tab
  ```
- after:
  ```ruby
  expect { click_on 'Open in new tab' }.to change { page.windows.size }.by(1)
  ```
- negated (`should not have opened`):
  ```ruby
  expect { click_on 'Open in same tab' }.not_to change { page.windows.size }
  ```

**Notes** — `may_open_new_tab` has no standalone translation; it only exists to snapshot the count. Discard it
and wrap the triggering action in the `expect { }` block.

#### `switch_to_new_tab`

**Step regexp** — `/^I switch to the new(?:ly opened)? browser tab$/` (`browser_tab_steps.rb:42`)

**Intent** — Wait for a second tab and switch the Capybara context to the most recently opened one.

**Mapping**
- before: `When I switch to the new browser tab`
- after: `switch_to_new_browser_tab`

#### `switch_to_previous_tab`

**Step regexp** — `/^I switch(?: back)? to the previous browser tab$/` (`browser_tab_steps.rb:49`)

**Intent** — Switch back to the second-to-last tab.

**Mapping**
- before: `When I switch back to the previous browser tab`
- after: `switch_to_previous_browser_tab`

#### `open_in_new_tab`

**Step regexp** — `/^I open (.+?) in a new browser tab$/` (`browser_tab_steps.rb:17`)

**Intent** — Open a page (by English page name) in a new tab via `window.open` and switch to it.

**Mapping**
- before: `When I open the dashboard in a new browser tab`
- after: `open_in_new_browser_tab(dashboard_path)`

**Notes** — Resolve the page name via `paths.rb` (convention #2) and pass the resulting route helper/path to
`open_in_new_browser_tab`.

#### `close_tab`

**Step regexp** — `/^I close the browser tab$/` (`browser_tab_steps.rb:28`)

**Intent** — Close the current tab and switch back to the first.

**Mapping**
- before: `When I close the browser tab`
- after: `close_browser_tab`

**Support file — create in the target app** (`spec/support/browser_tab_helpers.rb`), used by the four stateful
tab rules above:
```ruby
# spec/support/browser_tab_helpers.rb
module BrowserTabHelpers
  # Switch Capybara to the most recently opened tab.
  def switch_to_new_browser_tab
    switch_to_window(windows.last)
  end

  # Switch back to the previous (second-to-last) tab.
  def switch_to_previous_browser_tab
    switch_to_window(windows[-2] || windows.first)
  end

  # Open a path in a new tab and switch to it.
  def open_in_new_browser_tab(path)
    new_window = window_opened_by { execute_script("window.open(#{path.to_json}, '_blank')") }
    switch_to_window(new_window)
  end

  # Close the current tab and return to the first one.
  def close_browser_tab
    current_window.close
    switch_to_window(windows.first)
  end
end

RSpec.configure { |config| config.include(BrowserTabHelpers, type: :feature) }
```

#### `n_browser_tabs`

**Step regexp** — `/^there should be (\d+) browser tabs?$/` (`browser_tab_steps.rb:79`)

**Intent** — Assert the number of open tabs.

**Mapping**
- before: `Then there should be 2 browser tabs`
- after: `expect(page.windows.size).to eq(2)`

**Notes** — A newly-opened tab may not register immediately, and **capybara-lockstep does not help here**
— it synchronises AJAX/navigation within the current document, not the load of a separate window. So
prefer a **waiting** form: `expect { ... }.to change { page.windows.size }.to(2)`, or wrap the assertion
in `eventually`/`patiently`. (The sibling `there should be at least N browser tabs` is unused in the
example apps; it would map to `expect(page.windows.size).to be >= N`.)

---

## `session_steps.rb`

#### `in_browser_session`

**Step regexp** — `/^(.*) in the browser session "([^"]+)"$/` (`session_steps.rb:7`)

**Intent** — A meta-step: run any other step inside a separate, named Capybara session (a distinct browser
with its own cookies/login) — e.g. to test two users interacting.

**Mapping** — Wrap the inner step's mapping in `Capybara.using_session`:
- before: `When I press "Accept" in the browser session "second user"`
- after:
  ```ruby
  Capybara.using_session('second user') do
    click_on 'Accept'
  end
  ```

**Notes** — Each distinct session name is an isolated browser. Authentication/visits performed inside the
block apply only to that session. The default (unnamed) session is whatever you use outside such blocks.
Convert the inner step per its own rule. (The table/doc-string variant `… in the browser session "…":` is
unused in the example apps.)

---

## `time_steps.rb`

> Time-travel steps. Spreewald stubs `Time.now`/`Time.current` and auto-resets after each scenario.
>
> **First, pick the time-travel API based on what the app already uses — don't wire up both:**
> - **If the app already depends on `timecop`** (check the `Gemfile`), use **Timecop** (`Timecop.freeze` /
>   `Timecop.travel`) and add `config.after(type: :feature) { Timecop.return }` so the clock resets after each
>   example. In this case **do *not* also include `ActiveSupport::Testing::TimeHelpers`** — two time-travel
>   mechanisms fighting over the clock is a source of bugs.
> - **Otherwise**, use the ActiveSupport `travel_to` / `travel` / `freeze_time` API — its names match
>   Spreewald's intent and it auto-resets after each example. It comes from
>   `ActiveSupport::Testing::TimeHelpers`, not mixed into feature specs by default, so include it.
>
> **Second, parse the time string the way Spreewald does — this matters.** Spreewald does **not** always use
> `Time.zone.parse`. Its `parse_time` (`time_steps.rb`) uses `Time.zone.parse` only when `use_timezones?` is
> true, and falls back to `Time.parse` (system-local) when `ActiveRecord::Base.default_timezone == :local`. An
> app that sets `config.active_record.default_timezone = :local` (with `Time.zone = 'UTC'`) will render an hour
> **off** if you force `Time.zone.parse`. So branch exactly like Spreewald — easiest via a small helper you
> reuse in every time mapping below:
> ```ruby
> # spec/support/time_helpers.rb
> module TimeTravelHelpers
>   # Mirrors Spreewald's parse_time / use_timezones? (time_steps.rb).
>   def parse_time(string)
>     ar_local = defined?(ActiveRecord::Base) && active_record_default_timezone == :local
>     (!ar_local && Time.zone) ? Time.zone.parse(string) : Time.parse(string)
>   end
>
>   def active_record_default_timezone
>     ActiveRecord.respond_to?(:default_timezone) ? ActiveRecord.default_timezone : ActiveRecord::Base.default_timezone
>   end
> end
>
> RSpec.configure do |config|
>   config.include(TimeTravelHelpers, type: :feature)
>   # Only when the app does NOT use Timecop:
>   config.include(ActiveSupport::Testing::TimeHelpers, type: :feature)
> end
> ```
> The mappings below call `parse_time('…')`; pair it with `travel_to` (ActiveSupport) or `Timecop.freeze` /
> `Timecop.travel` (Timecop) depending on the API you picked above.

#### `date_or_time_is`

**Step regexp** — `/^the (?:date|time) is "?(\d{4}-\d{2}-\d{2}(?: \d{1,2}:\d{2})?)"?$/` (`time_steps.rb:78`)

**Intent** — Freeze/travel to an absolute date (optionally with time).

**Mapping**
- before: `Given the date is "2012-02-10"`
- after: `travel_to(parse_time('2012-02-10'))`
- before: `Given the time is "2012-02-10 13:40"`
- after: `travel_to(parse_time('2012-02-10 13:40'))`

**Notes** — `parse_time` (above) picks `Time.zone.parse` vs `Time.parse` exactly like Spreewald's
`use_timezones?` branch, so an app with `default_timezone == :local` doesn't end up an hour off. Timecop
equivalent: `Timecop.travel(parse_time('…'))` (running clock) or `Timecop.freeze(parse_time('…'))` (frozen).

#### `time_is`

**Step regexp** — `/^the time is "?(\d{1,2}:\d{2})"?$/` (`time_steps.rb:85`)

**Intent** — Travel to a time **today** (date defaults to today).

**Mapping**
- before: `Given the time is "13:40"`
- after: `travel_to(parse_time('13:40'))`

**Notes** — `parse_time('13:40')` resolves to today at 13:40 (in the app's effective zone), matching Spreewald.

#### `it_is_later_earlier`

**Step regexp** — `/^it is (\d+|an?|some|a few) (seconds?|minutes?|hours?|days?|weeks?|months?|years?) (later|earlier)$/`
(`time_steps.rb:93`)

**Intent** — Travel by a relative duration (forward for "later", backward for "earlier"). Word amounts:
`a`/`an` = 1, `some`/`a few` = 10.

**Mapping**
- before: `When it is 10 minutes later`
- after: `travel(10.minutes)`
- before: `When it is a few hours earlier`
- after: `travel(-10.hours)`
- before: `When it is an hour later`
- after: `travel(1.hour)`

**Notes** — `travel(duration)` shifts relative to the *current* (possibly already-travelled) time, matching
Spreewald. Map the fuzzy amounts exactly: `a`/`an` → 1, `some`/`a few` → 10; negate the duration for
"earlier". Timecop equivalent: `Timecop.travel(duration.from_now)` or `Timecop.freeze(Time.current + duration)`.

---

## `development_steps.rb`

> Debugging / scaffolding steps. Like `show me the page` (in `web_steps.rb`), these should rarely appear in
> committed `.feature` files. Map them to their natural RSpec equivalent, but **flag them to a human** — they
> usually shouldn't survive into the converted spec.

#### `it_should_work`

**Step regexp** — `/^it should work(.+?)?$/` (`development_steps.rb:4`)

**Intent** — Marks the scenario as **pending** (optionally with a reason).

**Mapping**
- before: `Then it should work`
- after: `pending('not yet implemented')` (or `skip('reason')`)
- before (with reason): `Then it should work once the API is live`
- after: `pending('once the API is live')`

**Notes** — RSpec's `pending` runs the example and expects it to fail (flips to failure if it unexpectedly
passes); `skip` doesn't run it. Spreewald uses Cucumber's `pending`, so `pending` is the closer match. Used
≈15×. Often the better conversion is to either finish the scenario or mark the whole `scenario`/`feature`
pending — flag for human judgement.

#### `console`

**Step regexp** — `/^console$/` (`development_steps.rb:10`)

**Intent** — Debugging: drop into an interactive IRB shell with the current test binding.

**Mapping**
- before: `Then console`
- after: `binding.irb` (or `binding.pry` / `debugger`, per the app's debugging gem)

**Notes** — Only 1 occurrence (left in by accident). Like `show me the page`, this is a debugging artefact —
convert to `binding.irb` if literally needed, but it should almost certainly just be **removed**. Flag to a human.

---

## Appendix: shared matchers for common *non-Spreewald* steps

The steps below are **not** from Spreewald — they are app-specific steps defined in each app's
`features/step_definitions/`, so strictly they fall under the "flag and map on demand" rule in
[Scope & coverage](#scope--coverage). They are included here only because one pattern — **flash / notification
messages** — appears across essentially every app (well over a thousand uses: `I should see a flash message
"…"`, `I should see a success flash`, `I should see "…" within the flashes`, etc.), and all the reference RSpec
apps already converge on a single matcher for it. Providing it here avoids re-deriving it per app. Treat this
as a convenience, not part of the Spreewald mapping; if an app's flash markup differs, tune the selector.

### Flash / notification messages

**Typical Cucumber steps** — `I should see a flash message "X"`, `I should see a success flash`,
`I should see a success flash with message "X"`, `I should see "X" within the flashes`,
`I should not see a flash message`.

**Mapping** — Use the `have_flash` matcher below (checks **text content** in the flash container):
- `I should see a flash message "Saved"` → `expect(page).to have_flash('Saved')`
- `I should see "Saved" within the flashes` → `expect(page).to have_flash('Saved')`
- `I should not see a flash message` → `expect(page).not_to have_flash`
- `I should not see the flash "Saved"` → `expect(page).not_to have_flash('Saved')`

**Flash *type* (success/danger/info) — support it only when the app's steps carry it.** Many Cucumber flash
steps state only text (`I should see a flash "Saved"`); then use the text-only form and don't invent a type.
But some apps' steps consistently state a meaningful type (`… success flash "X"` / `… danger flash`, which
distinguishes happy-path from error-path) — then pass it (`have_flash(:success, 'X')`) and **adapt the typed
selector in the matcher to the app's markup** (`.alert.alert-success`, `.flash-message.-success`, etc.).
**Dismissing** a flash (close icon, auto-removal) stays app-specific — convert those against the app's own
markup/behaviour.

**Support file — create in the target app** (`spec/support/matchers/have_flash.rb`). Registers globally, so no
`config.include` is needed:
```ruby
# spec/support/matchers/have_flash.rb
#
# Asserts a flash / notification message is shown, optionally containing given text.
# The flash *type* is optional and may be given either way:
#   have_flash('Saved')                  # any flash containing the text
#   have_flash(:success, 'Saved')        # leading-symbol form
#   have_flash('Saved', type: :success)  # keyword form
# When a type is given, edit the typed selector to match the app's markup.
RSpec::Matchers.define :have_flash do |*args|
  opts = args.last.is_a?(Hash) ? args.pop : {}
  type = opts[:type]
  type = args.shift if type.nil? && args.first.is_a?(Symbol)  # leading-symbol form
  text = args.first                                           # String, or nil for a presence-only check

  selector =
    if type
      ".flash.flash-#{type}, .alert.alert-#{type}"  # typed flash — adapt to the app's markup
    else
      '.flash, .alert, .notice, .success, [up-flashes]'
    end

  match do |page|
    text ? page.has_css?(selector, text: text) : page.has_css?(selector)
  end

  match_when_negated do |page|
    text ? page.has_no_css?(selector, text: text) : page.has_no_css?(selector)
  end

  failure_message do |_page|
    "expected a#{" #{type}" if type} flash#{" containing #{text.inspect}" if text} matching #{selector.inspect}"
  end

  failure_message_when_negated do |_page|
    "expected no#{" #{type}" if type} flash#{" containing #{text.inspect}" if text}, but found one"
  end
end

# So `have_no_flash` exists as a method (for `.and have_no_flash` chains) — do this for every custom matcher:
RSpec::Matchers.define_negated_matcher :have_no_flash, :have_flash
```

<!-- GUIDE-END -->
