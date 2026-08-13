# Proposal: Interview Review Surface and Template Portability

## Intent

Two gaps, both found by reading the running system rather than the docs.

1. **BEAI collects proctoring evidence and shows none of it.** `integrity_events`
   and `interview_snapshots` are written on every interview by
   `Candidate\IntegrityController` and `Candidate\SnapshotController`. There is
   no read endpoint and no backoffice view — `rg -l "integrity|snapshot|proctor"
   backoffice/app/` returns nothing. The data exists, costs storage, carries
   GDPR weight, and has never once been looked at.

2. **Avatar template configuration cannot leave or enter the system.** Tuning a
   provider config is done by hand, per environment, through the form. The
   sibling project `quint-avatar-tester` exists precisely to find good configs,
   and there is no way to carry one across.

## What the reference project does

`quint-avatar-tester` (Astro + SQLite, on the same machine) runs one continuous
avatar session per template and reviews it afterwards. Relevant to us:

- **`templates`** — `heygen_config` and `tavus_config` as JSON blocks on one row.
- **`prompts`** — persona `body` + spoken `greeting` + language.
- **`integrity_events`** — 13 event types with a weighted risk score and three
  bands (`proctor-config.ts`), including `looking_away`, `looking_down`,
  `face_absent`, `too_far`, `multiple_faces`, `phone_detected`, `second_voice`.
- **`pricing.ts`** — provider cost estimate: HeyGen credits/min × $/credit,
  Tavus $/conversational-minute.
- **Periodic snapshots** — one webcam frame every 10s.

BEAI already has the same taxonomy vocabulary available (`legacy-demo` carries
the identical `proctor-config.ts`, cited by `CLAUDE.md` as the source to port).

## Scope

**Session review (backoffice only).** An admin-facing read surface per interview
session: duration and timing, provider cost estimate, the timed snapshot strip,
the integrity timeline with its risk score, and the session's technical facts
(provider, session ref, ended reason).

**Template portability.** JSON export and import of avatar template
configuration, plus the persona (system prompt body + greeting) that goes with
it. **Admin only**, on both directions.

## Two rulings taken before design (asked and answered)

- **Templates carry provider config and persona, not questions.** BEAI's
  questions are derived from BARS competencies with adaptive follow-ups; that is
  a binding domain constraint. Importing `avatar-tester`'s hand-ordered question
  lists would contradict it, and is out of scope.
- **A multi-provider export becomes one BEAI template per provider.** An
  `avatar-tester` row holding both `heygen_config` and `tavus_config` imports as
  two templates, because a BEAI template belongs to one provider and that
  provider is immutable after creation.

## Dependency, and a gap it exposes

The `avatar-templates` delta in this change extends a capability that **does not
yet exist in `openspec/specs/`**. Avatar templates are fully built and running —
table, policy, field specs, form, tests — but their change
(`openspec/changes/avatar-provider-templates/`) is still open and carries a
proposal and tasks with **no delta specs at all**. The capability was never
written down.

So this change is blocked on that one being finished and archived, and it should
stay blocked rather than inventing the capability spec sideways: whoever wrote
`avatar-provider-templates` owns what it says.

Flagged separately because it is a hole worth closing on its own terms — a
shipped feature with no specification is invisible to everyone who did not build
it.

## Non-goals

- **Not visible to candidates, ever.** The review surface is backoffice-only.
  A candidate who could see their own integrity score would be told how to game
  it, and the score is an operator's input to judgement, not a verdict served
  back to the person judged.
- **No new capture.** Events and snapshots are already collected; this reads
  them. The one addition is cost, which is computed from timings already stored.
- **No retention change.** Snapshots and events fall under the retention rules
  awaiting sign-off (open decision 2). Making them visible does not extend how
  long they are kept, and the review surface must not become a reason to keep
  them longer.
- **No import of candidate or session data.** Only template configuration and
  persona cross the boundary. Importing anything tied to a person would move
  personal data between systems with no legal basis.
