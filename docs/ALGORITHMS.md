# Algorithms

Tunables live in `config/parserguard.yml`.

## 1. Extraction rate (`Contracts::Runner`)

```
containers  = scope.css(container_selector)          # scope = contract.scope_selector
cell(c, f)  = TypeValidator(extract(c, f))            # string non-blank / http(s) URL / integer
rate        = Σ valid required cells / (|containers| × |required fields|)
field rate  = valid cells of f / |containers|
status      = rate ≥ min_extraction_rate ? passed : failed
```

There are two edge cases:
- Zero containers gives a rate of 0.
- A contract must declare at least one required field.

Type rules:
- **string**: the text, squished, must not be blank.
- **url**: must resolve to an http(s) URL. Google's own `/url?q=` wrappers are unwrapped.
- **integer**: the first number in the text, with thousands separators allowed. "4.5" is rejected.

## 2. Structure signature and drift (`Html::StructureSignature`, `Drift::Comparator`)

At ingest, the page is first normalized:
- It is converted to UTF-8.
- It is parsed with the HTML5 parser at a maximum depth of 128.
- `script`, `style`, `svg`, `noscript`, `template`, `iframe`, `link`, `meta` and comments are dropped.

The signature then records two multisets of paths for every element, truncated to the last 7 steps:

```
tag path:    div>div>a>h3
class path:  div.g.tF2Cxc>div.yuRUbf>a>h3.DKV0Md.LC20lb     (classes de-duplicated and sorted)
```

Both multisets are stored as `[path, count]` pairs, because Mongo keys cannot contain `.`.

```
J(A, B)      = Σk min(Ak, Bk) / Σk max(Ak, Bk)        (1.0 when both empty)
tag_drift    = 1 − J(tags_baseline,    tags_candidate)
class_drift  = 1 − J(classes_baseline, classes_candidate)
drift_score  = 0.6·tag_drift + 0.4·class_drift
```

Added and removed class paths are ranked by count delta (top 50) and shown on the drift page.

**Why two histograms:** a class rotation leaves `tag_drift = 0` and raises `class_drift`. A re-nesting moves both. The weighted Jaccard counts repeated result blocks, so losing 10 identical `div.g` items counts more than losing one footer link.

### Severity (`Drift::Detector`)

| severity | rule |
|---|---|
| broken | an active contract finds 0 containers, or its rate < 0.5 |
| major  | a required field is below the contract minimum, or there are no contracts for the engine and score ≥ 0.20 |
| minor  | score ≥ 0.05 |
| none   | otherwise |

While contracts exist and all pass, structure alone never escalates past `minor`. The regression suite found this case: an ad block above the results scored 0.225, which was a false "major".

## 3. Self-healing (`Healing::*`)

**Samples.** The healer takes up to 8 distinct known-good values of the field. They come from the baseline's latest passing `ContractRun`, so they are still available after the contract's selectors have changed.

**Locate (`TextMatcher`).** Values are normalized (downcase, punctuation stripped, squished) and matched as follows:
1. Exact match first.
2. Otherwise, filters run from cheapest to most expensive:
   - length within 15%
   - at least 50% token overlap
   - banded Levenshtein similarity ≥ 0.85, computed only inside the diagonal band that could still pass, with early exit
3. URL fields compare `host (minus www.) + path` of the configured attribute.

The traversal is post-order, so on a tie the deepest node wins. Work is capped at 50k nodes and 2k fuzzy comparisons per search, because pages are untrusted.

**Generate (`SelectorGenerator`).** Candidates are built for the matched node, and for ancestors inside the container that carry the same text. Each candidate type gets a base stability:

| candidate | stability |
|---|---|
| `#id` (not random-looking) | 0.9 |
| `tag[role=…]`, `tag[aria-level=…]` | 0.9 |
| semantic tag (`h3`, `cite`, `a[href]`…) | 0.8 |
| `tag[data-*]` | 0.7 |
| `tag.class` with a readable class | 0.7 |
| `tag.class` with a build-generated class (`yuRUbf`, `tF2Cxc`) | 0.5 |
| other attribute presence | 0.5 |
| generic `div` / `span` | 0.4 |
| `nth-of-type` path | 0.3 |

Chains (`parent > node`, `grandparent node`) take the minimum stability of their parts.

**Score (`CandidateScorer`).** Each candidate is scored over all containers of the new page:

```
coverage   = containers where the first match passes the type check / containers
agreement  = samples found among extracted values / samples
uniqueness = 1 / avg(matches per container)
confidence = 0.4·coverage + 0.3·agreement + 0.2·stability + 0.1·uniqueness
```

Candidates that select the same nodes are collapsed, keeping the most stable. Anything below 0.4 is dropped and the top 5 are kept.

**Container healing.** When the container selector itself finds nothing:
1. Locate the anchor field's samples, using the first required string field.
2. From each match, climb to the *item boundary*: the lowest ancestor whose parent contains more than one matched sample.
3. Generate selectors for those boundaries.
4. Score each candidate container selector `s`:
   - coverage: the share of samples it encloses
   - agreement: the extraction rate the contract would get with `s`
   - uniqueness: `min(k, m) / max(k, m)`, where k = containers found and m = samples matched

Healing happens in steps. After the container is accepted, `RunContractsJob` re-runs the contract and heals each field that still fails. Example from the fixtures:

```
structural_change:  div.g → div.MjjYud (0.80)   then   div.yuRUbf > a → a[href] (0.96)   rate 0 → 0.67 → 1.0
```

**Accept (`SuggestionAcceptor`).** Accepting a suggestion:
- Claims it atomically (`pending → accepting`).
- Writes the contract through `ParserContract.change!`: validate first, then compare-and-set on `version`, then append a `ContractRevision`.
- Rejects any other pending suggestion for the same field and snapshot.

Selectors are never applied automatically.
