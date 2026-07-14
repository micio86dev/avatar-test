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
  FACE_MIN_WIDTH_RATIO,
  FLUSH_INTERVAL_MS,
  INTEGRITY_LABELS,
  LOOK_AWAY_MS,
  LOOK_AWAY_PITCH_DEG,
  LOOK_AWAY_YAW_DEG,
  LOOK_DOWN_PITCH_DEG,
  MIN_BROWSER_EPISODE_MS,
  MULTI_FACE_MS,
  PHONE_DETECTED_MS,
  PHONE_SAMPLE_MS,
  PHONE_SCORE_THRESHOLD,
  SAMPLE_FPS,
  SECOND_VOICE_MS,
  SNAPSHOT_INTERVAL_MS,
  TOO_FAR_MS,
  VOICE_RMS_THRESHOLD,
  type IntegrityEventInput,
  type IntegrityType,
} from '../lib/proctor-config';

// Minimal structural types for @mediapipe/tasks-vision (dynamically imported), so this
// module type-checks without the package resolving eagerly.
interface FaceLandmark { x: number; y: number; z: number }
interface FaceResult {
  faceLandmarks: FaceLandmark[][];
  facialTransformationMatrixes?: { data: number[] | Float32Array }[];
}
interface FaceLandmarkerLike {
  detectForVideo(video: HTMLVideoElement, ts: number): FaceResult;
  close(): void;
}
interface PhoneDetectionResult {
  detections: Array<{ categories: Array<{ categoryName: string; score: number }> }>;
}
interface ObjectDetectorLike {
  detectForVideo(video: HTMLVideoElement, ts: number): PhoneDetectionResult;
  close(): void;
}

// ── Module state (one collector at a time; the app runs a single session) ──────────
let active = false;
let sessionId: number | null = null;
const buffer: IntegrityEventInput[] = [];

let stream: MediaStream | null = null;
// Landmarker is cached across sessions — the model loads once (~3–5s) and is reused.
let landmarker: FaceLandmarkerLike | null = null;
let landmarkerPromise: Promise<FaceLandmarkerLike | null> | null = null;
// ObjectDetector for phone detection — also cached, loads in background after face detection.
let objectDetector: ObjectDetectorLike | null = null;
let objectDetectorPromise: Promise<ObjectDetectorLike | null> | null = null;
let selfView: HTMLVideoElement | null = null;

let sampleTimer: number | null = null;
let phoneSampleTimer: number | null = null;
let flushTimer: number | null = null;
let snapshotTimer: number | null = null;

// ── Layer 3: audio anomaly (separate mic stream + WebAudio) ──────────────────────
// With echoCancellation: true, the avatar's voice (from speakers) is suppressed.
// Any sustained RMS above threshold while the avatar is talking = second person nearby.
let audioCtx: AudioContext | null = null;
let micStream: MediaStream | null = null;
let analyserNode: AnalyserNode | null = null;
let audioDataArray: Uint8Array<ArrayBuffer> | null = null;
let audioSampleTimer: number | null = null;
let avatarSpeaking = false;
let secondVoiceEp: Ep = null;

export function setAvatarSpeaking(speaking: boolean): void {
  avatarSpeaking = speaking;
}

// ── Violation callback ────────────────────────────────────────────────────────────
let violationCb: ((type: IntegrityType, label: string) => void) | null = null;
export function setViolationCallback(cb: (type: IntegrityType, label: string) => void): void {
  violationCb = cb;
}

// Open episodes: a signal that is currently ongoing. We emit ONE event on transition
// (when it ends) carrying the duration, instead of one event per sampled frame.
type Ep = { start: number; peak?: number } | null;
let hiddenEp: Ep = null; // tab_hidden
let focusEp: Ep = null; // focus_lost
let faceAbsentEp: Ep = null; // face_absent
let multiFaceEp: Ep = null; // multiple_faces
let lookAwayEp: Ep = null; // looking_away
let lookDownEp: Ep = null; // looking_down
let tooFarEp: Ep = null; // too_far
let phoneEp: Ep = null; // phone_detected
let lastPose: { yaw: number; pitch: number } | null = null;

function now(): number {
  return Date.now();
}

const VIOLATION_CB_TYPES = new Set<IntegrityType>([
  'tab_hidden',
  'focus_lost',
  'fullscreen_exit',
  'clipboard_copy',
  'clipboard_paste',
  'face_absent',
  'looking_down',
  'too_far',
  'multiple_faces',
  'second_voice',
  'phone_detected',
]);

function push(type: IntegrityType, meta?: Record<string, unknown>): void {
  buffer.push({ type, ts: new Date().toISOString(), meta: meta ?? null });
  if (violationCb && VIOLATION_CB_TYPES.has(type)) {
    violationCb(type, INTEGRITY_LABELS[type]);
  }
  if (SNAPSHOT_ON_EVENT_TYPES.has(type)) {
    void takeSnapshot(type); // capture visual evidence at the moment of the event
  }
}

// Close an open episode and, if it lasted at least `minMs`, emit an event with its duration.
function closeEpisode(ep: Ep, type: IntegrityType, minMs: number, extra?: Record<string, unknown>): Ep {
  if (ep) {
    const durationMs = now() - ep.start;
    if (durationMs >= minMs) push(type, { durationMs, ...extra });
  }
  return null;
}

// ── Fullscreen detection ─────────────────────────────────────────────────────────
function onFullscreenChange(): void {
  if (!document.fullscreenElement && active) {
    push('fullscreen_exit');
  }
}

// ── Copy/paste detection ─────────────────────────────────────────────────────────
function onCopy(): void { if (active) push('clipboard_copy'); }
function onPaste(): void { if (active) push('clipboard_paste'); }

// ── Webcam snapshot (periodic + event-triggered) ─────────────────────────────────
// Types that cause an immediate snapshot on top of the periodic stream.
const SNAPSHOT_ON_EVENT_TYPES = new Set<IntegrityType>([
  'face_absent',
  'multiple_faces',
  'looking_away',
  'looking_down',
  'too_far',
  'phone_detected',
  'second_voice',
]);

async function takeSnapshot(trigger?: string): Promise<void> {
  if (!selfView || selfView.readyState < 2 || sessionId == null) return;
  const canvas = document.createElement('canvas');
  canvas.width = selfView.videoWidth || 320;
  canvas.height = selfView.videoHeight || 240;
  const ctx = canvas.getContext('2d');
  if (!ctx) return;
  ctx.drawImage(selfView, 0, 0);
  const jpeg = canvas.toDataURL('image/jpeg', 0.7);
  try {
    await fetch('/api/interview/snapshot', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ sessionId, image: jpeg, ts: new Date().toISOString(), trigger: trigger ?? null }),
      keepalive: true,
    });
  } catch { /* best-effort */ }
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

// ── Layer 3: audio sampling ───────────────────────────────────────────────────────
function sampleAudio(): void {
  if (!analyserNode || !audioDataArray) return;
  analyserNode.getByteTimeDomainData(audioDataArray);
  let sum = 0;
  for (let i = 0; i < audioDataArray.length; i++) {
    const v = (audioDataArray[i] - 128) / 128;
    sum += v * v;
  }
  const rms = Math.sqrt(sum / audioDataArray.length);

  if (avatarSpeaking && rms > VOICE_RMS_THRESHOLD) {
    if (!secondVoiceEp) secondVoiceEp = { start: now() };
  } else {
    secondVoiceEp = closeEpisode(secondVoiceEp, 'second_voice', SECOND_VOICE_MS);
  }
}

async function initAudio(): Promise<void> {
  try {
    micStream = await navigator.mediaDevices.getUserMedia({
      audio: { echoCancellation: true, noiseSuppression: true },
      video: false,
    });
  } catch {
    return; // mic denied — Layer 1+2 still run
  }
  if (!active) {
    micStream.getTracks().forEach((t) => t.stop());
    micStream = null;
    return;
  }
  audioCtx = new AudioContext();
  analyserNode = audioCtx.createAnalyser();
  analyserNode.fftSize = 256;
  audioDataArray = new Uint8Array(analyserNode.frequencyBinCount);
  audioCtx.createMediaStreamSource(micStream).connect(analyserNode);
  audioSampleTimer = window.setInterval(sampleAudio, 500);
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

function evaluateFrame(faceCount: number, pose: { yaw: number; pitch: number } | null, faceWidth = 0): void {
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

  // looking_down — head sharply tilted downward (negative pitch), one face only.
  const down = faceCount === 1 && pose != null && pose.pitch < -LOOK_DOWN_PITCH_DEG;
  if (down) {
    if (!lookDownEp) lookDownEp = { start: t };
  } else {
    lookDownEp = closeEpisode(lookDownEp, 'looking_down', LOOK_AWAY_MS, {
      pitch: pose ? Math.round(pose.pitch) : undefined,
    });
  }

  // too_far — face bounding-box width below threshold; only when exactly one face detected.
  const farAway = faceCount === 1 && faceWidth > 0 && faceWidth < FACE_MIN_WIDTH_RATIO;
  if (farAway) {
    if (!tooFarEp) tooFarEp = { start: t };
  } else {
    tooFarEp = closeEpisode(tooFarEp, 'too_far', TOO_FAR_MS);
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
  const faces = result.faceLandmarks ?? [];
  const faceCount = faces.length;
  const matrix = result.facialTransformationMatrixes?.[0]?.data;
  const pose = faceCount === 1 && matrix ? poseFromMatrix(matrix) : null;
  // Face bounding-box width (normalized 0–1) as a proxy for camera distance.
  let faceWidth = 0;
  if (faceCount === 1 && faces[0]) {
    let minX = 1, maxX = 0;
    for (const l of faces[0]) {
      if (l.x < minX) minX = l.x;
      if (l.x > maxX) maxX = l.x;
    }
    faceWidth = maxX - minX;
  }
  evaluateFrame(faceCount, pose, faceWidth);
}

// Loads the MediaPipe ObjectDetector (EfficientDet-Lite0) once and caches it. Phone
// detection runs at a slower cadence than face detection to keep CPU load light.
function ensureObjectDetector(): Promise<ObjectDetectorLike | null> {
  if (objectDetector) return Promise.resolve(objectDetector);
  if (!objectDetectorPromise) {
    objectDetectorPromise = (async () => {
      try {
        const vision = await import('@mediapipe/tasks-vision');
        const fileset = await vision.FilesetResolver.forVisionTasks('/proctor/wasm');
        objectDetector = (await vision.ObjectDetector.createFromOptions(fileset, {
          baseOptions: { modelAssetPath: '/proctor/efficientdet_lite0.tflite' },
          runningMode: 'VIDEO',
          scoreThreshold: PHONE_SCORE_THRESHOLD,
          categoryAllowlist: ['cell phone'],
        })) as unknown as ObjectDetectorLike;
        return objectDetector;
      } catch (err) {
        console.warn('[proctor] phone detection unavailable:', err);
        objectDetectorPromise = null;
        return null;
      }
    })();
  }
  return objectDetectorPromise;
}

function samplePhone(): void {
  if (!objectDetector || !selfView || selfView.readyState < 2) return;
  try {
    const result = objectDetector.detectForVideo(selfView, performance.now());
    // categoryAllowlist ensures every returned detection IS a cell phone — just check count.
    if (result.detections.length > 0) {
      if (!phoneEp) phoneEp = { start: now() };
    } else {
      phoneEp = closeEpisode(phoneEp, 'phone_detected', PHONE_DETECTED_MS);
    }
  } catch { /* transient */ }
}

// Loads the MediaPipe FaceLandmarker once and caches it for the page lifetime so that
// subsequent sessions and warmupCamera() reuse the same model instance.
function ensureLandmarker(): Promise<FaceLandmarkerLike | null> {
  if (landmarker) return Promise.resolve(landmarker);
  if (!landmarkerPromise) {
    landmarkerPromise = (async () => {
      try {
        const vision = await import('@mediapipe/tasks-vision');
        const fileset = await vision.FilesetResolver.forVisionTasks('/proctor/wasm');
        landmarker = (await vision.FaceLandmarker.createFromOptions(fileset, {
          baseOptions: { modelAssetPath: '/proctor/face_landmarker.task' },
          runningMode: 'VIDEO',
          numFaces: 2,
          outputFacialTransformationMatrixes: true,
          outputFaceBlendshapes: false,
        })) as unknown as FaceLandmarkerLike;
        return landmarker;
      } catch (err) {
        console.warn('[proctor] face detection unavailable:', err);
        landmarkerPromise = null; // allow retry on next call
        return null;
      }
    })();
  }
  return landmarkerPromise;
}

async function initCamera(): Promise<void> {
  selfView = document.getElementById('self-view') as HTMLVideoElement | null;
  // Reuse the stream opened by warmupCamera() if it already has the camera.
  if (!stream) {
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
  }
  // Start periodic snapshot timer as soon as the stream is live (even if the landmarker fails).
  snapshotTimer = window.setInterval(() => void takeSnapshot(), SNAPSHOT_INTERVAL_MS);
  const lm = await ensureLandmarker();
  if (!active || !lm) return;
  sampleTimer = window.setInterval(sampleOnce, Math.round(1000 / SAMPLE_FPS));

  // Phone detection — loads in parallel, doesn't block face detection if it fails.
  void ensureObjectDetector().then((od) => {
    if (!active || !od) return;
    phoneSampleTimer = window.setInterval(samplePhone, PHONE_SAMPLE_MS);
  });
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
  lookDownEp = closeEpisode(lookDownEp, 'looking_down', LOOK_AWAY_MS);
  tooFarEp = closeEpisode(tooFarEp, 'too_far', TOO_FAR_MS);
  phoneEp = closeEpisode(phoneEp, 'phone_detected', PHONE_DETECTED_MS);
  secondVoiceEp = closeEpisode(secondVoiceEp, 'second_voice', SECOND_VOICE_MS);
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
  document.addEventListener('fullscreenchange', onFullscreenChange);
  document.addEventListener('copy', onCopy);
  document.addEventListener('paste', onPaste);

  void initCamera();
  void initAudio();
  flushTimer = window.setInterval(() => void flush(), FLUSH_INTERVAL_MS);
}

export function stopProctor(): void {
  if (!active) return;
  active = false;

  document.removeEventListener('visibilitychange', onVisibility);
  window.removeEventListener('blur', onBlur);
  window.removeEventListener('focus', onFocus);
  document.removeEventListener('fullscreenchange', onFullscreenChange);
  document.removeEventListener('copy', onCopy);
  document.removeEventListener('paste', onPaste);

  if (sampleTimer != null) window.clearInterval(sampleTimer);
  if (phoneSampleTimer != null) window.clearInterval(phoneSampleTimer);
  if (flushTimer != null) window.clearInterval(flushTimer);
  if (snapshotTimer != null) window.clearInterval(snapshotTimer);
  if (audioSampleTimer != null) window.clearInterval(audioSampleTimer);
  sampleTimer = null;
  phoneSampleTimer = null;
  flushTimer = null;
  snapshotTimer = null;
  audioSampleTimer = null;
  micStream?.getTracks().forEach((t) => t.stop());
  micStream = null;
  analyserNode = null;
  audioDataArray = null;
  void audioCtx?.close();
  audioCtx = null;
  avatarSpeaking = false;

  closeAllEpisodes();
  void flush();

  // Keep landmarker loaded — model caches for the page lifetime (first load ~3–5s).
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

// Pre-session camera check: opens the webcam + face landmarker in the background so
// the candidate can adjust their position BEFORE the interview starts. Calls onResult
// continuously with true (face close enough) or false (absent/too far). Returns a
// cleanup function the caller must invoke before startProctor() takes over — the open
// camera stream is left at module scope so initCamera() reuses it without a second
// getUserMedia() call.
export function warmupCamera(onResult: (faceOk: boolean) => void): () => void {
  let localStream: MediaStream | null = null;
  let localSelfView: HTMLVideoElement | null = null;
  let stopped = false;
  let warmupTimer: number | null = null;

  const init = async (): Promise<void> => {
    localSelfView = document.getElementById('self-view') as HTMLVideoElement | null;

    if (!stream) {
      let opened: MediaStream;
      try {
        opened = await navigator.mediaDevices.getUserMedia({
          video: { width: 320, height: 240, frameRate: 15 },
          audio: false,
        });
      } catch {
        onResult(true); // camera unavailable — don't block the interview
        return;
      }
      if (stopped) { opened.getTracks().forEach((t) => t.stop()); return; }
      localStream = opened;
      stream = localStream; // make available to initCamera()
      if (localSelfView) {
        localSelfView.srcObject = stream;
        localSelfView.muted = true;
        localSelfView.hidden = false;
        void localSelfView.play().catch(() => {});
      }
    }

    const lm = await ensureLandmarker();
    if (stopped) return;
    if (!lm) { onResult(true); return; } // no model — don't block

    const target = localSelfView;
    warmupTimer = window.setInterval(() => {
      if (!target || target.readyState < 2) return;
      try {
        const result = lm.detectForVideo(target, performance.now());
        const faces = result.faceLandmarks ?? [];
        if (faces.length === 0) { onResult(false); return; }
        let minX = 1, maxX = 0;
        for (const l of faces[0]) {
          if (l.x < minX) minX = l.x;
          if (l.x > maxX) maxX = l.x;
        }
        onResult(maxX - minX >= FACE_MIN_WIDTH_RATIO);
      } catch { /* transient */ }
    }, 500);
  };

  void init();

  return () => {
    stopped = true;
    if (warmupTimer != null) window.clearInterval(warmupTimer);
    warmupTimer = null;
    // Only release the camera if the proctor hasn't taken it over yet.
    if (!active && localStream) {
      localStream.getTracks().forEach((t) => t.stop());
      if (stream === localStream) stream = null;
      localStream = null;
      if (localSelfView) { localSelfView.srcObject = null; localSelfView.hidden = true; }
    }
  };
}

export async function enterFullscreen(): Promise<void> {
  try {
    await document.documentElement.requestFullscreen();
  } catch { /* ignored — unsupported or denied */ }
}

// Re-exported so callers (and future UI) can label event types without re-importing config.
export { INTEGRITY_LABELS };
