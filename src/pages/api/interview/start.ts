import type { APIRoute } from 'astro';
// Secrets are read ONLY here (server-side). API keys never reach the browser.
import {
  LIVEAVATAR_API_KEY,
  LIVEAVATAR_AVATAR_ID,
  LIVEAVATAR_VOICE_ID,
  LIVEAVATAR_LANGUAGE,
  TAVUS_API_KEY,
  TAVUS_REPLICA_ID,
  TAVUS_PERSONA_ID,
} from 'astro:env/server';
import { composeQuestionPrompt, questions, type PriorAnswer } from '../../../lib/prompt';
import { HEYGEN_END_PHRASE } from '../../../providers/types';
import { rates } from '../../../lib/pricing';
import { timing } from '../../../lib/timing';
import {
  createSession,
  getCandidateById,
  getProgress,
  setProgressSession,
  type SessionMeta,
} from '../../../lib/db';

export const prerender = false;

const LA_CONTEXTS_URL = 'https://api.liveavatar.com/v1/contexts';
const LA_TOKEN_URL = 'https://api.liveavatar.com/v1/sessions/token';
const TAVUS_CONVERSATIONS_URL = 'https://tavusapi.com/v2/conversations';

// Start LOW so latency feels instant while testing. Bump to 'high'/'very_high' later
// for fidelity. Allowed: 'very_high' | 'high' | 'medium' | 'low'.
const HEYGEN_VIDEO_QUALITY = 'low';

// If a participant leaves the Tavus room, end shortly after (frees the slot promptly).
const TAVUS_PARTICIPANT_LEFT_TIMEOUT = 5;

// Free-tier concurrency-slot release lags the 'ended' status by a few seconds. When a
// start races that window, wait and retry the create instead of failing. Up to
// RETRIES * BACKOFF_MS (~6s) of added latency, and ONLY on the concurrency error.
const TAVUS_CONCURRENCY_RETRIES = 3;
const TAVUS_CONCURRENCY_BACKOFF_MS = 2000;

// Tavus-only: after its closing phrase the persona calls the end_interview tool (registered
// once on the PAL). It reaches the client as a conversation.tool_call app-message and drives
// the soft auto-advance. HeyGen has no equivalent hook, so this instruction is Tavus-scoped.
const TAVUS_END_TOOL_INSTRUCTION =
  '\n\nDopo la tua frase di conclusione per questa domanda, chiama SUBITO lo strumento ' +
  'end_interview per segnalare che hai finito. Non annunciarlo: chiamalo in silenzio.';

// HeyGen FULL mode has no tool-calling, so completion is signalled by SPEAKING a fixed
// phrase. The client (heygen.ts matchesEndPhrase) detects it and drives the auto-advance.
const HEYGEN_END_PHRASE_INSTRUCTION =
  '\n\nQuando hai raccolto l’obiettivo di questa domanda, dopo la tua breve frase di ' +
  `conclusione pronuncia ESATTAMENTE, parola per parola, questa frase finale e poi fermati: "${HEYGEN_END_PHRASE}"`;

interface StartRequest {
  candidateId: number;
  questionIndex: number;
  questionId: string;
  systemPrompt: string;
  greeting: string;
  meta: SessionMeta;
  timezone: string | null;
}

// Parse + validate the request, then compose the per-question Italian context. Returns
// either a ready-to-use StartRequest or an error Response.
function prepare(
  body: { candidateId?: unknown; questionIndex?: unknown; timezone?: unknown } | null,
): StartRequest | Response {
  const candidateId = Number(body?.candidateId);
  const questionIndex = Number(body?.questionIndex);
  const timezone = typeof body?.timezone === 'string' && body.timezone ? body.timezone : null;

  if (!Number.isInteger(candidateId)) return json(400, { error: 'Invalid candidateId.' });
  if (!Number.isInteger(questionIndex) || questionIndex < 0 || questionIndex >= questions.questions.length) {
    return json(400, { error: 'questionIndex out of range.' });
  }
  if (!getCandidateById(candidateId)) return json(404, { error: 'Unknown candidate.' });

  const question = questions.questions[questionIndex];

  // Recap = prior-index questions that already have a (raw-derived) answer summary.
  const priorAnswers: PriorAnswer[] = getProgress(candidateId)
    .filter((p) => p.question_index < questionIndex && p.answer_summary && p.answer_summary.trim())
    .map((p) => ({
      label: questions.questions[p.question_index]?.text ?? p.question_id ?? '',
      text: p.answer_summary as string,
    }));

  const { systemPrompt, greeting } = composeQuestionPrompt({
    index: questionIndex,
    isFirst: questionIndex === 0,
    priorAnswers,
    timeLimitSeconds: timing.limitSeconds,
  });

  return {
    candidateId,
    questionIndex,
    questionId: question.id,
    systemPrompt,
    greeting,
    meta: { candidateId, questionId: question.id, questionIndex, timezone: timezone ?? undefined },
    timezone,
  };
}

export const POST: APIRoute = async ({ request, url }) => {
  const body = (await request.json().catch(() => null)) as
    | { candidateId?: unknown; questionIndex?: unknown; provider?: unknown; timezone?: unknown }
    | null;

  const provider = (body?.provider as string) ?? url.searchParams.get('provider');
  if (provider !== 'heygen' && provider !== 'tavus') {
    return json(400, { error: "'provider' must be 'heygen' or 'tavus'." });
  }

  const prepared = prepare(body);
  if (prepared instanceof Response) return prepared;

  try {
    const res =
      provider === 'heygen' ? await startHeygen(prepared) : await startTavus(prepared);
    return res;
  } catch (err) {
    return json(502, { error: err instanceof Error ? err.message : String(err) });
  }
};

// Build a short timezone context preamble to inject into the persona system prompt so
// the avatar knows the candidate's local date and time without guessing.
function timezoneContext(tz: string | null): string {
  if (!tz) return '';
  try {
    const localTime = new Date().toLocaleString('it-IT', {
      timeZone: tz,
      dateStyle: 'full',
      timeStyle: 'short',
    });
    return `[Contesto temporale]\nFuso orario del candidato: ${tz}. Ora locale: ${localTime}.\n\n`;
  } catch {
    return '';
  }
}

// Extra fields every successful start returns, so the client can drive the timer and
// progress UI without reading server secrets.
function meta(req: StartRequest) {
  return {
    pricing: rates,
    timeLimitSeconds: timing.limitSeconds,
    warnSeconds: timing.warnSeconds,
    questionIndex: req.questionIndex,
    total: questions.questions.length,
  };
}

async function startHeygen(req: StartRequest): Promise<Response> {
  if (!LIVEAVATAR_API_KEY) return json(500, { error: 'Missing LIVEAVATAR_API_KEY in .env.' });
  if (!LIVEAVATAR_AVATAR_ID || !LIVEAVATAR_VOICE_ID) {
    return json(500, { error: 'Missing LIVEAVATAR_AVATAR_ID or LIVEAVATAR_VOICE_ID in .env.' });
  }

  // A fresh Context per start: the prompt is candidate- and question-specific now, so
  // there is nothing stable to cache (caching by version would inject the wrong question).
  const contextId = await createHeygenContext(
    timezoneContext(req.timezone) + req.systemPrompt + HEYGEN_END_PHRASE_INSTRUCTION,
    req.greeting,
    req.questionId,
    req.candidateId,
  );

  // FULL mode: HeyGen provides ASR + LLM + TTS. All avatar/voice/quality/language config
  // lives in the token request.
  const tokenRes = await fetch(LA_TOKEN_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-API-KEY': LIVEAVATAR_API_KEY },
    body: JSON.stringify({
      mode: 'FULL',
      avatar_id: LIVEAVATAR_AVATAR_ID,
      is_sandbox: false,
      video_settings: { quality: HEYGEN_VIDEO_QUALITY },
      interactivity_type: 'CONVERSATIONAL',
      avatar_persona: {
        voice_id: LIVEAVATAR_VOICE_ID,
        context_id: contextId,
        language: LIVEAVATAR_LANGUAGE,
      },
    }),
  });
  const payload = await tokenRes.json().catch(() => null);
  if (!tokenRes.ok) throw new Error(`LiveAvatar rejected the token request (HTTP ${tokenRes.status}).`);
  const data = payload?.data ?? {};
  if (!data.session_token) throw new Error('LiveAvatar returned no session_token.');

  const providerSessionId: string | null = data.session_id ?? null;
  const dbSessionId = createSession('heygen', providerSessionId, questions.version, req.meta);
  setProgressSession(req.candidateId, req.questionIndex, dbSessionId);

  return json(200, {
    dbSessionId,
    provider: 'heygen',
    sessionToken: data.session_token,
    providerSessionId,
    ...meta(req),
  });
}

async function createHeygenContext(
  prompt: string,
  openingText: string,
  questionId: string,
  candidateId: number,
): Promise<string> {
  const res = await fetch(LA_CONTEXTS_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-API-KEY': LIVEAVATAR_API_KEY },
    body: JSON.stringify({
      // Context names must be UNIQUE per LiveAvatar account. A stable name collided on
      // every interview after the first ("Context with this name already exists"). We
      // create a fresh context each start, so the name carries candidate id + timestamp.
      name: `Colloquio v${questions.version} — ${questionId} — c${candidateId}-${Date.now()}`,
      prompt,
      opening_text: openingText,
    }),
  });
  const payload = await res.json().catch(() => null);
  if (!res.ok) {
    // Surface LiveAvatar's actual complaint instead of a blind status code — a 400
    // here is almost always a rejected field (prompt/opening_text), and the body says which.
    const detail = payload?.message ?? payload?.error ?? payload?.data?.message ?? `HTTP ${res.status}`;
    throw new Error(`LiveAvatar context creation failed: ${detail}`);
  }
  const id: string | undefined = payload?.data?.id;
  if (!id) throw new Error('LiveAvatar context response had no id.');
  return id;
}

// Detects Tavus' concurrency-limit rejection (free tier allows only 1 concurrent
// conversation). The previous question's /end can lag behind on Tavus' side, so a fresh
// start briefly races an already-teardown conversation that still counts as active.
function isConcurrencyLimit(detail: string): boolean {
  return /maximum concurrent conversations/i.test(detail);
}

// Reap leftover active conversations so the single free-tier slot is freed. Called only
// when a create is rejected for concurrency — self-heals a lagging or failed prior /end
// without slowing the happy path.
async function endActiveTavusConversations(): Promise<number> {
  const list = await fetch(`${TAVUS_CONVERSATIONS_URL}?status=active`, {
    headers: { 'x-api-key': TAVUS_API_KEY as string },
  });
  const payload = await list.json().catch(() => null);
  const rows: Array<{ conversation_id?: string; status?: string }> = Array.isArray(payload?.data)
    ? payload.data
    : [];
  const active = rows.filter((c) => c.conversation_id && c.status === 'active');
  await Promise.all(
    active.map((c) =>
      fetch(`${TAVUS_CONVERSATIONS_URL}/${c.conversation_id}/end`, {
        method: 'POST',
        headers: { 'x-api-key': TAVUS_API_KEY as string },
      }).catch(() => {}),
    ),
  );
  return active.length;
}

async function createTavusConversation(req: StartRequest): Promise<Response> {
  return fetch(TAVUS_CONVERSATIONS_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'x-api-key': TAVUS_API_KEY as string },
    body: JSON.stringify({
      replica_id: TAVUS_REPLICA_ID,
      persona_id: TAVUS_PERSONA_ID,
      // Tavus uses its OWN default LLM ("its brain"); the script is injected as context.
      conversational_context: timezoneContext(req.timezone) + req.systemPrompt + TAVUS_END_TOOL_INSTRUCTION,
      custom_greeting: req.greeting,
      properties: {
        language: 'italian',
        enable_recording: false,
        // Server-side hard cap so a session can't overrun the per-question budget
        // (fields confirmed in seconds against the Tavus OpenAPI spec).
        max_call_duration: timing.limitSeconds,
        participant_absent_timeout: timing.limitSeconds,
        participant_left_timeout: TAVUS_PARTICIPANT_LEFT_TIMEOUT,
      },
    }),
  });
}

async function startTavus(req: StartRequest): Promise<Response> {
  if (!TAVUS_API_KEY) return json(500, { error: 'Missing TAVUS_API_KEY in .env.' });
  if (!TAVUS_REPLICA_ID || !TAVUS_PERSONA_ID) {
    return json(500, { error: 'Missing TAVUS_REPLICA_ID or TAVUS_PERSONA_ID in .env.' });
  }

  let res = await createTavusConversation(req);
  let payload = await res.json().catch(() => null);

  // Concurrency rejection handling. On the free tier Tavus allows 1 concurrent
  // conversation and releases that slot a few seconds AFTER the prior question's
  // conversation reports 'ended' — so a fresh start briefly races a slot that is
  // gone by status but not yet by accounting. The account often shows ZERO active
  // conversations at this point, so there is nothing to reap: the only thing that
  // works (as confirmed by manual re-click succeeding) is to wait and retry.
  for (let attempt = 0; attempt < TAVUS_CONCURRENCY_RETRIES && !res.ok; attempt++) {
    const detail = String(payload?.message ?? payload?.error ?? `HTTP ${res.status}`);
    if (!isConcurrencyLimit(detail)) break;
    // Best-effort reap in case a genuinely stuck 'active' conversation exists, then wait
    // for Tavus to free the slot before retrying. The wait — not the reap — is the fix.
    await endActiveTavusConversations().catch(() => 0);
    await new Promise((r) => setTimeout(r, TAVUS_CONCURRENCY_BACKOFF_MS));
    res = await createTavusConversation(req);
    payload = await res.json().catch(() => null);
  }
  if (!res.ok) {
    const detail = String(payload?.message ?? payload?.error ?? `HTTP ${res.status}`);
    // Slot still not freed after the retries: surface a friendly, retryable signal instead
    // of a raw 502 so the client can invite the candidate to wait a moment and try again.
    if (isConcurrencyLimit(detail)) {
      return json(429, {
        code: 'provider_busy',
        error:
          'L’avatar sta ancora chiudendo la sessione precedente. Attendi qualche secondo e premi di nuovo “Parla”.',
      });
    }
    throw new Error(`Tavus rejected the conversation request: ${detail}`);
  }
  const conversationUrl: string | undefined = payload?.conversation_url;
  const conversationId: string | null = payload?.conversation_id ?? null;
  if (!conversationUrl) throw new Error('Tavus returned no conversation_url.');

  const dbSessionId = createSession('tavus', conversationId, questions.version, req.meta);
  setProgressSession(req.candidateId, req.questionIndex, dbSessionId);

  return json(200, {
    dbSessionId,
    provider: 'tavus',
    conversationUrl,
    providerSessionId: conversationId,
    ...meta(req),
  });
}

function json(status: number, obj: unknown): Response {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}
