# Italian Anchor-Length Ceiling — Measurement Record

The English ceiling is 18 words. Italian is systematically longer for the same
content, so reusing 18 would either force bad Italian or be quietly disabled.
This file records how the Italian number was derived, so that a later amendment
argues with the measurement rather than with a preference.

## Method, fixed before the number existed

The decision rule was written down first, on purpose. A rule chosen after
seeing the data is a rationalisation.

1. **Corpus**: `PRS × {FLL, MLL, BUL, SRX}` — 3 indicators × 3 levels × 4 roles
   = **36 anchors**. `PRS` is the only competency assigned to all five roles.
   ICO is excluded: its documented two-sentence 20–30 word register would
   contaminate the ratio.
2. **Blind authoring**: the translator was given the fidelity constraints and
   the register, and was explicitly told not to count words, not to report
   length, and not to shorten anything for any reason other than accuracy. They
   were not told a ceiling existed, and were instructed not to read the
   authoring standard or the CI guards. A translator who knows the number
   produces compliance, and the measurement then measures itself.
3. **Statistic**: `R` = 90th percentile of the per-anchor ratio `wc_it / wc_en`.
   The 90th percentile rather than the maximum, so that one compound-noun
   outlier cannot set policy for 747 anchors.
4. **Ceiling**: `CI_ANCHOR_WORDCOUNT_MAX_IT = ceil(18 × R)`.
5. **Falsification clause**: re-check the 36 against the derived ceiling. If
   more than 10% would need a clause dropped to comply, the ceiling is wrong
   rather than the Italian — recompute with `R = max(r)` and record why, here,
   in the same table.

## Measurement

| Quantity | Value |
|---|---|
| Anchors measured | 36 |
| English words | min 12, max 18 |
| Italian words | min 15, max 26 |
| Ratio `wc_it / wc_en` | min 0.882, median 1.172, **p90 1.414**, max 1.444 |
| `R` (p90) | **1.414** |
| Derived ceiling `ceil(18 × 1.414)` | **26** |
| Anchors exceeding the derived ceiling | **0 of 36 (0.0%)** |
| Falsification clause | **Did not fire** (0% ≤ 10%) |

Two things are worth reading off this table rather than leaving implicit.

**The number is not balanced on an outlier.** The fallback the falsification
clause would have used, `ceil(18 × max(r))`, is also **26**. p90 and max
produce the same ceiling, so the result does not depend on which of the two
statistics was chosen — which is the strongest evidence available at this
sample size that 26 is a property of the language pair and not of these 36
sentences.

**Italian is about 17% longer at the median**, not 40%. The 1.414 tail comes
from a small number of constructions where Italian needs a relative clause for
something English does with a compound noun. Most anchors are barely longer.

## Ceiling in force

```sh
CI_ANCHOR_WORDCOUNT_MAX_IT=26
```

Set in `scripts/ci-guards.sh`. Blocking, exactly as the English ceiling is, and
with the same ICO exemption. An unconfigured locale ceiling **fails closed**
rather than passing silently — a guard with no number must not be mistaken for
a guard that found nothing.

## Known limit of this measurement

36 anchors is roughly 5% of the 747 the catalogue will eventually hold in
Italian. A later role slice may genuinely need more than 26 words for a faithful
translation. If that happens the answer is a recorded amendment with a fresh
table appended to this file — never a silent bump of the constant, and never a
reworded Italian anchor that says less than its English source in order to fit.
Fidelity outranks the ceiling; the ceiling exists to catch padding, not to
compress meaning.
