// Per-question timing budget. Each interview question runs as its own short session with
// a countdown; SESSION_TIME_LIMIT_SECONDS is deliberately under a 5:00 provider cap so a
// session never overruns. These are read server-side and RETURNED to the client in the
// /api/interview/start response (the browser can't read server secrets), and also drive
// the Tavus server-side hard caps. Overridable via env; defaults mirror the plan.
import { SESSION_TIME_LIMIT_SECONDS, SESSION_WARN_SECONDS } from 'astro:env/server';

function int(v: string, fallback: number): number {
  const n = Number(v);
  return Number.isFinite(n) && n > 0 ? Math.floor(n) : fallback;
}

export interface Timing {
  limitSeconds: number; // total budget per question
  warnSeconds: number; // countdown turns amber at/under this remaining
}

export const timing: Timing = {
  limitSeconds: int(SESSION_TIME_LIMIT_SECONDS, 285), // 4:45, under a 5:00 cap
  warnSeconds: int(SESSION_WARN_SECONDS, 60),
};
