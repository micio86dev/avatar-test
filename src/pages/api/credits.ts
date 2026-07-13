import type { APIRoute } from 'astro';
import { LIVEAVATAR_API_KEY } from 'astro:env/server';

// On-demand: reads the REAL HeyGen credit balance server-side so the API key never
// reaches the browser. The client polls this to anchor its live cost meter (HeyGen).
export const prerender = false;

const CREDITS_URL = 'https://api.liveavatar.com/v1/users/credits';

export const GET: APIRoute = async () => {
  if (!LIVEAVATAR_API_KEY) {
    return json(500, { error: 'Missing LIVEAVATAR_API_KEY in .env (server-side).' });
  }

  let upstream: Response;
  try {
    upstream = await fetch(CREDITS_URL, { headers: { 'X-API-KEY': LIVEAVATAR_API_KEY } });
  } catch (err) {
    return json(502, { error: `Cannot reach LiveAvatar: ${String(err)}` });
  }

  const payload = await upstream.json().catch(() => null);
  if (!upstream.ok) {
    return json(upstream.status, { error: 'Reading credits failed.', detail: payload });
  }

  // API returns credits_left (string) — accept it wrapped in data or at top level.
  const raw = payload?.data?.credits_left ?? payload?.credits_left;
  const credits = Number(raw);
  if (!Number.isFinite(credits)) {
    return json(502, { error: 'Invalid credits response.', detail: payload });
  }

  return json(200, { credits_left: credits });
};

function json(status: number, obj: unknown): Response {
  return new Response(JSON.stringify(obj), { status, headers: { 'Content-Type': 'application/json' } });
}
