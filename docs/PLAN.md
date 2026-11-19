# Implementation plan

The plan I wrote before starting. [ALGORITHMS.md](ALGORITHMS.md) describes what actually shipped, including changes made during hardening.

## Branches

One branch per area, each merged into `main` with `--no-ff` once its specs passed.

| # | Branch | Area | Scope |
|---|---|---|---|
| 1 | `chore/setup` | DevOps | Rails 8 without ActiveRecord; Mongoid, Sidekiq, RSpec/FactoryBot/WebMock/SimpleCov; CI; LF-only fixtures |
| 2 | `feat/models` | Backend | Snapshot (gzipped HTML, histograms), ParserContract (embedded FieldSpec and revisions), ContractRun, DriftEvent, SelectorSuggestion, ApiKey |
| 3 | `feat/ingestion` | Backend | SnapshotCreator (dedupe, versioning, first-baseline rule), fixture, URL and SerpApi fetchers, structure signature |
| 4 | `feat/contracts` | Backend | YAML contracts, field extractor, type validator, runner |
| 5 | `feat/drift` | Backend | Weighted-Jaccard comparator, severity detector |
| 6 | `feat/healing` | Backend | Text matcher, selector generator, candidate scorer, healer (field and container), acceptor |
| 7 | `feat/api` | Backend | JSON API v1, hashed API keys, uniform errors, pagination |
| 8 | `feat/jobs-alerts` | Backend + DevOps | detect → heal → alert jobs, Slack webhook, scheduled ingest |
| 9 | `feat/dashboard` | Frontend | Health cards, drift timeline, side-by-side suggestion review, Stimulus accept |
| 10 | `test/qa-hardening` | Testing | Manifest-driven regression runner, extra fixture, security and correctness fixes |
| 11 | `docs/readme` | Docs | README, algorithms, hardening notes |

## Key decisions

- **Plain Ruby service objects returning `Result`.** Controllers, jobs and rake tasks share one code path.
- **Store the HTML gzipped, and the histograms precomputed.** Drift comparison never re-parses old pages.
- **Store histograms as `[path, count]` pairs.** CSS paths contain `.`, which Mongo keys cannot.
- **Never auto-apply a selector.** A human accepts it. Every change bumps the contract version and adds a revision, so runs can be traced to a contract version and rolled back.
- **No direct engine scraping.** Real pages come from SerpApi's `raw_html_file`. Fixtures are hand-written.

## Risks identified up front

| Risk | Mitigation |
|---|---|
| Native gems on Windows | Precompiled nokogiri. `bundle lock --add-platform x86_64-linux` for CI. |
| Sidekiq on Windows | `JOB_ADAPTER=async` fallback. docker-compose for Redis. |
| CRLF changing fixture bytes and their sha256 | `.gitattributes` sets `*.html -text` for fixtures and `eol=lf` elsewhere. |
| Fuzzy matching cost | Sample cap and text-length cap. Hardening later added budgets and banded Levenshtein. |
| Healing false positives | Human review, visible sample values, versioned revisions. |
