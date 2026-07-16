import type { APIRoute } from 'astro';
import { getSession, getUtterances } from '../../../lib/db';

export const prerender = false;

// Returns the stored transcript for a session (used by the review view / for analysis).
export const GET: APIRoute = async ({ params }) => {
  const id = Number(params.id);
  if (!Number.isInteger(id)) return json(400, { error: 'Invalid id.' });

  const session = getSession(id);
  if (!session) return json(404, { error: 'Session not found.' });

  return json(200, { session, utterances: getUtterances(id) });
};

function json(status: number, obj: unknown): Response {
  return new Response(JSON.stringify(obj), { status, headers: { 'Content-Type': 'application/json' } });
}
