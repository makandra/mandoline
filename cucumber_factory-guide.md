# cucumber_factory → RSpec/FactoryBot migration guide

## What this guide is

We are migrating legacy Rails apps from **Cucumber** to **RSpec feature specs**. Alongside Spreewald (see
`spreewald-guide.md`), these apps lean heavily on the [`cucumber_factory`](https://github.com/makandra/cucumber_factory)
gem, which lets `.feature` files create test records straight from prose — `Given there is a movie with the
title "Sunshine"` — with **no step definitions**. In RSpec specs we instead call the factory gem directly
(`create(:movie, title: 'Sunshine')`). This document maps every cucumber_factory prose variation to its
factory-gem equivalent so a downstream conversion agent can translate these steps mechanically.

This is a companion to `spreewald-guide.md`; the same `.feature` files contain both Spreewald steps and
cucumber_factory steps (every `Given there is …` / `… is a …` / `the … above has …` is cucumber_factory).

You (the conversion agent) convert the factory prose in the **target repo's own `features/**`**. When a rule below isn't enough, read the source of the gems the app bundles (`bundle show <gem>`, run inside the target repo):

- **cucumber_factory** — `bundle show cucumber_factory`; its `README.md` is the **authoritative list of
  variations**, and `lib/cucumber_factory/factory.rb` / `build_strategy.rb` are the parser if you need an edge case.
- **FactoryBot** (the primary target gem) — `bundle show factory_bot`; `GETTING_STARTED.md` is the reference.
- **Machinist 1** (legacy target gem — e.g. an old Rails-2 app) — `bundle show machinist`; `README.markdown`
  is the reference. On such an app the blueprints live in the app's **own** `spec/support/blueprints.rb`
  (e.g. `User.blueprint(:admin)`) — grep the target repo for those.

For house-style precedent (`create(:model, :trait, attr: value)`, associations as local-variable references),
look at the target app's own already-migrated `spec/features/**` — not another project's code.

### How to read a rule

Each rule has the **cucumber_factory variation** it maps, a one-line **intent**, a **before** (Cucumber prose)
/ **after** (RSpec code) pair, and **notes** for edge cases. The **after** is shown for **FactoryBot** (the
common case); where Machinist differs, a **Machinist (legacy)** line is added. Rules are grouped by the kind of
thing the prose expresses (creation, attributes, associations, …).

> **Unlike the Spreewald guide, there is no usage filter:** every cucumber_factory variation documented here is
> in scope and must be mapped — they all occur somewhere in the apps. There is also no static list of steps to
> enumerate: cucumber_factory registers a *handful of generic regexp steps* (in `factory.rb`) and parses
> everything after `there is` dynamically. The README's variations are therefore the checklist.

---

## Cross-cutting conventions (read first — they apply to every rule)

### 1. Detect the app's factory gem and target its syntax

cucumber_factory picks a backend at runtime; you must do the same statically per app. Detect it once, up front:

- **FactoryBot** (the common case) — `Gemfile` has `factory_bot` / `factory_bot_rails`; factories live in
  `spec/factories.rb` or `spec/factories/**/*.rb` and use `FactoryBot.define { factory :movie do … end }`.
  → map to **`create(:movie, …)`**.
- **factory_girl** (FactoryBot's old name; some legacy apps) — `Gemfile` has `factory_girl` /
  `factory_girl_rails`; `FactoryGirl.define`. **Identical syntax** to FactoryBot — still `create(:movie, …)`
  (the app aliases `FactoryGirl`/`FactoryBot`). Treat exactly like FactoryBot.
- **Machinist 1** (older legacy apps) — `Gemfile` has `machinist`; blueprints live in `spec/blueprints.rb`
  using `Movie.blueprint do … end`. → map to **`Movie.make(…)`** (see the Machinist lines per rule).
- **No factory gem** (rare) — cucumber_factory falls back to `Movie.create!(attrs)` / `Movie.new(attrs)`. If an
  app genuinely has no factory gem, map to `Movie.create!(attrs)`. Flag it — it's unusual for these apps.

If you can't tell which gem an app uses, **stop and ask** rather than guessing — the entire mapping depends on it.

### 2. Record references (`above`, named records, remembered strings) → Ruby local variables

This is the single most important transformation. In Cucumber, created records are referenced *implicitly* by
later steps in three ways; **all three become an ordinary Ruby local variable** in the spec:

- **`above`** — "the last created record of this class". `with the prequel above` refers to the most recent
  movie. → assign the created record to a variable and reference it. **Caveat:** `above` actually resolves to a
  *freshly loaded* `Klass.last` (`CucumberFactory::Switcher.find_last`), with **no cached associations**, whereas
  a local variable carries whatever associations it loaded earlier. This only bites when a **factory callback
  recomputes state by traversing back through the association you're setting** (e.g. an `after(:create)` that
  iterates `screening.tickets`): the local var's stale collection then yields a silent wrong number. There,
  pass a freshly loaded record — `create(:x, screening: screening.reload)` — matching what `above` did. Don't
  `reload` everywhere; only where such a write-back callback is involved. **And `above`/`Model.last!` can resolve
  to a *different record* than it did in Cucumber:** when a scenario mixes **explicit fixture ids** with
  sequence-generated ones, id assignment differs between the Cucumber and migrated setups, so "the last record"
  flips — work out which record the origin's `Model.last!` actually meant before mapping "the … above" (a literal
  port can silently point elsewhere).
- **Named record** — `"Before Sunrise" is a movie` registers the record under the handle `"Before Sunrise"`
  (the string is *only a handle*, not an attribute). → use it as the variable name.
- **Remembered string/number** — after creation, cucumber_factory remembers the record under **every string
  or integer attribute value** it was given, so `there is a movie with the title "Before Sunrise"` can later be
  referenced as `with the prequel "Before Sunrise"`. → assign a variable when you create it and reuse it.

So the agent **introduces local variables** and wires associations by reference. Example:

- before:
  ```cucumber
  Given there is a movie with the title "Before Sunrise"
  And there is a movie with the title "Limitless" and the prequel "Before Sunrise"
  And the movie above has the year 2011
  ```
- after:
  ```ruby
  before_sunrise = create(:movie, title: 'Before Sunrise')
  limitless = create(:movie, title: 'Limitless', prequel: before_sunrise)
  limitless.update!(year: 2011) # "the movie above" == the last-created movie == limitless
  ```

**Variable naming:**
- **Assign a variable to every record you use later** — to set an association, or to make an assertion on it.
  Derive a readable name from the record's handle/name/title (`before_sunrise`), or from the model with a
  counter when it has no obvious handle (`movie`, `movie_2`).
- **Records you never reference again don't need a variable.** But if naming one makes the scenario's intent
  clearer, do — and **prefix the name with `_`** so RuboCop doesn't flag the unused assignment, e.g.
  `_expired_credit_card = create(:credit_card, :expired)`. The `_` says "created deliberately for its
  side-effect/intent, not used below".

cucumber_factory resets its named-record registry before each scenario (a `Before` hook); in RSpec local
variables are naturally scoped to the example, so there is nothing to reset.

### 3. Model & attribute names: prose → symbol (downcase, spaces/slashes → underscore)

- **Model** → factory name: lowercased, non-alphanumerics → `_`, `/` → `_`. `a movie` → `:movie`,
  `an admin user` → `:admin_user`, `a car/motorization` → `:car_motorization`. (FactoryBot factory or, for
  Machinist, the model class `CarMotorization`.)
- **Attribute** → keyword: the prose after `the`, lowercased, spaces → `_`. `with the original title "Sunshine"` →
  `original_title: 'Sunshine'`; `with the account balance "-30000"` → `account_balance: '-30000'`.

### 4. Value types

| Prose | Parsed as | RSpec value |
| --- | --- | --- |
| `"text"` or `'text'` | string | `'text'` (ActiveRecord casts to the column type, incl. dates) |
| `2007` (unquoted) | integer | `2007` |
| `3.14` (unquoted) | decimal | `3.14` (pass the literal; AR casts — use `BigDecimal('3.14')` only if you need exactness) |
| `"500000"` (quoted number) | **string** | `'500000'` (quoted ⇒ string, even if numeric) |
| `file:"path"` | file | see the **File attributes** rule |
| `["a", "b"]` | array | see the **Arrays / has_many** rule |
| `above` / `"name"` | record reference | a local variable (convention #2) |

### 5. `create` persists — use `create`, not `build`

cucumber_factory always **saves** the record (FactoryBot `create`, Machinist `make`, or `create!`). Always map
to `create(...)` / `Model.make(...)`; never `build`/`make_unsaved`.

### 6. FactoryBot::Syntax::Methods (bare `create`)

All the reference RSpec apps include `config.include FactoryBot::Syntax::Methods` (in
`spec/support/factory_bot.rb`), so feature specs call a bare `create(:movie)` rather than
`FactoryBot.create(:movie)`. Assume this is present (add it if a target app lacks it):
```ruby
# spec/support/factory_bot.rb
RSpec.configure do |config|
  config.include FactoryBot::Syntax::Methods
end
```

### 7. Overrides (`cucumber_priority` / `.overridable`)

See *Watch for app overrides of predefined steps* in `app-migration-guide.md` for the general rule. **Factory-specific
tell:** cucumber_factory's generic steps are registered `.overridable` at low priority, so a `there is …` / `… exists`
line you **can't parse into model + attributes** is usually an app-defined override (e.g. one that builds an object
graph the factory can't express). When that happens, read the matching custom step in `features/step_definitions/`
and convert per its Ruby, not via this guide.

### 8. Porting exposes factory *defaults* the Cucumber suite never touched — lint the factories

cucumber_factory steps name their attributes explicitly (`there is a movie with the title "Sunrise"`), so a factory's own defaults and associations were often never exercised. A migrated spec calling `create(:movie)` runs the whole factory, which is how a migration surfaces **latent factory bugs that predate it by years** — in one app, a typo in a factory's association only blew up once migrated specs stopped passing every attribute by hand. That failure looks like the migration broke something; it didn't.

So run **`FactoryBot.lint`** (or simply `create` every factory once) as a gate before you start converting features, and again in Phase 6. Fix or flag what it reports **as its own commit, separate from the migration** — it is pre-existing app debt, and mixing it into the migration diff makes both harder to review.

**The inverse also bites: don't `create` a child the parent already builds.** When the model has a `has_one … required: true`, or a callback that builds the association, a faithfully-ported `create(:preference, user: alice)` produces a **second** row, and the app then reads an arbitrary one of the two — an order-dependent flake that was latent under Cucumber too. Port those steps as `alice.preference.update!(...)`, or give the factory an `initialize_with { user.preference || new(user:) }`. The app's own hand-written step definitions often already use the correct idiom — read `features/step_definitions/` before emitting a bare `create`.

---

## Scope & what to flag

This guide maps the cucumber_factory prose variations documented in its README. **Flag (don't guess)** when you
encounter:

- A step that **doesn't start with `there is` / `there are`, `"…" is a …`, or `the … (above|"…")  has/is …`** —
  it is not cucumber_factory. It's either an app-specific step (`features/step_definitions/`), a Spreewald step
  (see `spreewald-guide.md`), or a `cucumber_priority` override (convention #7).
- A `there is …` line you cannot parse into model + attributes (it may be an override).
- A bracketed `[…]` value where you can't tell whether the entries are record references or scalars — see the
  **Arrays / has_many** rule for the "was a matching record created earlier?" rule of thumb.

---

## Rules

### Basic creation

<rule id="create">
**Variation** — `there is a <model>` (the foundation; everything else adds to it).

**Intent** — Create one record with factory defaults.

**Mapping**
- before: `Given there is a movie`
- after: `create(:movie)`
- Machinist (legacy): `Movie.make`

**Notes** — `there is an …` (article "an") and `there are …` are the same step. Assign the result to a variable
when a later step references it (convention #2): `movie = create(:movie)`.
</rule>

### Scalar attributes

<rule id="attributes">
**Variation** — `… with the <attr> <value> [and the <attr> <value> …]` (join with `and`, `but`, or commas).

**Intent** — Set column values at creation.

**Mapping**
- before: `Given there is a movie with the title "Sunshine" and the year 2007`
- after: `create(:movie, title: 'Sunshine', year: 2007)`
- before: `And there is a director with the income "500000" but with the account balance "-30000"`
- after: `create(:director, income: '500000', account_balance: '-30000')`
- Machinist (legacy): `Movie.make(title: 'Sunshine', year: 2007)`

**Notes** — Quoted values are strings, unquoted numbers are numeric (convention #4); `but` and `,` are just
separators like `and`. Multi-word attribute names underscore (`account balance` → `account_balance`).
</rule>

### Boolean attributes

<rule id="booleans">
**Variation** — `… which/who/that is [not] <flag>` at creation; `… is [not] <flag>` when updating.

**Intent** — Set boolean columns. The word(s) after `is` become the attribute; `not` makes it `false`.

**Mapping**
- before: `Given there is a movie which is awesome, popular and successful but not science fiction`
- after: `create(:movie, awesome: true, popular: true, successful: true, science_fiction: false)`
- before: `And there is a cinema with the name "Starlight" which is not open on sundays`
- after: `create(:cinema, name: 'Starlight', open_on_sundays: false)`
- Machinist (legacy): `Cinema.make(name: 'Starlight', open_on_sundays: false)`

**Notes** — `which`, `who`, `that` are interchangeable. The flag phrase is underscored
(`open on sundays` → `open_on_sundays`). Combine freely with `with the …` scalar attributes in one call.
**Only the verb `is`/`is not` triggers the boolean clause.** A clause with any other verb (`which **may** stream online`, `who **can** edit`) is *not* parsed as a boolean — cucumber_factory swallows it in the trailing ` with the …` group and sets **nothing**. So before porting such prose as `may_stream_online: true`, confirm the origin step actually set the flag; a modal or non-`is` verb means it silently didn't, and reproducing it as `true` makes the spec stricter than the origin.
</rule>

### Attributes via table or doc string

<rule id="attribute-table">
**Variation** — `… with these attributes:` followed by a doc string (`key: value` lines) or a data table.

**Intent** — Set many attributes at once.

**Mapping**
- before:
  ```cucumber
  Given there is a movie with these attributes:
    | name   | Sunshine |
    | comedy | false    |
  ```
  (or the doc-string form with `name: Sunshine` lines)
- after: `create(:movie, name: 'Sunshine', comedy: false)`
- Machinist (legacy): `Movie.make(name: 'Sunshine', comedy: false)`

**Notes** — Each row/line is one attribute. Values are bare text → treat as **strings** unless they are
`true`/`false` (booleans), an array `[…]`, or `file:"…"`. The keys underscore like any attribute name. A step
may combine inline associations with a table (`with the prequel above and these attributes:`) — merge both into
one `create` call.
</rule>

### belongs_to / transient associations

<rule id="association-single">
**Variation** — `… with the <association> <reference>`, where `<reference>` is one of **three** forms:
- `above` — the last-created record of the associated class;
- `"<name>"` — a record given that explicit handle by a `"<name>" is a …` step;
- `"<value>"` / `<number>` — any string/number that was used as an **attribute value** when an earlier record
  was created (cucumber_factory remembers records under every string/integer attribute they were given —
  convention #2).

**Intent** — Set a `belongs_to` (or transient) association to a previously created record. All three forms
resolve to the **same thing in RSpec: the local variable holding that earlier record.**

**Mapping** — Resolve the reference to its local variable and pass it as a keyword argument:
- before (by `above`):
  ```cucumber
  Given there is a movie with the title "Before Sunrise"
  And there is a movie with the prequel above
  ```
- after:
  ```ruby
  before_sunrise = create(:movie, title: 'Before Sunrise')
  create(:movie, prequel: before_sunrise)
  ```
- before (by remembered attribute value): `And there is a movie with the prequel "Before Sunrise"`
- after: `create(:movie, prequel: before_sunrise)` *(same `before_sunrise` — it was remembered under its title)*
- before (by explicit handle):
  ```cucumber
  Given "BSR" is a movie
  And there is a movie with the prequel "BSR"
  ```
- after:
  ```ruby
  bsr = create(:movie)
  create(:movie, prequel: bsr)
  ```
- Machinist (legacy): `Movie.make(prequel: before_sunrise)`

**Notes** —
- **`above`** = the last-created record **of the associated class** (so `the place above and the user above` resolves to two *different* variables — the last place and the last user).
- **Never resolve a *named* reference (`"name"` / `"value"` / a handle) with `Model.last` — only the `above` form maps to "last record".** Use the local variable you hold from that record's earlier `create`. If you don't hold one (e.g. the record came from a `Background`, or isn't in this scenario), look it up **explicitly** — `User.find_by_anything('alice')` — not `Model.last`. Intervening factory steps routinely auto-create extra records of that class (a `create(:team)` builds an associated `User`), so `Model.last` silently grabs the wrong one — a bug that can still pass on a racy JS path. (`find_by_anything` is a makandra helper, **not** ActiveRecord — see [makandra card 6361](https://makandracards.com/makandra/6361-find-activerecord-column-useful-cucumber-steps); the app's Cucumber support may already define it, otherwise add it.)
- **A name-based lookup can collide with a factory-generated *attribute* of an unrelated record.** `find_by_anything('alice')` (and `cucumber_factory`'s own `the user "x"`) search across columns, so they can match a Faker/sequence-generated value on a record a *different* factory call created — e.g. a team's auto-built manager whose first name happens to be "Alice" vs. the user whose screen name is "alice" (and on MySQL the compare is case-insensitive, widening the collision). This surfaces as a "flaky" scenario that was really ambiguous all along. When the setup creates other records of that class, prefer the record's **unique** column (`User.find_by!(screen_name: 'alice')`) over a catch-all lookup.
- **`has_many`** is set from the child side (a `belongs_to` per child); the only parent-side form is the bracketed array (below).
- **Transient** association (a factory `transient` attribute naming a class/factory) → maps the same way, just a keyword argument.
- **Polymorphic** `belongs_to` can't use `above` (cucumber_factory raises) — such a step names the record explicitly; no special handling.
</rule>

### Arrays and has_many associations

<rule id="association-array">
**Variation** — `… with the <attr> ["a", "b" and "c"]` (square brackets, comma/`and`-separated).

**Intent** — Two distinct cases:
1. **has_many association** — the bracketed entries reference **records** created earlier.
2. **Array column** (e.g. PostgreSQL array) — the bracketed entries are **scalar values**.

**How to tell them apart (reliable rule):** an entry is a **record reference only if an earlier step created a
record carrying that exact string as an attribute value, or named it explicitly** (`"Sunshine" is a movie`).
If the bracketed strings match records you already created above, it's a has_many → use those local variables.
If they match nothing created earlier, they're plain scalars → an array column. (A record reference *must*
have an earlier record to point at; cucumber_factory would otherwise fail to resolve it — so "no earlier match"
unambiguously means scalars.) You can confirm against the model if in doubt, but the earlier-records signal is
usually enough.

**Mapping**
- before (has_many — referencing named movies):
  ```cucumber
  Given there is a movie with the title "Sunshine"
  And there is a movie with the title "Limitless"
  And there is a user with the favorite movies ["Sunshine", "Limitless"]
  ```
- after:
  ```ruby
  sunshine = create(:movie, title: 'Sunshine')
  limitless = create(:movie, title: 'Limitless')
  create(:user, favorite_movies: [sunshine, limitless])
  ```
- before (array column): `Given there is a movie with the tags ["comedy", "drama" and "action"]`
- after: `create(:movie, tags: ['comedy', 'drama', 'action'])`
- Machinist (legacy): same values; `User.make(favorite_movies: [sunshine, limitless])`. Note Machinist 1 can't
  build `has_many` inside a blueprint, but assigning a collection on `make` like this is fine.

**Notes** — An empty `[]` → `[]`. Mixed example:
`with the genres ["comedy", "drama"], languages []` → `genres: ['comedy', 'drama'], languages: []`.
For a large has_many of *anonymous* records, `create_list(:movie, 3)` is idiomatic, but the array form here
references *specific named* records, so list them explicitly.
</rule>

### File attributes

<rule id="file">
**Variation** — `… with the <attr> file:"<path>"` (single or double quotes; path relative to project root).

**Intent** — Set an attribute to a file object.

**Mapping** — Depends on what the attribute is:
- **A file-upload attribute** (Active Storage / CarrierWave / Shrine / Paperclip) — use the RSpec upload idiom
  seen in the apps:
  - before: `Given there is an attachment with the file file:"spec/fixtures/a_image.jpg"`
  - after: `create(:attachment, file: Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/a_image.jpg')))`
  - or, if the file lives under `spec/fixtures/files`: `fixture_file_upload('a_image.jpg')`
    (`fixture_file_upload` is provided by `ActionDispatch::TestProcess::FixtureFile`).
- **A plain file column / IO** — the faithful literal of what cucumber_factory does
  (`File.new("./path")`): `create(:doc, file: Rails.root.join('spec/assets/sample.pdf').open)`.
- Machinist (legacy): same value expression, `Attachment.make(file: Rack::Test::UploadedFile.new(...))`.

**Notes** — Prefer `Rack::Test::UploadedFile` / `fixture_file_upload` for genuine uploads (they set filename and content type, which `File.new` doesn't). If the app already defines an upload helper in `spec/support/` (e.g. `uploaded_file_fixture('image.jpg')`), reuse it. Anchor paths with `Rails.root.join`.
</rule>

### Named factories and traits

<rule id="traits">
**Variation** — `… (<variant>)` or `… (<trait1>, <trait2>)` in parentheses right after the model.

**Intent** — Use a FactoryBot trait or child factory (Machinist named blueprint).

**Mapping (FactoryBot) — default to traits.** The parens almost always mean **traits** on the factory named
after the model:
- before: `Given there is a movie (moody, dark) with the title "Interstellar"`
- after: `create(:movie, :moody, :dark, title: 'Interstellar')`

So convert `(a, b)` → `create(:model, :a, :b, …)` by default.

> **Minority case — child factory.** If the model has *no* factory of its own but the variant is itself a factory (no `:movie` factory, but a `:comedy` one), cucumber_factory uses the variant as the factory name: `there is a movie (comedy)` → `create(:comedy)`. **Default to the trait mapping; if verification fails with "trait/factory not registered", switch that step to `create(:comedy, …)`** (or check `spec/factories*`). Multiple comma-separated variants are always traits.

**Mapping (Machinist legacy)** — parens are a **named blueprint**, and Machinist supports **only one**:
- before: `Given there is a user (admin) with the email "a@b.c"`
- after: `User.make(:admin, email: 'a@b.c')`
- Multiple variants in parens are not expressible in Machinist 1 — flag it if you meet `(a, b)` in a Machinist app.

**Notes** — Variant names underscore like attributes (`for streaming` → `:for_streaming`). Example:
`there is a movie (moody, for streaming) with the genres ["drama"]` →
`create(:movie, :moody, :for_streaming, genres: ['drama'])`.
</rule>

### Named records (explicit handle)

<rule id="named-record">
**Variation** — `"<name>" is a <model> [with the … / which is …]` (single or double quotes).

**Intent** — Create a record **and** register it under an explicit handle for later reference. The handle is
**not** an attribute value.

**Mapping** — Use the handle as the variable name (convention #2):
- before:
  ```cucumber
  Given "Before Sunrise" is a movie
  And there is a movie with the prequel "Before Sunrise"
  ```
- after:
  ```ruby
  before_sunrise = create(:movie)
  create(:movie, prequel: before_sunrise)
  ```
- before (with attributes + trait + boolean): `And "Admin" is a user (admin) with the first name "Paul" who is active`
- after: `admin = create(:user, :admin, first_name: 'Paul', active: true)`
- Machinist (legacy): `before_sunrise = Movie.make`

**Notes** — Crucially, `"Before Sunrise"` here is **only a handle** — do **not** set it as `title` or any
attribute (contrast with `there is a movie with the title "Before Sunrise"`, where the string *is* the title
and *also* becomes a usable handle). Pick a readable snake_case variable name from the handle.
</rule>

### Updating an existing record

<rule id="update">
**Variation** — `the <model> (above|"<name>") has the <attr> <value> …` / `… is [not] <flag>` /
`… belongs to the <assoc> …` / `… has these attributes:`.

**Intent** — Modify a record created earlier.

**Mapping** — Reference the record's local variable (convention #2) and call `update!`:
- before:
  ```cucumber
  Given the movie above has the title "Sunset" and the year 2008
  ```
- after: `movie.update!(title: 'Sunset', year: 2008)`
- before (boolean update): `And the movie above is awesome but not popular`
- after: `movie.update!(awesome: true, popular: false)`
- before (by remembered name): `And the movie "Limitless" has the year 2009`
- after: `limitless.update!(year: 2009)`
- before (association update): `And the movie above belongs to the collection "Fantasy"`
- after: `movie.update!(collection: fantasy)` *(where `fantasy` is the collection record referenced by that handle)*
- before (table update): `And the movie above has these attributes:` + table → `movie.update!(name: 'Sunshine', comedy: false)`
- Machinist (legacy): identical — `movie.update!(...)` (plain ActiveRecord, gem-independent).

**Notes** — `the movie above` = the last-created movie's variable; `the movie "X"` = the variable for the
record named/remembered as `"X"`. `update!` (bang) mirrors cucumber_factory raising on invalid records. Boolean
and scalar updates can be combined: `has the year 1979 but is not science fiction` →
`update!(year: 1979, science_fiction: false)`.
</rule>

<!-- GUIDE-END -->
