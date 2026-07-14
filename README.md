# BEAI — Business Evaluation AI

**BEAI** is a multi-tenant platform for **soft-skill assessment via automated AI voice
interview**. A candidate enters through SSO/magic-link, takes an adaptive spoken interview
with a synthetic voice, and an asynchronous job produces a **BARS** competency evaluation
that is pushed to the calling HR system via webhook.

- **Domain source of truth (binding):** [`docs/app_description/`](docs/app_description/)
  and [`docs/BEAI_BRIEF.md`](docs/BEAI_BRIEF.md).
- **Project rules & constraints:** [`CLAUDE.md`](CLAUDE.md).
- **How we work:** Spec-Driven Development (SDD) **+** Test-Driven Development (TDD),
  coverage target 85%, Git Flow (`main`/`develop` + `feature`/`release`/`hotfix`).

### Target stack
This repo is a **wrapper superproject** with three git submodules:
- **`api`** — Laravel 12 + Eloquent + MySQL 8 + Redis (Horizon), **API-only**; **Scramble**
  publishes the OpenAPI spec. Stateless, scalable to thousands of concurrent candidates.
- **`frontend`** — Nuxt 4 (Vue 3) **SSR** + `@nuxtjs/i18n`: the candidate interview app
  (ports the avatar/proctoring logic below).
- **`backoffice`** — Nuxt 4 (Vue 3) **SPA** + `@nuxtjs/i18n`: the admin panel (separate app).

Both Nuxt apps **codegen a typed client from the API's OpenAPI**. Auth: Sanctum (SPA cookies
for the backoffice + token abilities for external API + signed candidate magic-link). Tests:
Pest (`api`) + Vitest/Vue Test Utils + Playwright. Deploy: Railway, three services, on request.

The build is greenfield (no legacy backward compatibility). The SDD roadmap slices it into
13 vertical changes (C1→C13). See [`openspec/ROADMAP.md`](openspec/ROADMAP.md).

---

## Reference: current avatar demo (Astro, local only)

> The section below documents the **existing demo** — the product kernel and the reference
> for the Nuxt port (C7). It is not the final architecture.

A single-page Astro app that runs the SAME Italian HR-style interview through **two
interchangeable providers**. You pick HeyGen **or** Tavus before starting; the avatar
leads the interview and **every utterance — yours and the avatar's — is stored in a
local SQLite database** for later analysis.

The interview runs as a **sequence of short, single-question sessions** — one provider
session per question, each with its own countdown — so a session never overruns a cheap
per-minute cap. Between questions you can **pause and resume later** with a short code;
progress lives in SQLite and survives app restarts. For each question the avatar is given
only that question's objective plus a recap of your prior answers (so it doesn't re-ask),
and it probes until the objective is met, then wraps up.

Both providers use **their own default LLM** ("their brain"); the interview script
(`questions.json`) is injected as per-question context. All code, identifiers, comments
and UI labels are English — only the avatar's spoken content and the questions are Italian.

## Architecture (demo)

- **Provider abstraction** (`src/providers/types.ts`): one `InterviewProvider`
  interface both implementations satisfy, so the UI and persistence are
  provider-agnostic. Every transcript event is normalized to
  `{ role: 'user' | 'avatar', text, ts, seq? }`.
  - `HeyGenProvider` — `@heygen/liveavatar-web-sdk`, FULL mode (HeyGen does
    ASR+LLM+TTS). Normalizes `user.transcription` / `avatar.transcription` events.
  - `TavusProvider` — `@daily-co/daily-js`, joins the conversation room audio-only
    (camera off). Normalizes Daily `app-message` `conversation.utterance` events.
- **Backend** (Astro `output: 'server'` + `@astrojs/node` standalone). API keys are
  read server-side only, never in the browser.
- **Persistence**: `better-sqlite3` at `./data/interviews.db`, schema auto-created on
  boot. `./data` is gitignored.

### Endpoints

| Method | Route | Purpose |
| --- | --- | --- |
| POST | `/api/candidate` | Create a candidate + a short resume code, seed one `pending` progress row per question |
| GET | `/api/candidate/:code` | Load a candidate by resume code: progress + the next question to run |
| POST | `/api/candidate/progress` | Set a question's status (used by "Prossima domanda" → `completed`) |
| POST | `/api/interview/start` | Body `{ candidateId, questionIndex, provider }`: compose that question's Italian context (+ recap), create the provider session, return connection info + timer |
| POST | `/api/interview/utterance` | Insert one normalized utterance |
| POST | `/api/interview/end` | Body `{ sessionId, provider, providerSessionId, endedReason }`: mark ended; HeyGen reconcile; free the Tavus slot; store a raw answer summary; mark `timeout` on expiry |
| GET | `/api/interview/:id` | Return the stored transcript (JSON) |
| GET | `/api/credits` | HeyGen real credit balance (for the cost meter) |
| GET | `/review/:id` | Simple stored-transcript view + estimated cost |

### Data model

`candidates` (resume code) → `question_progress` (one row per question:
`pending | completed | timeout | skipped`, plus a raw `answer_summary`) → `sessions`
(one per question, carrying `candidate_id / question_id / question_index / ended_reason`)
→ `utterances`. The schema is auto-created and auto-migrated on boot.

## Setup

### 1. Install

```bash
npm install
```

### 2. Environment

`.env.example` / `.env` are protected by the local tooling, so create them yourself.
Copy this into **`.env.example`** (secrets empty) and into **`.env`** (filled in):

```dotenv
# HeyGen LiveAvatar
LIVEAVATAR_API_KEY=
LIVEAVATAR_AVATAR_ID=ab0765ad-69de-41fb-9f8a-bd01c3c52d6f   # Alessandra
LIVEAVATAR_VOICE_ID=c84af063-5ce2-4370-8ef8-dcd0ef903d43    # Alessandra IT voice
LIVEAVATAR_LANGUAGE=it

# Tavus CVI
TAVUS_API_KEY=
TAVUS_PERSONA_ID=p8a490c4dfd4
TAVUS_REPLICA_ID=rf4e9d9790f0

# Optional cost-meter rate overrides (defaults in src/lib/pricing.ts)
# TAVUS_USD_PER_MIN=0.37
# HEYGEN_USD_PER_CREDIT=0.10
# HEYGEN_CREDITS_PER_MIN=2

# Optional per-question timer (defaults in src/lib/timing.ts)
# SESSION_TIME_LIMIT_SECONDS=285   # 4:45, kept under a 5:00 provider cap
# SESSION_WARN_SECONDS=60          # countdown turns amber at/under this remaining
```

**Values you must supply from the dashboards:**

| Var | Where to get it |
| --- | --- |
| `LIVEAVATAR_API_KEY` | HeyGen LiveAvatar dashboard → API key |
| `TAVUS_API_KEY` | Tavus dashboard → PAL Maker → API Key → Create New Key |
| `TAVUS_REPLICA_ID` | Tavus dashboard → Faces (the replica's id, e.g. `r90bbd427f71`) |
| `TAVUS_PERSONA_ID` | Tavus dashboard → PAL Maker (the persona/PAL id, e.g. `pdac61133ac5`) |

The HeyGen avatar/voice IDs above are Alessandra's and can stay as-is. The HeyGen
Context is created automatically at runtime from `questions.json` (no setup script).

### 3. Run

```bash
npm run dev
```

Open **http://localhost:4321**. Mic + WebRTC work on `http://localhost` (a secure
context), so no HTTPS setup is needed.

## Using it

1. Pick a provider (**HeyGen** or **Tavus**) and tick the consent checkbox.
2. **New interview** — enter your name → **Inizia**. You get a **resume code** (save it).
   Or **Riprendi** — type a resume code to continue where you left off.
3. For each question, click **🎤 Parla** — the session and mic start; Alessandra greets
   you and asks that one question, probing until its objective is met. A countdown runs
   in the top bar (amber under the warn threshold, red in the last 15s). Conversational
   VAD turn-taking + barge-in, no push-to-talk.
4. When the question ends (you press **⏹ Stop**, the avatar wraps up, or time runs out),
   choose **Prossima domanda** to continue or **Metti in pausa** to stop — the code lets
   you resume later.
5. Review a stored session's transcript at `GET /api/interview/<id>` or `/review/<id>`.

**Resume behavior:** on resume you land on the first question that isn't completed — so a
question that **timed out is retried**, not skipped. A question is only marked completed
when you affirm it with **Prossima domanda**.

Status line: `connessione…` → `pronta` → `in ascolto` → `sta parlando` → `errore`.

## Cost meter (HeyGen vs Tavus)

The floating meter estimates **≈ $ this session** so you can compare which provider is
cheaper for your use case:

- **HeyGen** — anchored to the *real* remaining balance (`/api/credits`), decrementing
  at 2 credits/min (FULL mode) × ~$0.10/credit.
- **Tavus** — *estimate only* (Tavus exposes no balance API): elapsed minutes ×
  **$0.37/min** (Basic/Starter overage, source tavus.io/pricing), with Tavus billing
  rules (30s minimum, rounded up to 6s). Free tier = 25 min/month, 1 concurrent stream.

Rates live in `src/lib/pricing.ts` and can be overridden via the optional env vars
above. Per-session cost is also recomputed on the `/review/:id` page from the stored
duration, giving an apples-to-apples comparison across providers.

## Notes

- Video starts at `quality: 'low'` (HeyGen) so latency feels instant while testing —
  bump it in `src/pages/api/interview/start.ts` (`HEYGEN_VIDEO_QUALITY`).
- Tavus free tier delivers the live utterance events we capture; the post-call full
  transcript webhook is a **paid** feature. Our capture is client-side, so it works on
  the free tier regardless.
- Local only — no deployment.

## Layout contract

The page never scrolls on the Y axis: `100dvh` flex column, video (`object-fit: contain`)
on top, controls + pulsantone in a fixed bottom bar.
