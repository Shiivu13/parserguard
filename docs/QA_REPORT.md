# QA report

Two independent reviews ran against the merged feature branches:
- a senior code and QA review
- a security review

Both reviewers wrote their own probe scripts and reproduced findings where they could. Every fix below has a regression spec in `spec/services/security_spec.rb` or `spec/services/review_regressions_spec.rb`, unless noted otherwise.

The **regression suite** (`parserguard:regression`) found a third class of issue on its own, a false-positive severity. That one is listed at the end.

## Security review

| # | Severity | Finding | Fix |
|---|---|---|---|
| 1 | High | **DNS rebinding SSRF.** The fetcher checked one resolution and Net::HTTP resolved again. Reproduced: a resolver returning a public IP still let `localhost/admin` through. | Resolve once, require all addresses public, pin the connection with `Net::HTTP#ipaddr=`. Same on every redirect hop. |
| 2 | High | **Whole body read before the size check.** A 40 MB response added 64 MB of RSS. Also open to gzip bombs. | Streamed read with a hard cap, `Content-Length` pre-check, `Accept-Encoding: identity`, total deadline. |
| 3 | High | **Levenshtein CPU attack.** 2,000 near-length decoys took 21.7 s per sample. | Banded Levenshtein with early exit, token-overlap prefilter, node and fuzzy-comparison budgets. The same page now takes under 2 s (spec-enforced). |
| 4 | Medium | **IPv6 blocklist gaps:** `::`, `::/96`, NAT64, 6to4, Teredo, site-local. | Ranges blocked. Bracketed literals are vetted via `uri.hostname`. |
| 5 | Medium | **Slack mrkdwn injection** through locale or contract key (`<!channel>`, phishing links). | Escape `& < >` and backticks. Validate locale, engine and result_type formats. |
| 6 | Medium | **Expensive user selectors and very deep documents.** | `Contracts::SelectorPolicy` blocks `*`, nested `:has`, more than 8 compounds and more than 200 characters. Parse depth capped at 128. |
| 7 | Medium | **No request-body limit; HTML written to the logs.** | Puma `http_content_length_limit` of 6 MB. `:html` added to filtered parameters. |
| 8 | Low | **SerpApi `raw_html_file` fetched without guards.** | Must be https `*.serpapi.com`, and is fetched through `UrlFetcher`. |
| 9 | Low | **Dashboard open whenever no password is set.** | Fails closed outside development and test. |
| 10 | Low | **Internal errors leaked** (host, port, `ECONNREFUSED`). | Callers get a generic message. Details go to the log. |
| 11 | Low | **No CSP.** | CSP added with script nonces, `object-src 'none'` and `frame-ancestors 'none'`. |
| 12 | Low | **Double accept race.** | Atomic claim on the suggestion. |

The review checked and cleared these areas: Mongo operator injection, CSRF (including the JSON accept endpoint), XSS (no `raw` or `html_safe`; the snapshot preview is escaped), and API key generation and storage.

## Code and QA review

| # | Severity | Finding | Fix |
|---|---|---|---|
| 1 | High | **An invalid `PATCH /contracts/:id` still wrote `field_specs`.** Mongoid persists `embeds_many` assignment immediately. A contract could be left with duplicate names, permanently invalid. | `ParserContract.change!` copies the raw document, validates it, then writes once with compare-and-set. The forced YAML loader uses the same path. |
| 2 | High | **Concurrent accepts on different fields lost a version bump.** | Compare-and-set on `version` with retry. Each revision records its own version. |
| 3 | Med-High | **`DetectDriftJob` retry after a partial failure** queued no healing and no alert. | Every follow-up step is idempotent: healing runs unless a suggestion already exists for the event, and the alert sends unless `alerted_at` is set. |
| 4 | Medium | **Optional-only contracts** always scored 0 and were always "broken". | A required field is mandatory. Optional-only extraction scores 1.0. |
| 5 | Medium | **sha256 dedupe was global,** so a mobile capture of the same bytes never got a snapshot. Duplicate results were light documents, so calling `.html` raised. | Unique index on `{engine, locale, device, sha256}`. Duplicates return full documents. |
| 6 | Medium | **Non-UTF-8 pages** gave a 500 from the API, and `scrub("")` silently dropped accented characters. | `Html::Encoding` checks the HTTP charset, then the meta charset, then falls back to Windows-1252. Invalid bytes become U+FFFD. |
| 7 | Medium | **A reject could overwrite an accept.** | `reject!` is a conditional `find_one_and_update`. The API returns 409 when it loses. |
| 8 | Medium | **Integer parsing concatenated every digit** ("1,230 results (0.45 s)" became 1230045). Any `/url?q=` link was unwrapped. | Only the first number is used. Only Google or relative `/url` links are unwrapped. |
| 9 | Medium | **One bad watch target aborted the scheduled ingest.** | Each target is isolated with its own rescue and log line. |
| 10 | Low | **Baseline lookups loaded the 5 MB HTML blob.** | `baseline_for` returns a light document. `with_html` loads the page only when needed. |
| 11 | Low | **Duplicate pending suggestions under concurrent healers.** | Partial unique index on pending `{contract, field, snapshot}`. A duplicate-key error is treated as "already exists". |
| 12 | Low | **Two baselines possible for one target.** | Partial unique index on `{engine, locale, device}` where `baseline: true`. |
| 13 | Low | **URL healing only looked at `href`.** | Healing honours the field's `extract` attribute (for example `src`). |
| 15 | Low | **Shared test database:** parallel runs truncated each other's data. | One database per process, dropped after the suite. |
| — | — | **An "accepting" claim could be stranded** if a process died mid-accept. | Claims older than 2 minutes count as pending again. |

The QA fixes also uncovered a hidden infrastructure bug. `Mongoid::Tasks::Database.create_indexes` only covers models that are already loaded, and the test environment does not eager-load. So the unique and partial indexes had never been created in the test and regression databases. Models are now eager-loaded before indexes are created.

**Not fixed (documented in the README):** finding 14. Container healing needs at least two matched results.

## Found by the regression suite

| Finding | Fix |
|---|---|
| An ad block inserted above the results scored drift 0.225 and was rated **major** while every contract still passed at 100%. That is a false alarm. | While contracts exist and all pass, structural drift is capped at `minor`. The `ads_added.html` fixture locks this in. |
