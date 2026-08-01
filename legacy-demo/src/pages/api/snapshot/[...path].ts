import type { APIRoute } from 'astro';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

export const prerender = false;

const SNAPSHOTS_DIR = process.env.SNAPSHOTS_PATH
  ? resolve(process.env.SNAPSHOTS_PATH)
  : resolve(process.cwd(), 'data', 'snapshots');

export const GET: APIRoute = ({ params }) => {
  const rawPath = params.path ?? '';
  if (!rawPath || rawPath.includes('..') || !/^[\w\-./]+$/.test(rawPath)) {
    return new Response('Forbidden', { status: 403 });
  }
  const filePath = resolve(SNAPSHOTS_DIR, rawPath);
  if (!filePath.startsWith(SNAPSHOTS_DIR + '/')) {
    return new Response('Forbidden', { status: 403 });
  }
  try {
    const data = readFileSync(filePath);
    return new Response(data, {
      status: 200,
      headers: {
        'Content-Type': 'image/jpeg',
        'Cache-Control': 'public, max-age=31536000, immutable',
      },
    });
  } catch {
    return new Response('Not Found', { status: 404 });
  }
};
