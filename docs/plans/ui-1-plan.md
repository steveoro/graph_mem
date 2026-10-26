# UI-1 → graph_mem 1.56.0: app shell, design system, guest role, CSP enforced (one PR)

**Written 2026-10-26 (Europe/Rome)** for Claude, from `main` @ `d156fc9` (1.55.3, the chores PR #122 merged).
Every file:line below was checked against that commit. If a line has moved, find the code by the quoted
text; if the code no longer matches the description, **stop and ask Steve** instead of improvising.

Context: `ui-dashboard-plan.md` §2 (sections and the guest), §2.1 (sign-in, roles, enforcement), §3 (layout,
components, styling), §5.4 (role matrix) and §6 UI-1. This file **replaces** §6 UI-1 as the step list: where
the two differ, this file wins (the differences are listed under "Decisions (changeable)"). Everything here
is self-contained; you only need the other plan for background.

## Brief

| | |
|---|---|
| **Branch** | `claude/ui-1-1.56.0`, off current `main` (supersedes the `claude/ui-1-shell-roles` name in §6). |
| **PR** | Open **one PR against `main`**. Title: `UI-1: app shell, guest role (read-only), CSP enforced (1.56.0)`. Steve merges and tags; never merge, tag, push tags or run `rake release`. |
| **Commits** | In this order, so the PR can be split cleanly if Steve asks (see "Size and split"): **A1** shell + design system, **A2** CSP enforced, **B1** guest credentials + setting, **B2** guest login + enforcement + API, **B3** read-only graph + docs, **R** release (version, SKILL.md, CHANGELOG). Review fixes go in new commits; no force-push after review starts. |
| **Data** | Synthetic fixtures only (`SynthWidget`, `Alpha Service`). Never real credentials: specs use the synthetic `test_operator` / `test_secret` and a synthetic guest password. |
| **Credentials** | **Do not create, edit, decrypt or print `config/credentials.yml.enc` or any key file.** Steve adds the `guest:` entry himself after merge. Until then guest login is disabled, and the app must behave exactly as an operator-only app. |
| **Read first** | `CLAUDE.md`, `AGENTS.md`, `.devin/rules/*`, `ui-dashboard-plan.md` §0.1 (implementer brief: spec hygiene, test-DB truncate, done criteria). |

## What the code looks like today (verified at `d156fc9`)

- **Stack.** Rails 8.1.4, Haml 7.5 (haml-rails), importmap-rails 2.2.3, propshaft, turbo-rails 2.0.23,
  stimulus-rails 1.3.4 (`app/javascript/controllers/index.js` eager-loads every `*_controller.js`),
  tailwindcss-rails 4.6 (Tailwind v4; `app/assets/tailwind/application.css` is one line, `@import "tailwindcss";`),
  plus hand-written `app/assets/stylesheets/{dashboard,graph}.css` (1192 + 925 lines). Cytoscape 3.31.4 is
  vendored as ESM (`vendor/javascript/cytoscape.js-3.31.4-dist/`, no `eval`/`new Function`). CI does not run
  `tailwindcss:build` (`app/assets/builds/*` is git-ignored), so specs must never depend on Tailwind CSS.
- **Layout.** `app/views/layouts/application.html.haml` (43 lines): head with `csrf_meta_tags` + `csp_meta_tag`
  (8-9), three `stylesheet_link_tag`s (14-16), `javascript_importmap_tags` (17); a top nav only
  `- if operator_signed_in?` (19-38) built with `dashboard_topnav_icon_link` (`app/helpers/dashboard_helper.rb:236-247`)
  and plain links (Dashboard, Graph, Telemetry, Jobs) plus a `button_to "Sign out"`; `#flash-messages` rendering
  `layouts/_flash_messages` (39-41); `%main.container.mx-auto.mt-8.px-5.flex` (42). No auth layout.
  `DataExchangeController` (`app/controllers/data_exchange_controller.rb:336`) does
  `turbo_stream.update("flash-messages", partial: "layouts/flash_messages")`; `spec/requests/data_exchange_spec.rb:1590`
  asserts `target="flash-messages"`. `spec/requests/pages_spec.rb:27-32` asserts the `topnav-*` test ids,
  the `dashboard-topnav__link--icon` class and `aria-label="Search"`.
- **Auth.** `app/controllers/application_controller.rb` (86 lines): `include RoleAuthorization` (4),
  `before_action :set_current_actor` (9), `before_action :authenticate_operator!, unless: :operator_authentication_exempt?` (10),
  `helper_method :operator_signed_in?` (12), `SESSION_IDLE_TIMEOUT = 24.hours` / `SESSION_ABSOLUTE_TIMEOUT = 7.days` (14-15),
  `operator_username` / `operator_password` = ENV → credentials → `operator` / `changeme` (17-29),
  `set_current_actor` (33-41), `operator_signed_in?` (role `operator` or the legacy `operator_signed_in` key, 43-48),
  `authenticate_operator!` (50-57, stores `session[:operator_return_to]` on GET), `enforce_session_expiry!` (59-77),
  `operator_authentication_exempt?` = sessions#new/#create (79-81).
- **Roles.** `app/controllers/concerns/role_authorization.rb` (28 lines) only defines
  `class_attribute :_guest_allowed_actions, default: []` and `allow_guest` (appends, never mutates the parent;
  pinned by `spec/controllers/concerns/role_authorization_spec.rb`). **Nothing enforces it yet**, and nothing opts in.
- **Login.** `app/controllers/operator/sessions_controller.rb` (68 lines): `rate_limit to: 10, within: 3.minutes` (5-9);
  `new` redirects a signed-in operator to `/` and renders `fallback_credentials_error` (503) in production with
  the `changeme` password (11-22); `create` compares SHA-256 digests with `secure_compare` (30-39), then
  `reset_session` and sets `session[:role] = "operator"`, `:user`, `:signed_in_at`, `:last_seen_at` (40-48);
  `destroy` (55-58). Views: `app/views/operator/sessions/{new,fallback_credentials_error}.html.haml`, both
  rendered in the application layout today. Strings: `config/locales/operator_settings.en.yml:6-17`.
- **API auth.** `app/controllers/concerns/api_authentication.rb` (84 lines): `skip_before_action :authenticate_operator!`
  + `before_action :authenticate_api_request!` (18-19); operator session (with its own copy of the expiry
  check, 36-56) or a valid `GRAPH_MEM_MCP_TOKEN` bearer + IP policy (59-83); otherwise 401 (or 403 for a bad IP).
  `app/controllers/api/v1/base_controller.rb:26-29` overrides `verify_authenticity_token` using `session[:role]`.
- **Other operator-only gates (leave them operator-only).** `app/constraints/operator_session_constraint.rb:9`
  (the `/api-docs` mounts, `config/routes.rb:3-6`); `app/channels/application_cable/connection.rb:20-33`
  (already rejects a `guest` role, pinned by `spec/channels/application_cable/connection_spec.rb:36-41`);
  Mission Control at `/operator/jobs` (`config/routes.rb:146`, base controller
  `Operator::JobsDashboardController < ApplicationController`).
- **MCP.** `/mcp*` is Rack middleware (`config/initializers/mcp.rb`, `lib/graph_mem/official_mcp/access_gate.rb`):
  IP allowlist + optional bearer, applied before Rails routing. It never reads the session cookie.
- **CSP.** `config/initializers/content_security_policy.rb` (25 lines): `default_src :self`, `script_src :self` (10),
  `style_src :self, :unsafe_inline` (12), `connect_src :self, :ws, :wss` (13), `img_src :self, :data` (14),
  `object_src :none` (15), `frame_ancestors :none` (16), `report_uri "/csp-reports"` (17); nonce generator (20),
  `nonce_directives = %w[script-src]` (21), **`content_security_policy_report_only = true` (24)**. Reports go to
  `CspReportsController` (logs `"[CSP] violation report"` at warn) via `post "csp-reports"` (`config/routes.rb:18`).
- **CSP inventory (all checked):**
  - Inline scripts: **none** in `app/views`, helpers, controllers or `lib` (no `%script`, `:javascript`,
    `javascript_tag`, `<script>`); `spec/inline_scripts_spec.rb` already guards this. `javascript_importmap_tags`
    and `csp_meta_tag` emit the nonce. Mission Control 1.3.1's layout uses `csp_meta_tag` +
    `javascript_importmap_tags` and its views have no inline scripts or `on*=` attributes.
  - Inline `on*=` HTML attributes: **none**. JS assigns handlers as properties (`btn.onclick = …` in
    `graph_controller.js`, `graph/context_menu.js`, `graph/drag_drop_manager.js`, `graph/modal_manager.js`):
    allowed under CSP.
  - `eval` / `new Function` / string `setTimeout`: none in app JS or vendored Cytoscape.
  - Inline `style=` attributes (need `style-src 'unsafe-inline'`, which stays): `app/views/pages/_graph_explorer.html.haml:1-2`;
    `app/views/pages/dashboard/_project_scan_skill_companion_card.html.haml:32,34,36`; `layouts/mailer.html.haml:5`
    (email only). CSSOM writes (`el.style.x = …`) in `graph/tooltip.js`, `graph/context_menu.js`,
    `graph/drag_drop_manager.js`, `graph_controller.js:28`, `operation_progress_controller.js:44` are not
    governed by CSP. Turbo's progress bar injects a `<style>`: covered by `'unsafe-inline'` (style-src has no nonce).
  - Third-party assets: none (no CDN, no web fonts). `public/*.html` error pages have no scripts.
  - `/api-docs` (rswag-ui) serves inline scripts and Google Fonts, but rswag sets its **own**
    `Content-Security-Policy` header on that response, and Rails' CSP middleware leaves a response alone when
    one is already present. So enforcement does not touch `/api-docs`; the spec below pins that.
- **Credentials.** `config/credentials.yml.enc` exists; there is no `config/master.key` in the repo, so in CI
  `Rails.application.credentials.dig(...)` returns `nil`. On Steve's machine it may decrypt, so **specs must stub
  the guest credential source** (step B1) and never rely on what the real file contains.
- **Settings.** `app/models/app_settings.rb`: `field :name, default:, type: :boolean` (lines 8-11 for flags),
  uncached readers via the private `read_boolean_setting(var, default:)` (line 175). The Settings page renders
  every field of a group generically (`app/views/operator/settings/index.html.haml:40-52` for booleans); groups are
  in `Operator::SettingsController#settings_groups` (`app/controllers/operator/settings_controller.rb:130-133` for
  `feature_flags`); labels in `config/locales/operator_settings.en.yml` under `operator.settings.fields.<key>`.
- **Graph page JS.** `/graph` (`PagesController#graph`, view `app/views/pages/graph.html.haml`, canvas partial
  `pages/_graph_explorer.html.haml`) reads only `GET /api/v1/graph_data`, `GET /api/v1/memory_entities/:id/memory_observations`
  (`graph/api_client.js:14-35`). Writes come only from the context menu (`graph/context_menu.js`: Edit data /
  Delete on nodes, lines 36-39; Edit Type / Delete Relation on edges, 93-94; the "delete duplicate observations"
  button wired at 186) and from drag-and-drop (`graph/drag_drop_manager.js`, initialised at
  `graph_controller.js:155`; merge / alias / create relation, lines 203-254).

## Scope

**In UI-1:**
1. **Shell:** new application layout (sidebar nav with role-aware items, review-backlog badge, skip link,
   toast region, page-header slot), a separate `auth` layout for sign-in, shared head partial.
2. **Design system (minimum):** Tailwind v4 `@theme` tokens + a small `@layer components` set (`.ui-btn`,
   `.ui-btn-primary`, `.ui-btn-danger`, `.ui-input`, `.ui-badge`, `.ui-card`, plus the shell classes), `UiHelper`
   (`can_write?`, `ui_nav_link`, `ui_page_header`, `ui_review_backlog_count`), partials `ui/_sidebar`,
   `ui/_page_header`, `ui/_toasts`, Stimulus `nav_controller.js` and `toast_controller.js`, `config/locales/ui.en.yml`.
3. **Guest role:** read-only, server-side, deny-by-default, exactly as `ui-dashboard-plan.md` §2.1 with the
   deviations listed under Decisions. Disabled unless a guest password is configured (ENV or credentials).
4. **CSP enforced** (report-only off), with `base-uri 'self'` and `form-action 'self'` added.
5. Docs, release 1.56.0.

**Out of scope (do not do here):**
- Section URLs (`/explore`, `/review`, `/projects`, `/system`) and 301 redirects from old URLs: each later UI PR adds
  its own section route when it builds the page (Decision 1).
- Rewriting page content: every existing page renders inside the shell **unchanged** (apart from the removal of the
  global flex `main` and the graph read-only switch). Home is UI-2, Search UI-3, Explore UI-4b, Review UI-5,
  Projects & Data UI-6, System and Settings › Access UI-7, dark mode and palette UI-8.
- `ui/_table`, `ui/_filter_bar`, the Kaminari `ui` theme, `ui/_confirm`, `ui/_empty`, `ui/_skeleton`, `ui/_error`,
  `ui/_progress`, `ui_stat`/`ui_health_pill`, `ui_entity_link`: added by the first PR that uses them (Decision 2).
- Tightening `style-src` (dropping `'unsafe-inline'`): UI-8 (Decision 4).
- Deleting `dashboard.css` / `graph.css` rules: UI-7. Leave the old `.dashboard-topnav*` CSS in place even if unused.
- Operator timeouts, the operator `changeme` rule, the login rate limit, ActionCable, `/api-docs`, MCP: unchanged.

## A1. Shell and design system

1. **Shared head.** New `app/views/layouts/_head.html.haml` with lines 4-17 of the current layout (title, metas,
   `csrf_meta_tags`, `csp_meta_tag`, `yield :head`, icons, the three `stylesheet_link_tag`s,
   `javascript_importmap_tags`). Both layouts render it.
2. **`app/views/layouts/application.html.haml`** (rewrite, keep under ~60 lines):
   - `%body.ui-body`; first child a skip link `%a.ui-skip-link{ href: "#main" }= t("ui.skip_link")`.
   - `- if signed_in?` → `.ui-shell` containing `= render "ui/sidebar"` and `.ui-shell__content`;
     otherwise just `.ui-shell__content` (pages that can render signed out, e.g. a 403 page after expiry).
   - Inside `.ui-shell__content`: `= render "ui/toasts"`, then `%main#main.ui-main{ tabindex: "-1" }` with
     `= yield(:page_header) if content_for?(:page_header)` and `= yield`.
   - **Drop** `.container.mx-auto.mt-8.px-5.flex`; `.ui-main` gives padding and a max width
     (`ui-dashboard-plan.md` §3.1). Check every page visually (list under "Manual checks"); if a page relied on the
     flex row, fix it with a class on that page's root, not by restoring the global flex.
3. **`app/views/layouts/auth.html.haml`** (new): `= render "layouts/head"`, `%body.ui-body.ui-auth`,
   `= render "ui/toasts"`, `%main#main.ui-auth__main= yield`. `Operator::SessionsController` gets `layout "auth"`.
   `operator/sessions/new.html.haml` and `fallback_credentials_error.html.haml` keep their markup (they may swap
   `dashboard-*` classes for `.ui-*`, optional).
4. **`app/views/ui/_sidebar.html.haml`** (new) - `%nav.ui-sidebar{ "aria-label": t("ui.nav.label"), data: { controller: "nav" } }`:
   brand + version (link to `root_path` for operators, `search_path` for guests); a toggle button for small screens
   (`data-action="nav#toggle"`, `aria-expanded`, `aria-controls`); the item list; at the bottom the user/role line
   (guests see a `.ui-badge` "Read-only guest") and the existing `button_to` Sign out
   (keep `id`/`data-testid` `btn-operator-logout`). Items use `ui_nav_link(label, path, testid:, icon: nil, badge: nil)`,
   which sets `aria-current="page"` when `current_page?(path)` and renders the existing `dashboard_icon` SVG when given.
   Groups and items (existing URLs only, Decision 1):

   | Group (heading) | Item → path | testid | Who |
   |---|---|---|---|
   | (none) | Home → `root_path` | `nav-home` | operator |
   | (none) | Search → `search_path` (icon `:search`) | `nav-search` | both |
   | (none) | Explore → `graph_path` | `nav-explore` | both |
   | Review & Fix | Compaction review → `compaction_review_data_exchange_index_path` (badge) | `nav-review` | operator |
   | Review & Fix | Scan review → `compaction_review_data_exchange_index_path(report_type: "scan_review")` | `nav-scan-review` | operator |
   | Projects & Data | Maintenance (import, export, cleanup) → `maintenance_path` (icon `:maintenance`) | `nav-maintenance` | operator |
   | System | Embeddings → `operator_embeddings_path` | `nav-embeddings` | operator |
   | System | Telemetry → `operator_telemetry_path` | `nav-telemetry` | operator |
   | System | Audit log → `operator_audit_logs_path` | `nav-audit-logs` | operator |
   | System | Settings → `operator_settings_path` (icon `:settings`) | `nav-settings` | operator |
   | System | Jobs → `"/operator/jobs"` | `nav-jobs` | operator |
   | System | API docs → `"/api-docs"` | `nav-api-docs` | operator |

   Use `- if can_write?` around every operator-only item and group. Labels live in `config/locales/ui.en.yml`
   (`ui.nav.*`). Badge: `ui_review_backlog_count` (below); render nothing when 0.
5. **`app/views/ui/_toasts.html.haml`** (new): `#toasts.ui-toasts{ "aria-live": "polite", role: "status", data: { controller: "toast" } }`
   wrapping `= render "layouts/flash_messages"`. Change `layouts/_flash_messages.html.haml` to render each message as
   `.ui-toast.ui-toast--notice|--alert{ data: { toast_target: "item" } }` with the text and a dismiss button
   (`%button{ type: "button", "aria-label": t("ui.toasts.dismiss"), data: { action: "toast#dismiss" } } ×`).
   Keep the existing keys (`notice`, `alert`, `error` falling back into alert). Keep `.dashboard-flash*` classes on the
   same elements too so no old CSS-dependent spec breaks (optional; remove if no spec needs them).
   **Rename the Turbo Stream target:** `data_exchange_controller.rb:336` `"flash-messages"` → `"toasts"`;
   `spec/requests/data_exchange_spec.rb:1590` `target="flash-messages"` → `target="toasts"`.
6. **`app/views/ui/_page_header.html.haml`** + `ui_page_header(title, subtitle: nil, &actions)` in `UiHelper`
   (`%header.ui-page-header` with one `h1`, optional subtitle, optional actions slot). Used in UI-1 only by the 403 page
   (B2 step 6); later PRs adopt it page by page.
7. **Stimulus** (`app/javascript/controllers/`, picked up automatically by `pin_all_from` + `eagerLoadControllersFrom`):
   - `nav_controller.js`: `toggle()` flips a `ui-sidebar--open` class and `aria-expanded`; `Escape` closes.
   - `toast_controller.js`: target `item`; `itemTargetConnected(el)` schedules auto-dismiss after 6 s for
     `.ui-toast--notice` only (alerts stay until dismissed); `dismiss(event)` removes the closest item. No
     `innerHTML`, no `alert()`/`confirm()`. Works for toasts added later by Turbo Streams (the target callback fires).
8. **`app/assets/tailwind/application.css`**: after `@import "tailwindcss";` add an `@theme` block (status colours,
   surface/border/text colours, radius, sidebar width) and `@layer components` with `.ui-body`, `.ui-shell`,
   `.ui-shell__content`, `.ui-main`, `.ui-sidebar` (+ `--open`, item, group heading, active state on
   `[aria-current="page"]`, badge), `.ui-skip-link`, `.ui-toasts`, `.ui-toast` (+ modifiers), `.ui-page-header`,
   `.ui-auth`, `.ui-btn`, `.ui-btn-primary`, `.ui-btn-danger`, `.ui-input`, `.ui-badge`, `.ui-card`, and visible focus
   rings. Sidebar ≥1024 px; a top bar with the toggle below that. **Every new class starts with `ui-`** so nothing
   collides with `dashboard.css` (`ui-dashboard-plan.md` §3 risk). Run `bin/rails tailwindcss:build` locally for
   screenshots; CI doesn't build it, so no spec may assert on computed styles.
9. **`app/helpers/ui_helper.rb`** (new, < 120 lines): `can_write?` (= `operator_signed_in?`; cosmetic only, the
   guarantee is server-side), `ui_nav_link`, `ui_page_header`, `ui_review_backlog_count`
   (`Rails.cache.fetch("ui/review_backlog_count", expires_in: 30.seconds) { MaintenanceReportRow.active.count }`,
   returns 0 for guests without querying).
10. **Remove the old top nav helper** once unused: `dashboard_topnav_icon_link` (`dashboard_helper.rb:236-247`) and its
    spec block (`spec/helpers/dashboard_helper_spec.rb:16-~31`). Keep `dashboard_icon` (the sidebar uses it).
11. **Update `spec/requests/pages_spec.rb:27-32`**: assert the sidebar instead (`data-testid="nav-search"`,
    `nav-maintenance`, `nav-telemetry`, `nav-settings`, `aria-current="page"` on Home, `aria-label="Search"`
    still present if you keep an icon-only element; otherwise drop that line).

## A2. CSP enforced

`config/initializers/content_security_policy.rb`:
- line 24: `config.content_security_policy_report_only = true` → **delete the line** (enforced is the default);
  update the comments at lines 3 and 23 ("enforced since UI-1 / 1.56.0").
- add `policy.base_uri :self` and `policy.form_action :self` (Decision 3). Keep `report_uri "/csp-reports"`,
  the nonce generator and `nonce_directives = %w[script-src]` unchanged. Keep `style_src :self, :unsafe_inline` (Decision 4).
- comments only: `config/routes.rb:17` and `app/controllers/csp_reports_controller.rb:3` ("report-only in UI-0") →
  "violation reports (CSP enforced since 1.56.0)".

**CSP migration checklist** (tick each in the PR body):
- [ ] No inline `<script>` / `:javascript` / `javascript_tag` (already true; `spec/inline_scripts_spec.rb` green).
- [ ] No `on*=` HTML attributes in `app/views` (`rg -n " on[a-z]+=" app/views` finds nothing).
- [ ] Every `<script>` in a rendered page carries the request nonce (request spec below).
- [ ] No `eval`/`new Function`/string timers in `app/javascript` (`rg -n "eval\(|new Function|setTimeout\(['\"]" app/javascript`).
- [ ] No third-party script/style/font/image URLs in app views and layouts.
- [ ] Turbo navigation keeps working (new nonce per page via `csp_meta_tag`); Turbo progress bar shows without a violation.
- [ ] Mission Control `/operator/jobs` loads and its buttons work (it uses the nonce).
- [ ] `/api-docs/index.html` still loads with rswag's own CSP header (unchanged by Rails).
- [ ] `/graph` renders the canvas, tooltip, context menu and modals; drag-and-drop works for the operator.
- [ ] Zero CSP console errors on every page in the system spec, and no `[CSP] violation report` lines in
      `log/test.log` / `log/development.log` after the manual pass.

**Specs:**
- `spec/requests/content_security_policy_spec.rb` (new): signed in as operator, `GET /`, `/search`, `/graph`,
  `/maintenance`, `/operator/settings`, `/operator/telemetry`, `/data_exchange/compaction_review`:
  the response has `Content-Security-Policy` (and **no** `Content-Security-Policy-Report-Only`) containing
  `script-src 'self' 'nonce-`, `object-src 'none'`, `frame-ancestors 'none'`, `base-uri 'self'`, `form-action 'self'`,
  `report-uri /csp-reports`; parse the body with Nokogiri and assert every `script` element has a `nonce` equal to
  the one in the header. Signed out, `GET /operator/login` has the same header. As operator,
  `GET /api-docs/index.html` returns 200 and its `Content-Security-Policy` still contains `'unsafe-inline'` in
  `script-src` (rswag's header, untouched).
- `spec/system/content_security_policy_spec.rb` (new, headless Chrome): visit, as operator, Home, Search (with a
  query), Explore (wait for the canvas `canvas` element), Maintenance, Compaction review, Scan review, Embeddings,
  Telemetry, Audit log, Settings, Jobs; and as guest (B2), Search and Explore. After each visit collect the browser
  log and assert no entry matches `/Content Security Policy/i`. Setup in `spec/support/system.rb` (new):
  ```ruby
  RSpec.configure do |config|
    config.before(:each, type: :system) do
      driven_by :selenium, using: :headless_chrome, screen_size: [ 1280, 800 ] do |options|
        options.add_option("goog:loggingPrefs", { browser: "ALL" })
      end
    end
  end
  ```
  and a helper `csp_console_errors = page.driver.browser.logs.get(:browser).map(&:message).grep(/Content Security Policy/i)`
  (reading the log clears it). `spec/system/escaping_spec.rb:23-25` keeps its own `driven_by`; it may switch to the
  shared one. If the Selenium logs API is unavailable in this driver version, stop and ask Steve rather than
  dropping the browser check.
- **Browser check (manual, record in the PR body):** `bin/dev`, sign in, open DevTools → Console with "Preserve log",
  click through every nav item and the graph context menu; there must be no "Refused to …" messages. In the Network tab,
  the document response shows `Content-Security-Policy` (not `-Report-Only`). `grep "\[CSP\] violation report" log/development.log`
  finds nothing new.

## B1. Guest credentials and the toggle

1. **`lib/graph_mem/guest_credentials.rb`** (new, < 120 lines), `GraphMem::GuestCredentials`:
   - `self.resolve(env: ENV, credentials: credentials_store)` → frozen value object with `username`, `password`:
     username = `env["GRAPH_MEM_GUEST_USERNAME"].presence || credentials.dig(:guest, :username).presence || "guest"`;
     password = `env["GRAPH_MEM_GUEST_PASSWORD"].presence || credentials.dig(:guest, :password).presence`.
     Blank ENV (docker-compose passes `""`) falls through to credentials. **No default password anywhere.**
   - `self.credentials_store` = `Rails.application.credentials`; rescue
     `ActiveSupport::MessageEncryptor::InvalidMessage` / `ActiveSupport::EncryptedFile::MissingKeyError` → `{}` with
     one warn log (an unreadable credentials file means "not configured", never a crash).
   - `self.current` memoises `resolve` (resolved once per process, as in §2.1: a rotated password takes effect after
     the restart); `self.reset!` clears it (specs).
   - instance: `configured?` (password present); `collides_with_operator?` (username equals
     `ApplicationController.operator_username` **or** password equals `ApplicationController.operator_password`,
     both with `secure_compare` on SHA-256 digests); `available?` = `configured? && !collides_with_operator? &&
     AppSettings.guest_access_enabled?`; `fingerprint` = first 32 hex chars of
     `OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base, "#{username}\0#{password}")` (Decision 7);
     `status` → `:not_configured`, `:conflict`, `:disabled`, `:available`.
   - `inspect`/`to_s` must not include the password.
2. **`config/initializers/guest_access.rb`** (new): `Rails.application.config.after_initialize` logs once:
   info `"[guest access] not configured (no guest password)"` or `"[guest access] configured"`; error
   `"[guest access] disabled: guest username or password equals the operator's"` on a collision. **No DB access at
   boot** (don't read the toggle here) and never log the values.
3. **`app/models/app_settings.rb`**: add `field :enable_guest_access, default: true, type: :boolean` next to the
   feature flags (after line 11) and `def self.guest_access_enabled? = read_boolean_setting("enable_guest_access", default: true)`
   next to the other readers (around line 140). Add `enable_guest_access` to the `feature_flags` group
   (`settings_controller.rb:132`) and a label/description under `operator.settings.fields` in
   `config/locales/operator_settings.en.yml`: label "Guest access (read-only)", description "Lets the guest account
   sign in. Has no effect until a guest password is set in GRAPH_MEM_GUEST_PASSWORD or the Rails credentials
   (guest.password)." (Decision 6; UI-7 moves it to Settings › Access with a status line.)
4. **`docker-compose.yml`**: after line 37 add `GRAPH_MEM_GUEST_USERNAME: ${GRAPH_MEM_GUEST_USERNAME:-}` and
   `GRAPH_MEM_GUEST_PASSWORD: ${GRAPH_MEM_GUEST_PASSWORD:-}`. **`.env.example`**: commented `# GRAPH_MEM_GUEST_USERNAME=guest`
   and `# GRAPH_MEM_GUEST_PASSWORD=` with a one-line note (blank = guest disabled).
5. **Spec support** (`spec/support/operator_auth_helpers.rb`): in the existing `before(:each, type: :request)` (and a
   matching `type: :system` hook) delete both guest ENV vars, stub
   `allow(GraphMem::GuestCredentials).to receive(:credentials_store).and_return({})` and call
   `GraphMem::GuestCredentials.reset!` (also in an `after`). Add `TEST_GUEST_PASSWORD = "synthetic-guest-secret"`,
   `enable_guest!(username: nil)` (sets the ENV password, optional username, `reset!`) and
   `sign_in_guest` (posts the guest credentials to `operator_session_path`).
6. **`spec/lib/graph_mem/guest_credentials_spec.rb`** (new): resolution order (ENV over credentials, for each field);
   blank ENV falls through; nothing configured → `configured? == false`, username `"guest"`; collision on username or
   on password → `:conflict`; toggle off → `:disabled`; fingerprint changes when the password changes and never
   contains the password; an unreadable credentials store → not configured; `rg`-style check that the source has no
   string literal used as a default password (assert `resolve(env: {}, credentials: {}).password` is `nil`).

## B2. Guest login, enforcement, API

1. **`ApplicationController`** (keep the file under ~150 lines; move session helpers to a concern
   `app/controllers/concerns/session_authentication.rb` if it grows):
   - line 10 → `before_action :authenticate!, unless: :authentication_exempt?` followed by
     `before_action :authorize_role!, unless: :authentication_exempt?` (rename `operator_authentication_exempt?` →
     `authentication_exempt?`, same body).
   - add `GUEST_IDLE_TIMEOUT = 2.hours`, `GUEST_ABSOLUTE_TIMEOUT = 24.hours` below lines 14-15 (operator values unchanged, Decision 8).
   - `current_role` → `"operator"` (role `operator` or the legacy key), `"guest"` (role `guest`), else `nil`;
     `operator_signed_in?` keeps its meaning; add `guest_signed_in?` and `signed_in?`;
     `helper_method :operator_signed_in?, :guest_signed_in?, :signed_in?, :current_role`.
   - `authenticate!` (replaces `authenticate_operator!`): no role → store `operator_return_to` on GET, redirect to login
     with `login_required` (as today); operator → `enforce_session_expiry!` with the operator limits; guest →
     `guest_session_valid?` else `reset_session` + redirect to login with the new `operator.sessions.guest_disabled`
     ("Guest access is disabled."), then expiry with the guest limits. Parameterise `enforce_session_expiry!(idle:, absolute:)`.
   - `guest_session_valid?` (shared with the API): `GuestCredentials.current.available?` **and**
     `secure_compare(session[:guest_cred_fp].to_s, GuestCredentials.current.fingerprint)`.
   - `set_current_actor` (33-41): add a guest branch `"guest:#{session[:user]}@#{request.remote_ip}"` (guests never write).
2. **`RoleAuthorization`** (`role_authorization.rb`): update the header comment (no longer a skeleton) and add
   ```ruby
   def authorize_role!
     return unless guest_signed_in?
     return if self.class._guest_allowed_actions.include?(action_name)
     render_guest_forbidden
   end
   ```
   `render_guest_forbidden`: JSON requests (`request.format.json?` or `Accept` JSON) →
   `render json: { error: "forbidden", role: "guest" }, status: :forbidden`; everything else (HTML, Turbo Stream,
   downloads) → `render "shared/forbidden", status: :forbidden, formats: :html` in the application layout.
   Deny by default: a controller with no `allow_guest` is operator-only.
3. **Opt-ins** (the complete list; the route-matrix spec pins it):
   - `SearchController`: `allow_guest :results`.
   - `PagesController`: `allow_guest :home, :graph`; `home` starts with `redirect_to search_path and return if guest_signed_in?`.
   - `Operator::SessionsController`: `allow_guest :destroy` (`new`/`create` are exempt from both callbacks).
4. **`Operator::SessionsController`**:
   - `layout "auth"`.
   - `new` line 12: operator → `root_path` (as now); guest → `search_path`.
   - `create` (30-52): compute the operator match exactly as now; then the guest match with the same digest +
     `secure_compare` pattern against `GuestCredentials.current` when `available?`, or against two fresh
     `SecureRandom.hex(32)` values when not (same work either way, so timing doesn't reveal whether a guest exists).
     Use `&` (not `&&`) as line 40 does. Operator match wins. On a guest match: `reset_session`, then
     `session[:role] = "guest"`, `:user`, `:signed_in_at`, `:last_seen_at`, `:guest_cred_fp = fingerprint`, redirect to
     `search_path` (honour `operator_return_to` only when it starts with `/search` or `/graph`, Decision 9). No match
     → the same generic `invalid_credentials` 422 as today. Extract `start_session!(role:, user:)` so `create` stays short.
   - The production `changeme` 503 (14-21, 25-28) stays operator-only and unchanged.
5. **`ApiAuthentication`** (`api_authentication.rb`):
   - lines 18-19 → `skip_before_action :authenticate!`, `skip_before_action :authorize_role!`,
     `before_action :authenticate_api_request!`.
   - add `GUEST_READ_ACTIONS = %w[api/v1/graph_data#index api/v1/memory_entities#index api/v1/memory_entities#show
     api/v1/memory_entities#search api/v1/memory_observations#index api/v1/memory_observations#show
     api/v1/memory_relations#index api/v1/memory_relations#show api/v1/search#subgraph
     api/v1/graph_traversal#traverse api/v1/graph_traversal#shortest_path].freeze` (keyed by `"#{controller_path}##{action_name}"`).
   - `authenticate_api_request!`: operator session → pass; valid bearer → pass; guest session
     (`session[:role] == "guest"`, `guest_session_valid?`, guest expiry) → pass for `GUEST_READ_ACTIONS`, else
     `render json: { error: "forbidden", role: "guest" }, status: :forbidden`; an invalid/expired guest session →
     `reset_session` and the 401 path; nothing → 401 as now. Reuse the ApplicationController expiry helper instead
     of the duplicated block at 36-56 if that stays readable.
   - update the header comment (lines 3-11).
6. **`app/views/shared/forbidden.html.haml`** (new): `ui_page_header(t("ui.forbidden.title"))`, one paragraph
   (`ui.forbidden.body`: "This page needs the operator account. You are signed in as a read-only guest."), a link to Search.
7. **Leave unchanged** (and pin in specs): `OperatorSessionConstraint` (guests get 404 on `/api-docs`, Decision 10),
   `ApplicationCable::Connection` (rejects guests), Mission Control (403 via `authorize_role!`, because its base
   controller inherits from `ApplicationController`), `/mcp*`.

**Specs:**
- `spec/requests/role_matrix_spec.rb` (new, the guarantee): iterate `Rails.application.routes.routes`; skip routes
  whose `app` is an engine/mounted Rack app (tested by path below) and internal `rails/*` routes except `/up`; for each
  remaining verb + path build a request with dummy segments (`:id`, `:target_id`, `:memory_entity_id` → `"1"`, drop
  `(.:format)`); then, with `enable_guest!` + `sign_in_guest`, assert:
  - routes in `GUEST_ALLOWED` (a constant in the spec: `GET /search`, `GET /graph`, `GET /` → 302 `/search`,
    `DELETE /operator/logout` → 302 login, `GET|POST /operator/login`, `POST /csp-reports` → 204, `GET /up`, and the
    eleven `GUEST_READ_ACTIONS` → not 401/403, 404 for a dummy id is fine) behave as listed;
  - **every other route returns 403** (`/api/v1/*` with the JSON body `{"error":"forbidden","role":"guest"}`;
    HTML routes with the forbidden page) and **no record is created, changed or deleted** (wrap each mutating verb
    in `expect { … }.not_to change { [MemoryEntity.count, MemoryObservation.count, MemoryRelation.count,
    AuditLog.count, MaintenanceReportRow.count] }`, with one synthetic entity/observation/relation created first);
  - signed out: HTML routes → 302 to `/operator/login`, `/api/v1/*` → 401.
  - mounted apps by path: guest `GET /operator/jobs` → 403, `GET /api-docs/index.html` → 404, operator → 200 for both.
  - a guard example: the number of routes checked is > 60, so a broken iterator can't pass vacuously.
- `spec/requests/operator/guest_login_spec.rb` (new): with nothing configured, `guest` + any password (including
  `guest` and blank) → 422 generic error and the page has no guest wording; ENV password set → login works with the
  toggle at its default, redirects to `/search`, the nav shows Search/Explore/Sign out and the read-only badge only;
  credentials-only (stub `credentials_store` to `{ guest: { password: "…" } }`) → works; ENV wins over credentials;
  toggle off (`AppSettings.enable_guest_access = false`) → the next request logs the guest out with "Guest access is
  disabled." and login is refused; guest username or password equal to the operator's → refused; changing the
  configured password + `reset!` → the existing guest session is logged out; guest idle > 2 h or absolute > 24 h
  (`travel`) → expired; operator login and its 24 h/7 d limits unchanged; production `changeme` 503 unchanged;
  rate limit still applies to guest attempts.
- `spec/requests/api/v1/guest_access_spec.rb` (new): as guest, each `GUEST_READ_ACTIONS` route → 200 with synthetic
  data; `POST /api/v1/memory_entities`, `PATCH`/`DELETE /api/v1/memory_entities/:id`, `POST …/merge_into/:target_id`,
  `POST /api/v1/memory_relations`, `DELETE …/memory_observations/delete_duplicates`, `POST /api/v1/search/subgraph_by_ids`,
  `POST /api/v1/summarize`, `POST /api/v1/scan`, `POST /api/v1/bulk`, `GET|POST|DELETE /api/v1/context`,
  `GET /api/v1/maintenance/stats` → 403 JSON, records unchanged; a guest session **plus** a valid bearer token →
  full access (the token is the owner's machine credential); an expired guest session → 401.
- **MCP** (add to `spec/requests/mcp_official_spec.rb` or a new `spec/requests/mcp_guest_session_spec.rb`): with
  `GRAPH_MEM_MCP_TOKEN` set (`with_env`, see line 166 of that spec) and `GraphMem::OfficialMcp.reset!`, a guest session
  cookie and no `Authorization` header → `POST /mcp` (a `tools/call` for a write tool) is 401 and nothing changes;
  same for `/mcp/readonly`. The session never grants MCP access.
- `spec/channels/application_cable/connection_spec.rb`: the existing guest-rejection example stays green (no change).
- `spec/controllers/concerns/role_authorization_spec.rb`: add `authorize_role!` examples (operator passes, guest with an
  opted-in action passes, guest otherwise gets 403 JSON/HTML).
- `spec/helpers/ui_helper_spec.rb` (new): `can_write?` true for operator, false for guest and signed out;
  `ui_nav_link` sets `aria-current="page"` only on the current path and escapes the label; the badge count is cached
  and 0 for guests.
- `spec/system/navigation_spec.rb` (new): operator sees Home, Search, Explore and the three groups with all items, each
  link loads (status 200 page, no exception), `aria-current` follows the page, the toggle button flips `aria-expanded`;
  a notice toast appears after sign-in and can be dismissed; guest sees only Search, Explore, the badge and Sign out,
  `/graph` renders without edit items in the context menu (B3), and visiting `/maintenance` shows the 403 page.

## B3. Read-only graph, docs

1. **`pages/_graph_explorer.html.haml:1`**: add `graph_read_only_value: !can_write?` to the `data:` hash.
   **`graph_controller.js`**: `static values = { readOnly: Boolean }`; pass `{ readOnly: this.readOnlyValue }` as a
   4th argument to `new ContextMenuManager(...)` (line 25); when read-only, don't create/initialise the
   `DragDropManager` (lines 26 and 155). **`graph/context_menu.js`**: accept `{ readOnly = false } = {}`; when
   read-only, omit the items with action `edit`, `delete` (node, lines 36 and 39) and `edit-type`, `delete` (edge,
   93-94), and remove (don't wire) the delete-duplicates button in the observations modal (line 186). View-only items
   (show observations, toggle relations/observations) stay. Cosmetic only: the API refuses guest writes anyway.
   **`pages/graph.html.haml:13`**: show the "Back to dashboard" link only `- if can_write?`.
   `spec/system/escaping_spec.rb` must stay green (it runs as operator).
2. **Docs:**
   - `README.md:565`: add a guest paragraph (read-only account, disabled until `GRAPH_MEM_GUEST_PASSWORD` or
     credentials `guest.password` is set; username defaults to `guest`; must differ from the operator's; the
     Settings toggle "Guest access"; a guest can read all graph content, no per-project scoping; no MCP access).
     Env table after line 585 (`GRAPH_MEM_MCP_ALLOWED_IPS`): `GRAPH_MEM_GUEST_USERNAME` (`guest`) and `GRAPH_MEM_GUEST_PASSWORD` (--, blank = disabled).
   - `docs/app_settings_reference.md`: add `enable_guest_access` to the Feature Flags table (line 11 onwards) and mention
     the guest login next to the auth line (8).
   - `docs/mcp_access_control.md`: one short paragraph: `/api/v1` accepts a guest session for the read actions only
     (list), everything else 403; `/mcp*` ignores browser sessions entirely.
   - `docs/architecture.md`: if it describes the auth flow or the CSP mode, update it (enforced, guest role).

## Release: 1.56.0 (commit R)

- `lib/graph_mem/version.rb:4`: `VERSION = "1.55.3"` → `"1.56.0"`.
- `skills/graph-mem-mcp-toolset/SKILL.md:18`: `graph-mem-version: "1.55.3"` → `"1.56.0"`
  (`spec/docs/agent_text_sync_spec.rb:193` checks they match).
- `CHANGELOG.md`: under the empty `## [Unreleased]` (line 8) add `## [1.56.0] - <merge date>` with
  `### Added` (app shell with sidebar navigation and review-backlog badge; toasts; read-only guest role, disabled until
  a guest password is configured; `enable_guest_access` setting; `GRAPH_MEM_GUEST_USERNAME` / `GRAPH_MEM_GUEST_PASSWORD`),
  `### Changed` (layout no longer forces a flex row; sign-in uses its own layout; the flash container id is now `toasts`),
  `### Security` (Content Security Policy is enforced, with `base-uri` and `form-action 'self'`; every non-opted-in route
  is operator-only and pinned by a route-matrix spec).

## Size and split

As written in `ui-dashboard-plan.md` §6, UI-1 was too big for one reviewable PR (section routes, 301s, table/filter/
pagination components and the full component set on top of the shell, roles and CSP). Trimmed as above it is about
**1,600-1,900 changed lines, roughly half of them specs** (A ≈ 700, B ≈ 1,000). That is one PR, because the nav is
role-aware and the CSP system spec covers guest pages. **Decision (changeable): ship it as one PR.**

If Steve prefers two PRs, the commit order already splits cleanly:
- **UI-1a** (commits A1-A2): shell, design system, CSP enforced. Adds its CHANGELOG lines under `## [Unreleased]`,
  **no version bump**. The nav shows operator items only (`can_write?` is always true without guests).
- **UI-1b** (commits B1-B3 + R): guest role, read-only graph, docs, and the **1.56.0** release that folds in UI-1a.
  Branches would be `claude/ui-1a-shell-csp` and `claude/ui-1b-guest-1.56.0`. The release train numbers don't move.

## Decisions (changeable)

1. **No new section routes or 301s in UI-1.** The sidebar groups the existing URLs under the five section names.
   Each later UI PR adds its section URL (`/explore`, `/review`, …) and the redirect when it builds that page. This
   avoids aliases that point at pages that haven't been redesigned and the redirect churn twice over.
2. **Only the components the shell needs** (sidebar, page header, toasts, buttons/inputs/badges/cards classes). Table,
   filter bar, pagination theme, confirm card and empty/skeleton/error states come with their first user (UI-5/UI-3/UI-7).
3. **Add `base-uri 'self'` and `form-action 'self'`** to the enforced policy; keep `report-uri /csp-reports` so
   violations still reach the log.
4. **Keep `style-src 'self' 'unsafe-inline'`**, nonce on `script-src` only. Five inline `style=` attributes and Turbo's
   progress-bar `<style>` need it; scripts are what matters for XSS. Tightening styles is UI-8.
5. **Guest on `/graph`:** allowed (it is Explore today); the canvas hides edit items and drag-and-drop via a Stimulus
   value; every write it could make is already refused server-side.
6. **`enable_guest_access` lives in the Feature Flags group for now** (generic switch with a description); UI-7 moves
   it to Settings › Access with the "not configured / available / turned off" status line.
7. **Guest fingerprint = HMAC-SHA256 with `secret_key_base`, 32 hex chars** (instead of a bare truncated SHA-256): the
   cookie is encrypted anyway, but an HMAC can't be precomputed from a guessed password.
8. **Operator timeouts stay at 24 h idle / 7 days absolute** (the code since UI-0); `ui-dashboard-plan.md` §2.1 says
   12 h idle. Guests get 2 h / 24 h as planned.
9. **Guests land on `/search`** after sign-in and ignore a stored return path unless it is under `/search` or `/graph`
   (so a guest never lands on a 403 right after signing in).
10. **`/api-docs` returns 404 to guests**, not 403: the existing `OperatorSessionConstraint` hides the route, and the
    matrix spec asserts "not 200". Mission Control returns 403 through `authorize_role!`.
11. **The flash container becomes `#toasts`** (one Turbo Stream target rename in `DataExchangeController`), as in §3.1.
12. **`GUEST_READ_ACTIONS` lives in `ApiAuthentication`** (keyed by `controller_path#action`), not as a separate
    `Api::V1` constant file.

## Acceptance criteria

- The scope above and nothing else; every existing page is reachable from the sidebar and renders inside the shell.
- With **no** guest ENV and no `guest:` credentials entry the app behaves like 1.55.3 for the operator, and `guest` +
  any password gets the generic invalid-credentials error. No credentials file was touched (`git diff --stat` shows no
  `config/credentials*` or key file).
- With a guest password set: guests reach only Search, Explore (read-only) and Sign out; every other route returns 403
  (404 for `/api-docs`) and no mutation succeeds; `/mcp*` ignores the guest session (role-matrix, guest-login,
  API and MCP specs green).
- CSP is enforced (`Content-Security-Policy` header, no `-Report-Only`), zero CSP console errors in the system spec,
  and the manual DevTools pass is clean.
- Required specs green; the **full suite run alone** green; `bin/rubocop` and `bin/brakeman` clean; the test database
  has 0 rows in every table before and after the run (truncate snippet in `ui-dashboard-plan.md` §0.1).
- No `alert()`/`confirm()`, no `innerHTML` with data, files under ~500 lines, methods under ~60.
- Version 1.56.0 in `version.rb` and `SKILL.md`, the CHANGELOG entry above, docs updated.
- **One PR against `main`**, CI green. The PR body has: the scope, the CSP checklist ticked, the manual checks with
  screenshots (operator shell at 1440 px and 800 px, guest shell, the 403 page, `/graph` as guest, sign-in page) on
  synthetic data, and the decisions above. Fix the review bot's should-fix findings with new commits on the same
  branch; no force-push after review starts.

**Manual checks** (synthetic data): sign in as operator → visit every sidebar item, open the graph context menu,
drag a node, run a Mission Control page, export from Maintenance; sign out; set `GRAPH_MEM_GUEST_PASSWORD` in your
shell (never in a committed file), restart, sign in as `guest` → Search, Explore (no edit items), type `/maintenance`
→ 403; turn "Guest access" off as operator → the guest is signed out on the next click.

## Stop and ask Steve if

- any quoted line no longer matches the code;
- an existing page breaks visibly once the global flex `main` is gone and the fix isn't a one-class change;
- enforcing CSP shows a violation you can't remove without inline code, `'unsafe-eval'` or a new source;
- Mission Control, rswag or Turbo need a CSP relaxation;
- the Selenium browser-log API isn't available for the CSP system spec;
- a route can't be classified in the role matrix (it isn't obviously read-only for guests or operator-only);
- the PR grows past ~2,000 changed lines (then propose the UI-1a/UI-1b split above before continuing);
- anything seems to need editing `config/credentials.yml.enc` or a key file.
