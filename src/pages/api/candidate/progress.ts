import type { APIRoute } from 'astro';
import { setProgressStatus, getCandidateById, type ProgressStatus } from '../../../lib/db';

export const prerender = false;

const VALID: ProgressStatus[] = ['pending', 'completed', 'timeout', 'skipped'];

// Explicitly set a question's status. Used by the end-of-question screen's
// "Prossima domanda" to mark the current question 'completed'.
export const POST: APIRoute = async ({ request }) => {
  const body = (await request.json().catch(() => null)) as
    | { candidateId?: unknown; questionIndex?: unknown; status?: unknown }
    | null;

  const candidateId = Number(body?.candidateId);
  const questionIndex = Number(body?.questionIndex);
  const status = body?.status as ProgressStatus;

  if (!Number.isInteger(candidateId) || !Number.isInteger(questionIndex)) {
    return json(400, { error: 'Invalid candidateId or questionIndex.' });
  }
  if (!VALID.includes(status)) return json(400, { error: 'Invalid status.' });
  if (!getCandidateById(candidateId)) return json(404, { error: 'Unknown candidate.' });

  setProgressStatus(candidateId, questionIndex, status);
  return json(200, { ok: true });
};

function json(status: number, obj: unknown): Response {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}
