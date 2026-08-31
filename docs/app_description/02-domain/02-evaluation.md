# Evaluation logic

## Goal

At the end of the interview, the system produces a **structured evaluation** that quantifies the candidate's soft skills against the role and the competencies of the project.

## Process

1. **Input:** the full transcript of the conversation (questions + answers).
2. **Context:** the candidate's role, the competency definitions, the BARS scales for the role.
3. **Analysis:** for every assessed competency, the AI:
   - identifies behaviours observed in the answers;
   - compares them against the BARS indicators;
   - assigns a score per indicator and per competency;
   - computes reliability (how far the answers suffice to judge).
4. **Output:** a JSON structure with scores, explanations and textual excerpts.

## Evaluation output content

For every assessed **competency**:

| Field | Description |
|-------|-------------|
| `score` | Overall competency score (e.g. the mean of the indicators, on a numeric scale) |
| `reliability` | Reliability of the evaluation (e.g. a percentage, or qualitative: high/medium/low) |
| `behaviors[]` | List of assessed indicators |

For every **indicator** (`behaviors`):

| Field | Description |
|-------|-------------|
| `indicator` | Name of the behavioural indicator (from BARS) |
| `score` | Score assigned on the set {1,2,3,4,5} (4 and 2 are residual levels, see rubric AD-1); -1 if unassessable |
| `explanation` | Rationale for the score |
| `excerpts[]` | Supporting textual excerpts from the candidate's answers |

## Associated assets

Beyond the structured text, the evaluation may include references to:
- audio files of the answers (per competency/question);
- the full transcript (JSON or plain text);
- the raw evaluation file (JSON).

## Asynchronous execution

- The evaluation is **not** synchronous with the end of the interview.
- A background job starts immediately after the interview closes.
- Results are typically available within **a few minutes**.
- The candidate's status moves to "under evaluation" until completion.

## Concrete example

See `../03-ux-reference/evaluation-report-example.json` for a real output (competencies COL, COM, CSF, etc. with behaviors, score, excerpts).

## Implementation notes

- The evaluation engine may be an LLM service with structured prompts and JSON-schema output.
- The BARS scales in `framework/bars/` are the **authoritative reference** for indicators and scoring anchors.
- The evaluation must be **repeatable** and **traceable** (prompt/model version, job timestamp).

## Overall evaluation states

| State | Meaning |
|-------|-------------|
| `completed` | The evaluation is considered definitive (competency threshold reached, or the retry is exhausted) |
| `pending` | The evaluation was processed but competency coverage is insufficient; the candidate may retry |

Rule detail: `../05-business-rules/02-evaluation-rules.md`.
