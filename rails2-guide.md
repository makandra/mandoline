# Emulating feature specs in Rails 2 / RSpec 1

> **Extra resource for the Cucumber→RSpec migration.** Load this **only** when the target app is on
> the Rails-2-era stack (Rails LTS 2.3 + RSpec 1.x + Capybara 2.x). It **overrides** the parts of
> `app-migration-guide.md` and `conversion-guide.md` that assume modern RSpec (`feature`/`scenario`,
> `expect().to`, `RSpec.configure`, metadata-filtered hooks, `capybara/rspec`). Everything else in
> those guides (Spreewald/cucumber_factory mappings, the house-style *intent*, working scenario-by-
> scenario, the step→method mapping discipline) still applies.

This guide is written from a full, green migration of a real Rails LTS 2.3 app (`rspec 1.3.2`,
`rspec-rails 1.3.4`, `capybara 2.18`, `machinist 1`, `timecop`, `spreewald`, `cucumber_factory`).
Every code snippet below is taken from that working migration (with app-specific names replaced).


## 1. When this guide applies — detect it first

The standard guide's entire target DSL is **modern RSpec (2.14+/3.x)** and does not exist on RSpec 1.x.
Before writing any spec, detect the stack:

```bash
bundle show rspec        # rspec-1.x.x  -> this guide
ruby -e "require 'spec'; puts Spec::VERSION::STRING" 2>/dev/null   # 1.3.2
# The decisive check — does Capybara's RSpec integration even load?
bundle exec ruby -e "require 'capybara/rspec'"   # LoadError: cannot load such file -- rspec/core
```

If `require 'capybara/rspec'` raises `LoadError: cannot load such file -- rspec/core`, you are on this
path. Capybara 2.x's RSpec integration `require`s `rspec/core` (an RSpec-2+ gem), so `feature`/`scenario`
and Capybara's `have_*` matchers are unavailable. RSpec is pinned `< 2` because `rspec-rails 2+` needs
Rails 3+ — you **cannot** upgrade RSpec without leaving Rails 2. So you emulate feature specs on RSpec 1
instead. **Do not** attempt to upgrade the test stack; do not hand-wave past the `LoadError`.

**Good news up front:** the app already runs RSpec 1 for model/controller/request specs, so
`Spec::Runner.configure`, DatabaseCleaner, factories and the `.should` matcher protocol are all present.
You are only adding a *feature-spec* layer, driven by Capybara's driver-agnostic DSL.


## 2. The dialect at a glance

| Modern RSpec (standard guide) | Rails-2 / RSpec-1 dialect |
| --- | --- |
| `feature 'X' do … end` | `describe 'X', type: :feature do … end` |
| `scenario 'Y' do … end` | `it 'Y' do … end` |
| `expect(page).to have_content('Z')` | `page.should have_content('Z')` |
| `expect(x).to eq(y)` | `x.should == y` |
| `expect(page).to have_no_css('.e')` | `page.should have_no_css('.e')` |
| an `expect(page).to … .and …` chain | two lines: `page.should have_x` / `page.should have_y` (no compound matcher) |
| `scenario 'z', js: true` | `it 'z' do; use_js!; … end` (imperative — see §5) |
| `RSpec.configure` | `Spec::Runner.configure` |
| `config.infer_spec_type_from_file_location!` | not needed — you pass `type: :feature` on each `describe` |
| custom matcher `failure_message` / `failure_message_when_negated` | `failure_message_for_should` / `failure_message_for_should_not` |
| `require 'capybara/rspec'` | **never** — `require 'capybara'`, `'capybara/dsl'`, `'capybara/rails'` and mix in `Capybara::DSL` yourself |

### The single most important fact: the dynamic `have_*` → `has_*?` bridge

RSpec 1's built-in **dynamic predicate matcher** turns `foo.should have_bar(args)` into
`foo.has_bar?(args)`. Capybara defines exactly those predicates (`has_content?`, `has_css?`,
`has_no_content?`, `has_field?`, `has_select?`, `has_current_path?`, `has_link?`, `has_button?`,
`has_checked_field?`, `has_table?`, …). So **almost every Spreewald/Capybara assertion the standard
guide maps to `expect(page).to have_X` works verbatim as `page.should have_X`**, options hash and all:

```ruby
page.should have_content('Welcome')
page.should have_no_content('Error')
page.should have_css('.panel', visible: true)
page.should have_field('Email', with: 'a@b.c')
page.should have_current_path(users_path, ignore_query: true)
```

You do **not** need `capybara/rspec` for these — the bridge is pure RSpec 1 + Capybara predicates. This is
what makes the whole migration viable. Just translate `expect(page).to` → `page.should` and
`.not_to`/`have_no_*` as usual.


## 3. Support setup

The app's `spec/spec_helper.rb` already `require`s all of `spec/support/**/*.rb` and configures RSpec 1 via
`Spec::Runner.configure`. **You do not touch `spec_helper.rb`.** You only add feature-spec support files
under `spec/support/`. One load-order fact makes this clean:

> `spec_helper.rb` requires the support files **before** its own `Spec::Runner.configure` block runs. So a
> `config.before(:each)` registered in a support file runs **before** `spec_helper`'s own `before(:each)`
> (which typically does `DatabaseCleaner.start`). That lets a support file set the DB strategy that
> `spec_helper`'s `.start` then picks up — **without editing `spec_helper.rb`.**

### `spec/support/capybara.rb`

Ports the app's existing Capybara/Selenium config (from `features/support/capybara.rb` + `selenium.rb`),
mixes `Capybara::DSL` into feature groups, and manages driver + DB strategy per example.

```ruby
require 'capybara'
require 'capybara/dsl'
require 'capybara/rails'      # sets Capybara.app (uses ActionController::Dispatcher on Rails 2.3)
require 'selenium/webdriver'

# Ported from features/support/selenium.rb
Capybara.register_driver :selenium do |app|
  options = Selenium::WebDriver::Chrome::Options.new
  options.add_argument('--headless') unless ENV.key?('NO_HEADLESS')
  options.add_argument('--disable-infobars')
  options.add_emulation(device_metrics: { width: 1280, height: 960, touch: false })
  Capybara::Selenium::Driver.new(app, browser: :chrome, options: options)
end
Selenium::WebDriver.logger.level = :error

# Ported from features/support/capybara.rb — keep the app's legacy settings verbatim
Capybara.configure do |config|
  config.match = :prefer_exact
  config.ignore_hidden_elements = false        # this app renders hidden elements — important!
  config.asset_host = 'http://localhost:3000'
  config.default_max_wait_time = ENV['PARALLEL_TEST_GROUPS'].present? ? 10 : 4
end

Spec::Runner.configure do |config|
  # Filtered includes DO work in RSpec 1.3. This is how the DSL reaches feature groups.
  config.include Capybara::DSL, type: :feature

  # Feature specs run against a booted app server, so records must be visible across DB
  # connections -> :deletion (works for rack-test too). Runs BEFORE spec_helper's before(:each),
  # so this is the strategy its DatabaseCleaner.start uses.
  config.before(:each) do
    if self.class.respond_to?(:options) && self.class.options[:type] == :feature
      DatabaseCleaner.strategy = :deletion
      Capybara.use_default_driver          # rack-test until a scenario calls use_js!
    else
      DatabaseCleaner.strategy = :transaction   # keep non-feature specs on the fast path
    end
  end

  # Reset every piece of per-scenario state a use_*! helper may have set (see §5) — the
  # RSpec-1 equivalent of Cucumber's After('@tag') teardown hooks.
  config.after(:each) do
    if defined?(Capybara) && self.class.respond_to?(:options) && self.class.options[:type] == :feature
      Capybara.reset_sessions!
      Capybara.use_default_driver
      Capybara.default_max_wait_time = ENV['PARALLEL_TEST_GROUPS'].present? ? 10 : 4
      ActionController::Base.consider_all_requests_local = true
    end
  end
end
```

Notes:
- **`self.class.options`** is how an RSpec-1 `before(:each)` reads the group's metadata
  (`{ type: :feature, js: true, … }`). There is **no per-example accessor** — see §5.
- **DB strategy is `:deletion` for *all* feature specs**, not just JS ones. This deliberately removes
  the per-example strategy decision (which would be impossible to make at the right time — see §5).
- Reading `Capybara.ignore_hidden_elements`, `Capybara.match` etc. from the app's own
  `features/support/capybara.rb` matters — legacy apps often disable hidden-element filtering.

### `spec/support/feature_helpers.rb` — DSL includes + auth + route helpers

```ruby
module FeatureHelpers
  # ... use_*! helpers (see §5) and app auth helpers (sign_in, sign_out, ...) ...
end

Spec::Runner.configure do |config|
  # Installs the named route helpers (root_path, new_session_path, ...) + default_url_options onto
  # each feature group — the same mechanism ActionController::IntegrationTest uses. Callable BARE
  # (`visit new_session_path`) with NO `send`. (They are installed as private methods, so
  # `respond_to?(:new_session_path)` is false — a reflection quirk, irrelevant to bare calls.)
  config.include ActionController::UrlWriter, type: :feature
  config.include FeatureHelpers, type: :feature
end
```

**Route helpers — the one non-obvious bit.** A plain RSpec-1 example group has no route helpers.
`include ActionController::UrlWriter` into the group fixes it (its `included` hook calls
`install_helpers` and sets up `default_url_options` on the group class). Do **not** try
`ActionController::Routing::Routes.install_helpers(SomeModule)` into a standalone module — its
`default_url_options` mattr lands on the wrong object and `_path` helpers raise
`NoMethodError: default_url_options`.


## 4. `describe … type: :feature`, not `feature`

**Every spec file must start with `require 'spec_helper'`.** RSpec 1 has no `.rspec` file (no `--require spec_helper`), so nothing auto-loads the helper the way modern RSpec does — put `require 'spec_helper'` as the literal **first line** of every migrated spec, or it won't find the support files / config and fails opaquely.

```ruby
require 'spec_helper'

describe 'Authentication', type: :feature do

  it 'redirects protected pages to the sign in form' do
    visit root_path
    page.should have_current_path(new_session_path, ignore_query: true)
  end

  it 'signs in with valid credentials' do
    User.make(screen_name: 'alice')       # Machinist (this app's factory gem)

    visit new_session_path
    fill_in 'Username or email', with: 'alice'
    fill_in 'Password', with: 'correcthorsebatterystaple'
    click_button 'Sign in'

    page.should have_css('.user-menu .current-user')
  end

end
```

- `type: :feature` is what the support-file `config.include(..., type: :feature)` and
  `config.before(:each) { … options[:type] == :feature … }` filter on. **It must be on every feature
  `describe`.** `rspec-rails 1.3` treats an unknown `:type` as a plain example group (which is what you
  want — you mix in Capybara yourself).
- The **file layout** rule from the standard guide still holds: `features/users/list.feature` →
  `spec/features/users/list_spec.rb`.
- **Modern hash syntax** (`key: value`) is fine and preferred — Rails LTS apps run a modern Ruby (e.g.
  2.5), and there is usually **no RuboCop** to normalize style, so write it cleanly yourself. (Verbatim
  ports of old app files may keep their hash rockets; that's fine.)


## 5. Cucumber tags → imperative `use_*!` helpers (the core pattern)

This is the biggest structural difference and it is **general**, not specific to `@javascript`.

**Why metadata doesn't work.** RSpec 1.3 can filter `config.include` by group metadata, but a
`config.before(:each, type: :feature)` filter is unreliable and, crucially, **there is no way to read the
current *example's* options inside a `before(:each)`** (only the *group's*, via `self.class.options`).
Cucumber's `Before('@tag')` / `After('@tag')` hooks are inherently **per-scenario**. So every tag that
maps to per-scenario setup hits the same wall.

**The pattern.** Migrate each such tag to a uniform **`use_<tag>!` helper** called at the **top**
of the example, and reset it centrally in the shared `after(:each)` (§3). Group all `use_*!` calls
together and **follow them with a blank line** before the first action — the Rails-2 analog of the
house style's "blank line after setup".

```ruby
module FeatureHelpers
  # @javascript -> real (headless Chrome) browser
  def use_js!
    Capybara.current_driver = :selenium
  end

  # @allow-rescue -> let the app render its own error page (403/404/422) instead of the
  # local debug page / re-raising. (Rails 2.3: flip consider_all_requests_local.)
  def use_allow_rescue!
    ActionController::Base.consider_all_requests_local = false
  end

  # Before('@patiently') { Capybara.default_max_wait_time = 12 }
  def use_long_wait_time!
    Capybara.default_max_wait_time = 12
  end
end
```

```ruby
it 'lets only admins access the settings' do
  use_allow_rescue!            # was @allow-rescue

  sign_in_as_user
  visit settings_path
  page.should have_content('Access denied')
end

it 'shows the totals' do
  use_js!                      # was @javascript
  use_allow_rescue!

  visit root_path
  page.should have_content('Total')
end
```

Mapping any `Before('@x') { …set state… }` this way, with the matching reset added to `after(:each)`,
is mechanical.

**The one exception — state needed before `DatabaseCleaner.start`.** A body-level helper runs *after*
`spec_helper`'s `before(:each)`. That's fine for the driver, `allow_rescue`, wait time, locale, etc.
(all consumed later, at `visit`/request time). It is **too late** for the DB *cleaning strategy*, which
`.start` reads. That is exactly why §3 uses `:deletion` for **all** feature specs — removing that one
decision from the per-example path. Do not try to make a `use_js!` also switch the DB strategy.

### Whole-feature tags

If an *entire* feature is `@javascript`, you may instead put `js: true` on a group and branch in a
`before` on `self.class.options[:js]` — but the imperative helper is simpler, always correct, and keeps
original scenario order, so prefer it. To keep a *mixed* feature's order with a group approach you would
wrap each JS scenario in its own `describe '…', js: true` (verified to inherit the outer `before`/`let!`
and the type-filtered includes) — but `use_js!` avoids that nesting entirely.


## 6. Custom matchers on RSpec 1.3

`Spec::Matchers.define` exists in RSpec 1.3 and supports `match`, `chain`,
`failure_message_for_should`, and `failure_message_for_should_not`. Differences from the standard
guide's RSpec-3 matchers:

- rename `failure_message` → **`failure_message_for_should`**, `failure_message_when_negated` →
  **`failure_message_for_should_not`**.
- there is **no negated-match block** (`match_when_negated`). `should_not have_x` just runs
  `!matches?`. When you need the negation to *wait for absence* (Capybara `has_no_*?`), define a
  **separate** matcher (e.g. `have_no_flash`) instead of relying on `should_not`.
- there is **no `define_negated_matcher`**.
- **do not use `define_method` inside the matcher block** (the RSpec-3 trick). RSpec 1.3's matcher DSL
  doesn't support it. Put helper logic in a plain module (`module_function`) and call it.
- a matcher's `match` block runs on the **matcher instance**, which does **not** have the example
  group's helper methods. So retry helpers must be callable at **module level** (see `patiently` below).

### Flash matcher (adapt the selector to the app's markup)

```ruby
# App markup: <div class="flash notice|error|success|...">text</div>
def _have_flash_selector(type)
  type ? ".flash.#{type}" : '.flash'
end
def _have_flash_parse(args)
  opts = args.last.is_a?(Hash) ? args.pop : {}
  type = opts[:type]
  type = args.shift if type.nil? && args.first.is_a?(Symbol)   # leading-symbol form
  [type, args.first]
end

Spec::Matchers.define :have_flash do |*args|
  type, text = _have_flash_parse(args)
  selector = _have_flash_selector(type)
  match { |page| text ? page.has_css?(selector, text: text) : page.has_css?(selector) }
  failure_message_for_should { |_p| "expected a#{" #{type}" if type} flash#{" containing #{text.inspect}" if text}" }
end

# Separate matcher so the negation WAITS for absence (has_no_css?), which `should_not` wouldn't.
Spec::Matchers.define :have_no_flash do |*args|
  type, text = _have_flash_parse(args)
  selector = _have_flash_selector(type)
  match { |page| text ? page.has_no_css?(selector, text: text) : page.has_no_css?(selector) }
  failure_message_for_should { |_p| "expected no flash, but found one" }
end
```

### Retry helper (`patiently`) — must be module-callable

**The modern guide uses the `patiently` gem** (`require 'patiently/rspec'`), but its RSpec wiring calls
`RSpec.configure`, which doesn't exist on RSpec 1 — so here you **vendor** the helper instead. Port it from the
Spreewald guide's `patiently`, but declared `module_function` so it works both as a mixed-in instance method
(in example bodies) **and** at module level (from matcher `match` blocks):

```ruby
module PatientlyHelper
  module_function
  IN_PATIENTLY = :in_patiently
  WAIT_PERIOD = 0.05

  def patiently(seconds = Capybara.default_max_wait_time, &block)
    return block.call if Thread.current[IN_PATIENTLY]
    started = monotonic_time; tries = 0
    begin
      Thread.current[IN_PATIENTLY] = true; tries += 1; block_started = monotonic_time
      block.call
    rescue Exception => e
      raise e if block_started - started > seconds && tries >= 2
      sleep(WAIT_PERIOD)
      raise Capybara::FrozenInTime, 'time appears frozen' if monotonic_time == started
      retry
    ensure
      Thread.current[IN_PATIENTLY] = false
    end
  end

  RetryUntilTrue = Class.new(StandardError)
  def patiently_wait_until(&block)
    patiently { block.call || raise(RetryUntilTrue) }; true
  rescue RetryUntilTrue
    false
  end

  def monotonic_time; Process.clock_gettime(Process::CLOCK_MONOTONIC); end
end

Spec::Runner.configure { |c| c.include PatientlyHelper, type: :feature }
```

A retry-capable matcher then calls it at module level (`define_method` avoided):

```ruby
module TableMatching
  module_function
  # ... normalize / cell_matches? / row_matches? / table_matches? / tables_on_page ...
end

Spec::Matchers.define :have_table_with_rows do |*expected_rows|
  chain(:exactly)      { @exactly = true }         # chain() works in RSpec 1.3
  chain(:in_any_order) { @in_any_order = true }
  match do |page|
    PatientlyHelper.patiently_wait_until do
      @tables = TableMatching.tables_on_page(page)
      @tables.any? { |rows| TableMatching.table_matches?(rows, expected_rows, @exactly, @in_any_order) }
    end
  end
  failure_message_for_should { |_p| "no table matched:\n#{expected_rows.inspect}\nfound:\n#{@tables.inspect}" }
end
```

The Spreewald guide's `have_flash`, `have_table_with_rows`, `have_content_in_order`, `have_field_error`
all port this way: swap the failure-message method names, move inner helpers to a `module_function`
module, and call `PatientlyHelper.patiently_wait_until` at module level instead of assuming it's in scope.


## 7. More Cucumber/RSpec patterns (verified)

### `Scenario Outline` → parameterized shared examples

RSpec 1.3 provides `share_examples_for 'name' do … end` + `it_should_behave_like 'name'` — the **names
differ** from RSpec 2/3 (`shared_examples` / `it_behaves_like` do **not** exist). More importantly,
RSpec 1's shared examples take **no block parameters**, so the standard guide's
`shared_examples 'x' do |email:, …|` + `it_behaves_like 'x', email: …` does not translate directly.

Use **`it_should_act_like(group, env_hash)`** — makandra's `rspec_candy` helper, frequently **inlined in
a project's `spec/support/spec_candy.rb`** (and sometimes shipped as the `rspec_candy` gem). It wraps the
shared group in a `describe`, turns each `env_hash` entry into a `let`, then calls
`it_should_behave_like`. So each `Examples:` row becomes **one explicit `it_should_act_like` line**
(matching the standard guide's "one line per row, no loops, no metaprogramming"):

```ruby
share_examples_for 'previous-year summary' do
  it 'shows the totals of the previous year' do
    travel_to_time(date)        # `date` is provided as a let by it_should_act_like
    # ...build data, assert with have_table_with_rows...
  end
end

it_should_act_like 'previous-year summary', date: '2011-01-02'
it_should_act_like 'previous-year summary', date: '2011-01-05'
```

If neither `rspec_candy` nor a local `it_should_act_like` exists, fall back to a plain **helper method
defined in the `describe` + one `it` per row** (each `it` calls the helper with that row's values) —
never a loop.

### Email — Rails 2.3 ActionMailer uses TMail, **not** the `mail` gem

Rails 2.3 builds **`TMail::Mail`**, which has **no `html_part` / `text_part`** and only a plain
`body` / `parts` API (`multipart?`, `content_type` are limited). The Spreewald guide's `MailHelpers`
(written for the modern Mail gem) dies with `NoMethodError: undefined method 'html_part'`. Read the body
via `mail.body` / `mail.parts` instead, and clear deliveries before each feature example (RSpec doesn't;
Spreewald did):

```ruby
def mail_body_text(mail = last_mail)
  if mail.respond_to?(:parts) && mail.parts && !mail.parts.empty?
    mail.parts.map { |part| part.body.to_s }.join("\n")   # multipart
  else
    mail.body.to_s                                          # TMail single-part
  end
end
def mail_text(mail = last_mail)   # visible text (strips tags for HTML mails)
  Nokogiri::HTML(mail_body_text(mail)).text.strip
end
def mail_links(mail = last_mail)  # scan body for links (works for plain-text AND HTML)
  mail_body_text(mail).scan(%r{https?://\S+}).map { |u| u.sub(/["'>).,]+\z/, '') }
end
def mail_link_paths(mail = last_mail) # host-stripped, so `visit` hits the test server
  mail_links(mail).map { |href| href[%r{https?://[^/]+([^"'\s]+)}, 1] }.compact
end

Spec::Runner.configure do |config|
  config.include MailHelpers, type: :feature
  config.before(:each) do
    ActionMailer::Base.deliveries.clear if self.class.respond_to?(:options) && self.class.options[:type] == :feature
  end
end
```

Assertions run straight against `ActionMailer::Base.deliveries` (no matcher bridge). `Then an email
should have been sent to "x" with the subject "y"` → find it and assert present; "follow the link in the
email" → `visit mail_link_paths(mail).first`.

### File downloads — Tier 1 works on rack-test

`Then I should get a download with filename "X"` → after clicking the (GET) download link, assert the
`Content-Disposition` header, which rack-test exposes. No real browser, no download directory:

```ruby
click_link 'Download'
page.response_headers['Content-Disposition'].should match(/filename.*X/)
```

(Only use the browser-download-directory approach for genuinely JS-triggered downloads.)

### JS confirm dialogs — merge trigger + confirm

Capybara 2.18's `accept_confirm { … }` / `dismiss_confirm { … }` work on the Selenium driver. As in the
standard guide, the Cucumber "click, then confirm the dialog" **pair collapses into one block**:

```ruby
accept_confirm { click_link 'Withdraw' }   # was: follow "Withdraw" + I confirm the browser dialog
```

### JS widget helpers (e.g. jQuery datepicker) — `execute_script`

App-specific JS steps (`I show the "…" datepicker`) port to `page.execute_script`:

```ruby
def show_datepicker(id); page.execute_script("$('.datepicker##{id}').datepicker('show')"); end
```

### Auth across multiple users — `sign_in` must log out first

A scenario that signs in as several users in turn (e.g. permission specs) needs `sign_in` to log out
any current user first (the original Cucumber step did). Mirror it, or the second sign-in lands on a
"already logged in → redirected to root" page and `fill_in` fails:

```ruby
visit new_session_path
if page.has_css?('.user-menu .current-user', wait: 0)
  sign_out
  visit new_session_path
end
```


## 8. Migrating `features/support/**`

Same audit-and-port idea as the standard guide's Phase 3b, with these Rails-2 specifics:

| Cucumber support file | What to do |
| --- | --- |
| `capybara.rb`, `selenium.rb` | Port config verbatim into `spec/support/capybara.rb` (§3). |
| `database_cleaner.rb` | Usually **redundant** — the app's `spec_helper.rb` already configures DatabaseCleaner for its model specs. Don't duplicate it; just set `:deletion` for feature specs in your `before(:each)` (§3). |
| `env.rb` | Drop all Cucumber requires (`cucumber/rails`, `capybara/cucumber`, `spreewald/all_steps`, …). Port only genuinely needed non-Cucumber requires. |
| `capybara_javascript_emulation.rb` | **Port it** (see below) — needed so rack-test can follow `link_to :method => :delete/:put/:post`. Drop its `Before('@no-js-emulation')` toggle hooks. |
| `capybara_screenshot.rb` | `require 'capybara-screenshot'` for config only (save_path/prune). Its `capybara-screenshot/cucumber` and `/rspec` integrations are Cucumber-/RSpec-2-specific — skip them. |
| `examiners.rb` and other `AfterStep`/`@pause`/`@slomo`/`@single_step` debugging hooks | **Drop** entirely. |
| `find_by_anything.rb`, `find_or_make.rb`, other `ActiveRecord::Base.class_eval` monkeypatches | Port **verbatim** (plain Ruby, no Cucumber deps). |
| `paths.rb` (`NavigationHelpers#path_to`), `selectors.rb` (`HtmlSelectorsHelpers#selector_for`) | The standard guide says *inline* the resolved route/selector, and that's still best for readability. But these resolvers are plain Ruby; on a large legacy app with hundreds of `I go to the X page` steps, porting them verbatim (replacing the trailing `World(mod)` with `config.include(mod, type: :feature)`) is a pragmatic escape hatch. Prefer inlining in the specs you write; keep the resolver available for the long tail. |

`World(SomeModule)` at the bottom of a support file becomes
`Spec::Runner.configure { |c| c.include SomeModule, type: :feature }` — the RSpec-1 form of the standard
guide's `World(mod)` → `config.include(mod, type: :feature)` rule.


## 9. Rails-2-era gotchas (learned the hard way)

- **`data-method` / non-GET links need the JS-emulation monkeypatch on rack-test.** Rails 2.3
  `link_to X, :method => :delete` renders an `onclick` form-builder (or `data-method` on newer LTS). The
  rack-test driver can't follow it, so a "sign out" / "archive" link silently does nothing. Port
  `features/support/capybara_javascript_emulation.rb` verbatim (it patches
  `Capybara::RackTest::Node#click` to synthesize the form), dropping only its `Before` toggle hooks:
  ```ruby
  class Capybara::RackTest::Node
    include ::Cucumber::Rails::Capybara::JavascriptEmulation
  end
  ```
  JS (Selenium) scenarios don't need it (the real browser submits the form).

- **`@allow-rescue` → `consider_all_requests_local = false`.** In the `test` env
  `consider_all_requests_local` is `true`, so an exception renders Rails' *local debug* page rather than
  the app's own 403/404/500. To assert on the app's error page (e.g. "Access denied"), a
  `use_allow_rescue!` helper flips it to `false` for that example (reset in `after(:each)`). This is the
  RSpec-1 analogue of cucumber-rails' `allow_rescue` mechanism (which cucumber-rails implements as
  exactly `ActionController::Base.allow_rescue = true` around a tagged scenario).

- **A dedicated `cucumber` Rails environment folds into `test`.** If the app has
  `config/environments/cucumber.rb` (and a `cucumber:` DB), feature specs run under **`test`**. Diff the
  two env files and port anything the E2E suite relies on into `test.rb`. (In practice they're often
  near-identical: `consider_all_requests_local = true`, `allow_forgery_protection = false`,
  `action_mailer.delivery_method = :test` — so no porting is needed. Verify, don't assume.)

- **Legacy date inputs are often plain text fields, not HTML5 `<input type=date>`.** Before HTML5 dates,
  date entry was typically a JS widget over a plain text `<input>` whose value is the **locale-formatted
  string** — a jQuery datepicker with German `dd.mm.yyyy` (`24.12.2011`) is the common Rails-2 case, but
  the principle is the same for any such widget: find how the app actually renders and stores the value.
  When it's a text field — unlike the standard guide's HTML5-date gotcha — you **carry the localized
  string verbatim**: `fill_in 'Date', with: '1.1.2011'` and
  `page.should have_field('Date', with: '24.12.2011')`.

- **Machinist 1, not FactoryBot.** cucumber_factory prose maps to `Model.make(:trait, attr: value)` (see
  the cucumber_factory guide's Machinist lines). Blueprints live in `spec/support/blueprints.rb`
  (`User.blueprint(:admin) { … }`, `Sham.define { … }`). A parenthetical variant that has **no**
  matching blueprint but *is* the model's default state (e.g. `(published)` when the base blueprint already
  sets `state 'published'`) → just `Model.make(attrs)` with the default. A boolean-ish trailing clause
  (`which is featured on homepage`) is usually a boolean **attribute** (`featured_on_homepage: true`),
  not a trait.

- **Time travel uses the app's Timecop.** Mirror Spreewald's `TimecopHarness#parse_time`
  (`Time.zone.parse` only when timezone-aware, else `Time.parse`) so a `:local` app isn't shifted an
  hour. `spec_helper.rb` already resets via `Timecop.return` in `after(:each)`. In a JS scenario, Timecop
  affects **Ruby/server** time (the app server runs in a thread in the same process), which is what
  server-rendered assertions read — but it does **not** move the browser's JS clock, so handle auto-ticking
  relative-time assertions the way the standard guide does: **absorb the timing with a waiting matcher — do
  not skip** (see the auto-ticking-time bullet in `conversion-guide.md`).

- **`self.class.options[:type]` is `nil` in a nested group** (a child `describe` only carries its own
  options). Type-filtered `config.include`s still reach the child by example-group inheritance, and outer
  `before`/`let!` are inherited — but any hook that *reads* `options[:type]` must tolerate `nil` on
  children.

- **Old Cucumber too (≈1.3) — no `ParameterType`, no modern Gherkin.** The standard guide mentions
  cucumber-expressions `ParameterType(...)` (in `parameter_types.rb`); Cucumber 1.3 predates it entirely
  (regexp step definitions only, `Cucumber::Factory.add_steps`), so you won't encounter it. Custom step
  arguments are plain regexp captures — nothing special to inline. Likewise there are no cucumber-
  expressions `{int}`/`{word}` placeholders to translate.

- **TMail, not the `mail` gem** (see §7 *Email*) — the single biggest surprise when migrating mail specs.


## 10. Running the specs

The runner is the RSpec-1 `spec` binary (not `rspec`):

```bash
TZ='Europe/Berlin' bundle exec spec spec/features/users/list_spec.rb          # one file
TZ='Europe/Berlin' bundle exec spec spec/features/users/list_spec.rb:12       # by line (RSpec 1 supports it)
```

Set `TZ` to match CI (headless Chrome inherits it). Fan-out via `parallel_tests` works the same as the
standard guide (`TEST_ENV_NUMBER`), and JS scenarios still need a matching Chromedriver — ensuring one
exists is the developer's own dev-environment responsibility (on a geordi stack, `geordi
chromedriver-update`). Everything in the standard guide about **working scenario-by-scenario**,
**reviewing each migrated scenario**, and the **step→method mapping** artifact applies unchanged.

**Translate every `bundle exec rspec` in the standard guides to `bundle exec spec`** — including Phase 6's
verification run. One caveat for the orphaned-process cleanup that guide prescribes before the final run:
`bundle exec spec` actually launches `<rbenv-path>/bin/spec`, so `pkill -f 'bundle exec spec'` **misses**
the real process — find it (`ps`/`pgrep spec`) and kill it by **PID**.


## 11. What still differs from the house style (accept these)

These are unavoidable on RSpec 1 and should **not** be "fixed":

- `describe`/`it` instead of `feature`/`scenario`; `.should` instead of `expect().to`.
- No `.and`-chained expectations → one `page.should have_*` per line.
- `js: true` becomes a `use_js!` call rather than metadata (and the other `use_*!` helpers for other
  tags).
- Custom matchers use the RSpec-1 DSL method names.
- **No `skip`.** RSpec 1.3 has no `skip`, and a bare `pending('reason')` does **not** reliably halt — the
  body still runs, and if it raises it's reported as a *failure*, not pending. So in the rare case a scenario
  genuinely can't be verified (an **absent system dependency** — see the *missing dependency* rule in
  `conversion-guide.md`; this is a last resort, not the flaky-timing or global-mock cases, which you
  reproduce rather than skip), instead of `skip` leave the body **unrun**: an `it 'desc (skipped: reason)'`
  with **no block** (RSpec 1 reports a blockless example as pending and never executes it), and flag it for
  the human. Don't rely on `pending` to behave like RSpec 2's `skip`.

Everything else — the arrange→act→assert rhythm, blank-line beats, narrating comments, named
helpers (`sign_in_as_admin`, `have_flash`), factories with traits, asserting model state alongside
rendered state — should read exactly as the house style prescribes.


## Appendix — proven support-file inventory

A complete, green feature-spec foundation for a Rails-2/RSpec-1 app looks like this (names illustrative):

```
spec/support/capybara.rb                     # driver + DSL include + DB strategy + tag reset (§3)
spec/support/capybara_javascript_emulation.rb# rack-test non-GET link support (§9)
spec/support/capybara_screenshot.rb          # save_path/prune config only
spec/support/feature_helpers.rb              # use_*! tag helpers, auth helpers, UrlWriter include (§5)
spec/support/mail_helpers.rb                 # TMail-safe mail body/links + deliveries clearing (§7)
spec/support/paths.rb                        # ported NavigationHelpers#path_to (World -> config.include)
spec/support/selectors.rb                    # ported HtmlSelectorsHelpers#selector_for
spec/support/find_by_anything.rb             # verbatim AR monkeypatch
spec/support/find_or_make.rb                 # verbatim AR monkeypatch
spec/support/patiently.rb                    # module_function patiently / patiently_wait_until (§6)
spec/support/time_travel_helpers.rb          # Timecop + parse_time (§9)
spec/support/matchers/have_flash.rb          # + have_no_flash (§6)
spec/support/matchers/have_table_with_rows.rb
spec/support/matchers/have_content_in_order.rb
spec/support/feature_steps/*.rb              # converted cross-cutting step-helpers (auth, domain, datepicker)
```

## Coverage proven in the reference migration

This guide's patterns were validated by migrating a real app's feature files, **all green together**,
with its **existing model/controller specs still green** (the added support files don't disturb the existing
suite): authentication (incl. email/password-reset), clickable table rows, several CRUD sections,
notifications, a JS sidebar with server-side calculations, export (downloads), a Scenario Outline, and a
form with a confirm dialog + datepicker. Between them they exercise: CRUD +
flash + validation, `have_table_with_rows` (incl. `*` wildcards) / `have_content_in_order` /
`have_field` / `have_current_path`, `@allow-rescue`, `<select>`, associations, Timecop time-travel,
localized date text fields, Machinist factories with traits, JS via `use_js!` + `patiently` + `accept_confirm`
+ `execute_script`, Tier-1 downloads, TMail email + follow-link, and Scenario Outline via
`it_should_act_like`.
