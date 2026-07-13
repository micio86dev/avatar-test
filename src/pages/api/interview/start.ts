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

// Tavus-only: after its closing phrase the persona calls the end_interview tool (registered
// once on the PAL). It reaches the client as a conversation.tool_call app-message and drives
// the soft auto-advance. HeyGen has no equivalent hook, so this instruction is Tavus-scoped.
const TAVUS_END_TOOL_INSTRUCTION =
  '\n\nDopo la tua frase di conclusione per questa domanda, chiama SUBITO lo strumento ' +
  'end_interview per segnalare che hai finito. Non annunciarlo: chiamalo in silenzio.';

interface StartRequest {
  candidateId: number;
  questionIndex: number;
  questionId: string;
  systemPrompt: string;
  greeting: string;
  meta: SessionMeta;
}

// Parse + validate the request, then compose the per-question Italian context. Returns
// either a ready-to-use StartRequest or an error Response.
function prepare(
  body: { candidateId?: unknown; questionIndex?: unknown } | null,
): StartRequest | Response {
  const candidateId = Number(body?.candidateId);
  const questionIndex = Number(body?.questionIndex);

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
    meta: { candidateId, questionId: question.id, questionIndex },
  };
}

export const POST: APIRoute = async ({ request, url }) => {
  const body = (await request.json().catch(() => null)) as
    | { candidateId?: unknown; questionIndex?: unknown; provider?: unknown }
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
  const contextId = await createHeygenContext(req.systemPrompt, req.greeting, req.questionId, req.candidateId);

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

async function startTavus(req: StartRequest): Promise<Response> {
  if (!TAVUS_API_KEY) return json(500, { error: 'Missing TAVUS_API_KEY in .env.' });
  if (!TAVUS_REPLICA_ID || !TAVUS_PERSONA_ID) {
    return json(500, { error: 'Missing TAVUS_REPLICA_ID or TAVUS_PERSONA_ID in .env.' });
  }

  const res = await fetch(TAVUS_CONVERSATIONS_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'x-api-key': TAVUS_API_KEY },
    body: JSON.stringify({
      replica_id: TAVUS_REPLICA_ID,
      persona_id: TAVUS_PERSONA_ID,
      // Tavus uses its OWN default LLM ("its brain"); the script is injected as context.
      conversational_context: req.systemPrompt + TAVUS_END_TOOL_INSTRUCTION,
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
  const payload = await res.json().catch(() => null);
  if (!res.ok) {
    const detail = payload?.message ?? payload?.error ?? `HTTP ${res.status}`;
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
