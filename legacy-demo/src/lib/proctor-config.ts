// Shared proctoring constants + risk scoring — imported by BOTH the client collector
// (src/scripts/proctor.ts) and the server scorer (src/lib/db.ts). It holds NO secrets and
// touches no browser-only globals, so it is safe in the browser bundle. astro:env is
// server-only, hence a plain TS module for the values both sides need.

export type IntegrityType =
  | 'tab_hidden' // page became hidden (tab switch / minimize)
  | 'focus_lost' // window lost focus while still visible (app/window switch)
  | 'second_monitor' // an extended display was present at session start
  | 'face_absent' // no face in frame beyond the threshold
  | 'looking_away' // head turned off-axis beyond the threshold
  | 'looking_down' // head sharply tilted downward (reading phone/notes)
  | 'too_far' // face too small in frame — candidate too far from webcam
  | 'multiple_faces' // two or more faces in frame
  | 'fullscreen_exit' // user exited fullscreen during interview
  | 'clipboard_copy' // user copied text
  | 'clipboard_paste' // user pasted text
  | 'second_voice' // another voice detected via mic while avatar is speaking
  | 'phone_detected'; // a mobile phone visible in frame

export const INTEGRITY_TYPES: IntegrityType[] = [
  'tab_hidden',
  'focus_lost',
  'second_monitor',
  'face_absent',
  'looking_away',
  'looking_down',
  'too_far',
  'multiple_faces',
  'fullscreen_exit',
  'clipboard_copy',
  'clipboard_paste',
  'second_voice',
  'phone_detected',
];

// Human-readable labels for the review panel (Italian, user-facing copy).
export const INTEGRITY_LABELS: Record<IntegrityType, string> = {
  tab_hidden: 'Uscita dalla scheda',
  focus_lost: 'Finestra fuori fuoco',
  second_monitor: 'Secondo monitor',
  face_absent: 'Volto assente',
  looking_away: 'Sguardo altrove',
  looking_down: 'Sguardo verso il basso',
  too_far: 'Troppo lontano dalla webcam',
  multiple_faces: 'Più persone',
  fullscreen_exit: 'Uscita dal fullscreen',
  clipboard_copy: 'Copia testo',
  clipboard_paste: 'Incolla testo',
  second_voice: 'Seconda voce rilevata',
  phone_detected: 'Telefono rilevato',
};

export interface IntegrityEventInput {
  type: IntegrityType;
  ts: string; // ISO 8601 UTC, client event time
  meta?: Record<string, unknown> | null;
}

// ── Client detection thresholds ────────────────────────────────────────────────
export const SAMPLE_FPS = 3; // face-detection sampling rate (low → light on CPU/GPU)
export const FLUSH_INTERVAL_MS = 10_000; // buffer flush cadence
export const MIN_BROWSER_EPISODE_MS = 500; // ignore sub-half-second tab/focus flickers
export const FACE_ABSENT_MS = 4_000; // no face this long → face_absent
export const MULTI_FACE_MS = 1_500; // ≥2 faces this long → multiple_faces
export const LOOK_AWAY_MS = 2_500; // head off-axis this long → looking_away
export const LOOK_AWAY_YAW_DEG = 25; // |yaw| beyond this = looking away
export const LOOK_AWAY_PITCH_DEG = 22; // |pitch| beyond this = looking away
export const LOOK_DOWN_PITCH_DEG = 20; // negative pitch below this (downward tilt) = looking_down
export const FACE_MIN_WIDTH_RATIO = 0.20; // face bbox width (0–1 normalized) below this = too_far
export const TOO_FAR_MS = 3_000; // face too small this long → too_far event

export const PHONE_SAMPLE_MS = 2_000;     // run object detection every 2s (CPU-light cadence)
export const PHONE_DETECTED_MS = 3_000;  // phone visible this long → phone_detected event
export const PHONE_SCORE_THRESHOLD = 0.5; // min confidence to count as "cell phone"

export const SNAPSHOT_INTERVAL_MS = 10_000; // periodic webcam capture — one frame every 10s
export const VOICE_RMS_THRESHOLD = 0.04; // mic RMS above this = voice activity
export const SECOND_VOICE_MS = 2_000; // sustained audio this long while avatar speaks → flag

// ── Risk scoring (server, derived at query time) ────────────────────────────────
// Heuristic weights. This is a TRIAGE signal for a human reviewer, NOT proof of cheating.
export interface RiskWeights {
  tabHiddenPerSec: number;
  focusLostPerEvent: number;
  faceAbsentPerSec: number;
  lookingAwayPerSec: number;
  multipleFacesPerSec: number;
  secondMonitor: number;
  fullscreenExitPerEvent: number;
  clipboardCopyPerEvent: number;
  clipboardPastePerEvent: number;
  secondVoicePerSec: number;
}
export const RISK_WEIGHTS: RiskWeights = {
  tabHiddenPerSec: 1.0,
  focusLostPerEvent: 3,
  faceAbsentPerSec: 0.5,
  lookingAwayPerSec: 0.4,
  multipleFacesPerSec: 4,
  secondMonitor: 8,
  fullscreenExitPerEvent: 5,
  clipboardCopyPerEvent: 4,
  clipboardPastePerEvent: 6,
  secondVoicePerSec: 3.0,
};
// score < medium → low; medium ≤ score < high → medium; score ≥ high → high.
export const RISK_BANDS = { medium: 15, high: 40 } as const;
export type RiskBand = 'low' | 'medium' | 'high';

export interface IntegritySummary {
  score: number;
  band: RiskBand;
  counts: Record<string, number>;
  tabHiddenSec: number;
  faceAbsentSec: number;
  lookingAwaySec: number;
  multipleFacesSec: number;
  secondMonitor: boolean;
  total: number;
  fullscreenExits: number;
  clipboardCopies: number;
  clipboardPastes: number;
  secondVoiceSec: number;
}

interface ScoreableEvent {
  type: string;
  meta?: Record<string, unknown> | null;
}

function durSec(meta: Record<string, unknown> | null | undefined): number {
  const ms = Number(meta?.durationMs);
  return Number.isFinite(ms) && ms > 0 ? ms / 1000 : 0;
}

// Pure aggregation over a session's integrity events → weighted score + band. Kept pure
// (no I/O) so it is trivially unit-testable and reused verbatim by the review page.
export function summarizeIntegrity(events: ScoreableEvent[]): IntegritySummary {
  const counts: Record<string, number> = {};
  let tabHiddenSec = 0;
  let faceAbsentSec = 0;
  let lookingAwaySec = 0;
  let multipleFacesSec = 0;
  let secondVoiceSec = 0;
  let secondMonitor = false;

  for (const e of events) {
    counts[e.type] = (counts[e.type] ?? 0) + 1;
    switch (e.type) {
      case 'tab_hidden':
        tabHiddenSec += durSec(e.meta);
        break;
      case 'face_absent':
        faceAbsentSec += durSec(e.meta);
        break;
      case 'looking_away':
        lookingAwaySec += durSec(e.meta);
        break;
      case 'multiple_faces':
        multipleFacesSec += durSec(e.meta);
        break;
      case 'second_voice':
        secondVoiceSec += durSec(e.meta);
        break;
      case 'second_monitor':
        if (e.meta?.isExtended === true) secondMonitor = true;
        break;
    }
  }

  const w = RISK_WEIGHTS;
  const score =
    tabHiddenSec * w.tabHiddenPerSec +
    (counts.focus_lost ?? 0) * w.focusLostPerEvent +
    faceAbsentSec * w.faceAbsentPerSec +
    lookingAwaySec * w.lookingAwayPerSec +
    multipleFacesSec * w.multipleFacesPerSec +
    secondVoiceSec * w.secondVoicePerSec +
    (secondMonitor ? w.secondMonitor : 0) +
    (counts.fullscreen_exit ?? 0) * w.fullscreenExitPerEvent +
    (counts.clipboard_copy ?? 0) * w.clipboardCopyPerEvent +
    (counts.clipboard_paste ?? 0) * w.clipboardPastePerEvent;

  const band: RiskBand =
    score >= RISK_BANDS.high ? 'high' : score >= RISK_BANDS.medium ? 'medium' : 'low';

  return {
    score: Math.round(score * 10) / 10,
    band,
    counts,
    tabHiddenSec: Math.round(tabHiddenSec),
    faceAbsentSec: Math.round(faceAbsentSec),
    lookingAwaySec: Math.round(lookingAwaySec),
    multipleFacesSec: Math.round(multipleFacesSec),
    secondMonitor,
    total: events.length,
    fullscreenExits: counts.fullscreen_exit ?? 0,
    clipboardCopies: counts.clipboard_copy ?? 0,
    clipboardPastes: counts.clipboard_paste ?? 0,
    secondVoiceSec: Math.round(secondVoiceSec),
  };
}
