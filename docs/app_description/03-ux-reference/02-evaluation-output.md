# Evaluation output reference

## Example file

`evaluation-report-example.json` — the real output of a completed evaluation (an ICO-level candidate, a partial subset of the competency set).

## Expected structure

```json
{
  "COMPETENCY_CODE": {
    "score": 3.67,
    "reliability": "100%",
    "behaviors": [
      {
        "indicator": "BARS indicator name",
        "score": 3,
        "explanation": "Rationale for the score...",
        "excerpts": [
          "Excerpt from the candidate's answers...",
          "Another excerpt..."
        ]
      }
    ]
  }
}
```

## Use within the project

- **Admin panel:** per-competency report view with score, indicators and excerpts;
- **Export:** downloadable JSON or a read API;
- **Evaluation webhook:** the payload may include this structure in the text field plus references to assets (audio, transcript);
- **HTML/PDF report:** the layout is free; the data structure must preserve the fields above.

## Notes

- Per-indicator scores use the set {1,2,3,4,5} (4 and 2 are residual levels, selected only when the evidence matches neither adjacent anchor); -1 = unassessable (excluded from the mean);
- `reliability` indicates how far the answers provided sufficient evidence;
- the `reliability` values in the example are illustrative and not normative (pending open decision #1);
- `excerpts` must be faithful quotations from the transcript (never invented).
