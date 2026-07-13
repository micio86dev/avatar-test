// Soft, silent proctoring collector — provider-agnostic. It lives ABOVE the
// InterviewProvider abstraction (it never touches HeyGen/Tavus), observes integrity
// signals during a live session, and ships them to /api/interview/integrity for later
// HUMAN review. It never blocks the interview. Two layers:
//   Layer 1 — browser: Page Visibility + window focus (truly invisible, no camera).
//   Layer 2 — webcam: an independent getUserMedia({video}) + local MediaPipe FaceLandmarker
//             (face presence, head pose, face count). Frames NEVER leave the browser —
//             only derived event labels + durations are sent.
// Webcam access lights the browser's unsuppressable camera indicator by design; that is
// why the candidate also sees a self-view and consents up front.
import {
  FACE_ABSENT_MS,
  FLUSH_INTERVAL_MS,
  INTEGRITY_LABELS,
  LOOK_AWAY_MS,
  LOOK_AWAY_PITCH_DEG,
  LOOK_AWAY_YAW_DEG,
  MIN_BROWSER_EPISODE_MS,
  MULTI_FACE_MS,
  SAMPLE_FPS,
  type IntegrityEventInput,
  type IntegrityType,
} from '../lib/proctor-config';

// Minimal structural types for @mediapipe/tasks-vision (dynamically imported), so this
// module type-checks without the package resolving eagerly.
interface FaceResult {
  faceLandmarks: unknown[];
  facialTransformationMatrixes?: { data: number[] | Float32Array }[];
}
interface FaceLandmarkerLike {
  detectForVideo(video: HTMLVideoElement, ts: number): FaceResult;
  close(): void;
}

// ── Module state (one collector at a time; the app runs a single session) ──────────
let active = false;
let sessionId: number | null = null;
const buffer: IntegrityEventInput[] = [];

let stream: MediaStream | null = null;
let landmarker: FaceLandmarkerLike | null = null;
let selfView: HTMLVideoElement | null = null;

let sampleTimer: number | null = null;
let flushTimer: number | null = null;

// Open episodes: a signal that is currently ongoing. We emit ONE event on transition
// (when it ends) carrying the duration, instead of one event per sampled frame.
type Ep = { start: number; peak?: number } | null;
let hiddenEp: Ep = null; // tab_hidden
let focusEp: Ep = null; // focus_lost
let faceAbsentEp: Ep = null; // face_absent
let multiFaceEp: Ep = null; // multiple_faces
let lookAwayEp: Ep = null; // looking_away
let lastPose: { yaw: number; pitch: number } | null = null;

function now(): number {
  return Date.now();
}

function push(type: IntegrityType, meta?: Record<string, unknown>): void {
  buffer.push({ type, ts: new Date().toISOString(), meta: meta ?? null });
}

// Close an open episode and, if it lasted at least `minMs`, emit an event with its duration.
function closeEpisode(ep: Ep, type: IntegrityType, minMs: number, extra?: Record<string, unknown>): Ep {
  if (ep) {
    const durationMs = now() - ep.start;
    if (durationMs >= minMs) push(type, { durationMs, ...extra });
  }
  return null;
}

// ── Layer 1: browser focus/visibility (no camera) ──────────────────────────────────
function onVisibility(): void {
  if (document.visibilityState === 'hidden') {
    if (!hiddenEp) hiddenEp = { start: now() };
  } else {
    hiddenEp = closeEpisode(hiddenEp, 'tab_hidden', MIN_BROWSER_EPISODE_MS);
  }
}
function onBlur(): void {
  // Only count as focus_lost when the page is still VISIBLE (app/window switch). A tab
  // switch also fires blur, but it is already captured by onVisibility → avoid double count.
  if (document.visibilityState === 'visible' && !focusEp) focusEp = { start: now() };
}
function onFocus(): void {
  focusEp = closeEpisode(focusEp, 'focus_lost', MIN_BROWSER_EPISODE_MS);
}

// ── Layer 2: webcam face detection ──────────────────────────────────────────────────
// Head orientation proxy from the facial transformation matrix (column-major 4x4). The
// face's forward axis is the 3rd rotation column (m[8], m[9], m[10]); angles vs the camera
// axis give a convention-robust "how far is the face pointing away" without decoding full
// Euler angles. Approximate, sufficient for a triage heuristic.
function poseFromMatrix(data: number[] | Float32Array): { yaw: number; pitch: number } | null {
  if (!data || data.length < 11) return null;
  const fx = data[8];
  const fy = data[9];
  const fz = Math.abs(data[10]) || 1e-6;
  const yaw = (Math.atan2(fx, fz) * 180) / Math.PI;
  const pitch = (Math.atan2(fy, fz) * 180) / Math.PI;
  return { yaw, pitch };
}

function evaluateFrame(faceCount: number, pose: { yaw: number; pitch: number } | null): void {
  const t = now();

  // face_absent — no face at all.
  if (faceCount === 0) {
    if (!faceAbsentEp) faceAbsentEp = { start: t };
  } else {
    faceAbsentEp = closeEpisode(faceAbsentEp, 'face_absent', FACE_ABSENT_MS);
  }

  // multiple_faces — someone else in frame.
  if (faceCount >= 2) {
    if (!multiFaceEp) multiFaceEp = { start: t, peak: faceCount };
    else multiFaceEp.peak = Math.max(multiFaceEp.peak ?? 2, faceCount);
  } else {
    multiFaceEp = closeEpisode(multiFaceEp, 'multiple_faces', MULTI_FACE_MS, {
      count: multiFaceEp?.peak ?? 2,
    });
  }

  // looking_away — exactly one face, turned off-axis (skip when 0 or ≥2 faces).
  const away =
    faceCount === 1 &&
    pose != null &&
    (Math.abs(pose.yaw) >= LOOK_AWAY_YAW_DEG || Math.abs(pose.pitch) >= LOOK_AWAY_PITCH_DEG);
  if (away) {
    lastPose = pose;
    if (!lookAwayEp) lookAwayEp = { start: t };
  } else {
    lookAwayEp = closeEpisode(lookAwayEp, 'looking_away', LOOK_AWAY_MS, {
      yaw: lastPose ? Math.round(lastPose.yaw) : undefined,
      pitch: lastPose ? Math.round(lastPose.pitch) : undefined,
    });
  }
}

function sampleOnce(): void {
  if (!landmarker || !selfView || selfView.readyState < 2) return;
  let result: FaceResult;
  try {
    result = landmarker.detectForVideo(selfView, performance.now());
  } catch {
    return; // transient decode hiccup — skip this frame
  }
  const faceCount = result.faceLandmarks?.length ?? 0;
  const matrix = result.facialTransformationMatrixes?.[0]?.data;
  const pose = faceCount === 1 && matrix ? poseFromMatrix(matrix) : null;
  evaluateFrame(faceCount, pose);
}

async function initCamera(): Promise<void> {
  selfView = document.getElementById('self-view') as HTMLVideoElement | null;
  try {
    stream = await navigator.mediaDevices.getUserMedia({
      video: { width: 320, height: 240, frameRate: 15 },
      audio: false,
    });
  } catch {
    // Camera denied/unavailable → Layer 1 (browser signals) still runs. Not fatal.
    return;
  }
  if (!active) {
    // Session ended while we were awaiting permission — release immediately.
    stream.getTracks().forEach((t) => t.stop());
    stream = null;
    return;
  }
  if (selfView) {
    selfView.srcObject = stream;
    selfView.muted = true;
    selfView.hidden = false;
    void selfView.play().catch(() => {});
  }

  try {
    const vision = await import('@mediapipe/tasks-vision');
    if (!active) return;
    const fileset = await vision.FilesetResolver.forVisionTasks('/proctor/wasm');
    landmarker = (await vision.FaceLandmarker.createFromOptions(fileset, {
      baseOptions: { modelAssetPath: '/proctor/face_landmarker.task' },
      runningMode: 'VIDEO',
      numFaces: 2,
      outputFacialTransformationMatrixes: true,
      outputFaceBlendshapes: false,
    })) as unknown as FaceLandmarkerLike;
  } catch (err) {
    // Model/WASM failed to load → self-view still shows, but no detection. Log for debug.
    console.warn('[proctor] face detection unavailable:', err);
    return;
  }
  if (!active) return;
  sampleTimer = window.setInterval(sampleOnce, Math.round(1000 / SAMPLE_FPS));
}

// ── Transport ────────────────────────────────────────────────────────────────────
async function flush(): Promise<void> {
  if (sessionId == null || buffer.length === 0) return;
  const events = buffer.splice(0, buffer.length);
  try {
    await fetch('/api/interview/integrity', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ sessionId, events }),
      keepalive: true,
    });
  } catch {
    // Best-effort. Re-queue so the next flush (or beacon) retries.
    buffer.unshift(...events);
  }
}

// Close every open episode against "now" — used before a final flush so an interview that
// ends mid-episode (e.g. tab still hidden) still records the duration so far.
function closeAllEpisodes(): void {
  hiddenEp = closeEpisode(hiddenEp, 'tab_hidden', MIN_BROWSER_EPISODE_MS);
  focusEp = closeEpisode(focusEp, 'focus_lost', MIN_BROWSER_EPISODE_MS);
  faceAbsentEp = closeEpisode(faceAbsentEp, 'face_absent', FACE_ABSENT_MS);
  multiFaceEp = closeEpisode(multiFaceEp, 'multiple_faces', MULTI_FACE_MS, {
    count: multiFaceEp?.peak ?? 2,
  });
  lookAwayEp = closeEpisode(lookAwayEp, 'looking_away', LOOK_AWAY_MS, {
    yaw: lastPose ? Math.round(lastPose.yaw) : undefined,
    pitch: lastPose ? Math.round(lastPose.pitch) : undefined,
  });
}

// ── Public API (called from interview-client.ts) ───────────────────────────────────
export function startProctor(id: number): void {
  if (active) return;
  active = true;
  sessionId = id;
  buffer.length = 0;

  // One-shot: extended display present? (best-effort; undefined on unsupported browsers.)
  if ((screen as Screen & { isExtended?: boolean }).isExtended === true) {
    push('second_monitor', { isExtended: true });
  }

  document.addEventListener('visibilitychange', onVisibility);
  window.addEventListener('blur', onBlur);
  window.addEventListener('focus', onFocus);

  void initCamera();
  flushTimer = window.setInterval(() => void flush(), FLUSH_INTERVAL_MS);
}

export function stopProctor(): void {
  if (!active) return;
  active = false;

  document.removeEventListener('visibilitychange', onVisibility);
  window.removeEventListener('blur', onBlur);
  window.removeEventListener('focus', onFocus);

  if (sampleTimer != null) window.clearInterval(sampleTimer);
  if (flushTimer != null) window.clearInterval(flushTimer);
  sampleTimer = null;
  flushTimer = null;

  closeAllEpisodes();
  void flush();

  landmarker?.close();
  landmarker = null;
  stream?.getTracks().forEach((t) => t.stop());
  stream = null;
  if (selfView) {
    selfView.srcObject = null;
    selfView.hidden = true;
  }
  sessionId = null;
}

// Unload path: synchronously close episodes and ship the tail via sendBeacon (fetch is
// unreliable during unload). Mirrors the existing releaseOnUnload pattern for Tavus.
export function beaconProctor(): void {
  if (!active || sessionId == null) return;
  closeAllEpisodes();
  if (buffer.length === 0) return;
  const events = buffer.splice(0, buffer.length);
  const payload = JSON.stringify({ sessionId, events });
  navigator.sendBeacon('/api/interview/integrity', new Blob([payload], { type: 'application/json' }));
}

// Re-exported so callers (and future UI) can label event types without re-importing config.
export { INTEGRITY_LABELS };
