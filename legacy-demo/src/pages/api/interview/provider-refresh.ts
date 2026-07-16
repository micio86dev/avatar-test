import type { APIRoute } from 'astro';
import { LIVEAVATAR_API_KEY, TAVUS_API_KEY } from 'astro:env/server';
import { getSession } from '../../../lib/db';
import { fetchTavusMeta, fetchHeyGenMeta } from './end';

export const prerender = false;

export const POST: APIRoute = async ({ request }) => {
  const body = (await request.json().catch(() => null)) as { sessionId?: unknown } | null;
  const sessionId = Number(body?.sessionId);
  if (!Number.isInteger(sessionId)) {
    return json(400, { error: 'Invalid sessionId.' });
  }

  const session = getSession(sessionId);
  if (!session) return json(404, { error: 'Session not found.' });

  const { provider, provider_session_id: pid } = session;
  if (provider === 'tavus' && pid && TAVUS_API_KEY) {
    await fetchTavusMeta(sessionId, pid, TAVUS_API_KEY);
  } else if (provider === 'heygen' && pid && LIVEAVATAR_API_KEY) {
    await fetchHeyGenMeta(sessionId, pid, LIVEAVATAR_API_KEY);
  } else {
    return json(400, { error: 'No provider session ID stored for this session.' });
  }

  return json(200, { ok: true });
};

function json(status: number, obj: unknown): Response {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}
