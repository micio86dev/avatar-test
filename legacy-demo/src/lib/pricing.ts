// Cost rates for the provider-aware comparison meter. Defaults are verified 2026
// figures; each can be overridden via a (non-secret) env var without code changes.
// These are surfaced to the client in the /api/interview/start response so the live
// meter can estimate "≈ $ this session" for whichever provider is running.
import { TAVUS_USD_PER_MIN, HEYGEN_USD_PER_CREDIT, HEYGEN_CREDITS_PER_MIN } from 'astro:env/server';

function num(v: string, fallback: number): number {
  const n = Number(v);
  return Number.isFinite(n) && n > 0 ? n : fallback;
}

export interface Rates {
  // HeyGen bills in credits; FULL mode = 2 credits/min, ~$0.10/credit overage.
  heygenCreditsPerMin: number;
  heygenUsdPerCredit: number;
  // Tavus bills per conversational minute; Basic/Starter overage = $0.37/min
  // (source: tavus.io/pricing). No API exposes the balance, so Tavus is estimate-only.
  tavusUsdPerMin: number;
}

export const rates: Rates = {
  heygenCreditsPerMin: num(HEYGEN_CREDITS_PER_MIN, 2),
  heygenUsdPerCredit: num(HEYGEN_USD_PER_CREDIT, 0.1),
  tavusUsdPerMin: num(TAVUS_USD_PER_MIN, 0.37),
};
