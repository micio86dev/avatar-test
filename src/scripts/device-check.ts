// Pre-join device check: a single-page, self-service webcam + microphone test the
// candidate runs on the "Prima di iniziare" screen before entering the interview.
//
// It is a HARD GATE: the "Entra nel colloquio" CTA stays disabled until BOTH the camera
// (frames flowing + a face detected) and the microphone (level has crossed a "you spoke"
// threshold) are confirmed working.
//
// Camera ownership: this module does NOT open a second competing video stream. It reuses
// the proctor's `warmupCamera()`, which opens the webcam once, stores it at proctor module
// scope, and hands it off to the live interview via `startProctor()`/`initCamera()`. We only
// mirror that same MediaStream into our local preview element. The microphone, by contrast,
// is opened here as an independent audio-only stream purely to drive the level meter — the
// proctor opens its own mic stream separately at session start, so there is no conflict.

import { warmupCamera, type WarmupStatus } from './proctor';

// ── Tunables ───────────────────────────────────────────────────────────────────────
// RMS level (0..1) above which the mic bar turns green and the level is considered
// "adequate". Latching `micOk` happens on the first frame that reaches this level.
const MIC_SPEAK_THRESHOLD = 0.08;
// The self-view element that `warmupCamera()` attaches the camera MediaStream to. We poll
// its `srcObject` and mirror it into our own preview so we never open the camera twice.
const PROCTOR_SELF_VIEW_ID = 'self-view';
// How long to wait for a live camera stream before assuming it was denied/unavailable.
// warmupCamera() swallows camera errors (never attaches a stream), so we detect the absence.
const CAMERA_TIMEOUT_MS = 6000;

// ── Element wiring ──────────────────────────────────────────────────────────────────
export interface DeviceCheckElements {
  /** Live webcam preview. Receives the proctor's camera stream (mirrored, muted). */
  preview: HTMLVideoElement;
  /** The fill element inside the mic level bar (its width + color are driven each frame). */
  micBarFill: HTMLElement;
  /** Camera status indicator — gets `data-ok="true"` once the webcam is actually streaming. */
  cameraStatus: HTMLElement;
  /** Distance status indicator — gets `data-ok="true"` once the face is close enough. */
  distanceStatus: HTMLElement;
  /** Gaze status indicator — gets `data-ok="true"` once the candidate looks at the camera. */
  gazeStatus: HTMLElement;
  /** Microphone status indicator — gets `data-ok="true"` once the user has spoken. */
  micStatus: HTMLElement;
  /** Permission-denied guidance block (Italian copy), hidden until a denial occurs. */
  deniedBox: HTMLElement;
  /**
   * Live positioning nudge. Its `data-hint-far` / `data-hint-gaze` attributes hold the
   * Italian copy; this module only copies those attribute values into `textContent`.
   */
  hint: HTMLElement;
}

export interface DeviceCheckHandle {
  /**
   * Stop the mic meter (RAF + AudioContext) and detach the preview.
   *
   * @param keepCamera When `true` (interview-entry handoff), the camera warmup and its open
   *   MediaStream are left running so the interview reuses the same camera — one stream, no
   *   second `getUserMedia`. The caller then owns the returned warmup cleanup via
   *   `cameraWarmupCleanup`. When `false` (reset/abandon), the warmup is torn down and the
   *   camera released.
   * Safe to call multiple times.
   */
  stop(keepCamera?: boolean): void;
  /**
   * The proctor `warmupCamera` cleanup for the camera opened during this check. After a
   * `stop(true)` handoff the caller MUST own this and invoke it exactly where it would have
   * invoked the interview's own warmup cleanup, so the single shared camera stream is released
   * once (and only once) at end of session.
   */
  readonly cameraWarmupCleanup: () => void;
}

// ── Public API ──────────────────────────────────────────────────────────────────────
// Starts the device check. `onReady` is invoked once (and only once) the moment BOTH camera
// and mic are confirmed — the caller uses it to reveal/enable the "Entra nel colloquio" CTA.
export function startDeviceCheck(
  els: DeviceCheckElements,
  onReady: () => void,
): DeviceCheckHandle {
  let stopped = false;
  let micOk = false;
  let readyFired = false;

  // Camera gate is split into independent latches (each latches once, never un-latches, so a
  // momentary look-away or move can't re-gate the CTA):
  // - `cameraLive`: a real live video track is flowing — the ONLY proof the camera works, since
  //   warmupCamera is fail-open and reports faceOk even when getUserMedia was denied.
  // - `distanceOk`: a status reported a face close enough (available && faceCount>=1 && !tooFar).
  // - `gazeOk`: a status reported a face looking at the camera (available && faceCount>=1 && !lookingAway).
  // - `detectionDegraded`: a status reported detection unavailable (available===false, model missing);
  //   when set, distance/gaze/face are NOT required — but the camera must still be genuinely live.
  let cameraLive = false;
  let distanceOk = false;
  let gazeOk = false;
  let detectionDegraded = false;

  let cameraWarmupCleanup: (() => void) | null = null;
  let previewLinkTimer: number | null = null;
  let cameraDeniedTimer: number | null = null;

  let audioStream: MediaStream | null = null;
  let audioCtx: AudioContext | null = null;
  let analyser: AnalyserNode | null = null;
  let meterRaf: number | null = null;

  // READY gate: the camera must be genuinely live and the mic confirmed; distance + gaze are
  // required only when face detection actually ran. If detection is unavailable (model missing),
  // it degrades to camera + mic — but never bypasses `cameraLive`, so a denied camera stays shut.
  function maybeFireReady(): void {
    if (readyFired || stopped) return;
    if (cameraLive && micOk && (detectionDegraded || (distanceOk && gazeOk))) {
      readyFired = true;
      onReady();
    }
  }

  // ── Camera + distance + gaze check ──────────────────────────────────────────────────
  // Reflects the shared latches into the DOM indicators and re-evaluates the READY gate.
  function updateCameraGate(): void {
    if (stopped) return;
    if (cameraLive) els.cameraStatus.dataset.ok = 'true';
    if (distanceOk) els.distanceStatus.dataset.ok = 'true';
    if (gazeOk) els.gazeStatus.dataset.ok = 'true';
    maybeFireReady();
  }

  // Live positioning nudge, updated on every frame where a face is being tracked. The Italian
  // copy lives in the hint element's `data-*` attributes — this module only reads them.
  function updateHint(status: WarmupStatus): void {
    if (!status.available || status.faceCount < 1) return;
    if (status.tooFar) {
      els.hint.textContent = els.hint.dataset.hintFar ?? '';
    } else if (status.lookingAway) {
      els.hint.textContent = els.hint.dataset.hintGaze ?? '';
    } else {
      els.hint.textContent = '';
    }
  }

  function startCamera(): void {
    cameraWarmupCleanup = warmupCamera((_faceOk, status) => {
      if (stopped || !status) return;
      if (!status.available) {
        detectionDegraded = true; // model unavailable — don't require distance/gaze/face
        updateCameraGate();
        return;
      }
      if (status.faceCount >= 1 && !status.tooFar) distanceOk = true;
      if (status.faceCount >= 1 && !status.lookingAway) gazeOk = true;
      updateHint(status);
      updateCameraGate();
    });

    // Mirror the proctor's camera stream into our preview and confirm it is actually live.
    // warmupCamera attaches the stream to the proctor's #self-view element; we copy the same
    // MediaStream object across so both elements share one camera (no second getUserMedia).
    // We poll because warmupCamera resolves getUserMedia async.
    const proctorSelfView = document.getElementById(
      PROCTOR_SELF_VIEW_ID,
    ) as HTMLVideoElement | null;
    previewLinkTimer = window.setInterval(() => {
      if (stopped) return;
      const src = proctorSelfView?.srcObject as MediaStream | null;
      if (!src) return;
      if (els.preview.srcObject !== src) {
        els.preview.srcObject = src;
        els.preview.muted = true;
        void els.preview.play().catch(() => {});
      }
      // A live video track is the proof warmupCamera's fail-open faceOk cannot give us: if the
      // camera was denied/unavailable, no stream ever reaches #self-view and this never runs.
      if (src.getVideoTracks().some((t) => t.readyState === 'live')) {
        cameraLive = true;
        updateCameraGate();
        if (previewLinkTimer != null) {
          window.clearInterval(previewLinkTimer);
          previewLinkTimer = null;
        }
      }
    }, 200);

    // warmupCamera swallows a denied/failed camera (never attaches a stream), so a camera-only
    // denial would otherwise stay invisible. If no live camera appears within the grace period,
    // surface the permission guidance and keep the gate shut.
    cameraDeniedTimer = window.setTimeout(() => {
      if (stopped || cameraLive) return;
      els.deniedBox.hidden = false;
    }, CAMERA_TIMEOUT_MS);
  }

  // ── Microphone level meter (independent audio-only stream + Web Audio) ─────────────
  async function startMic(): Promise<void> {
    try {
      audioStream = await navigator.mediaDevices.getUserMedia({ audio: true });
    } catch (err) {
      if (isPermissionDenied(err)) {
        els.deniedBox.hidden = false;
      }
      return; // no mic → the gate stays closed; micOk never latches
    }
    if (stopped) {
      audioStream.getTracks().forEach((t) => t.stop());
      audioStream = null;
      return;
    }

    audioCtx = new AudioContext();
    analyser = audioCtx.createAnalyser();
    analyser.fftSize = 512;
    audioCtx.createMediaStreamSource(audioStream).connect(analyser);

    const buffer = new Float32Array(analyser.fftSize);
    const tick = (): void => {
      if (stopped || !analyser) return;
      const level = computeRms(analyser, buffer); // 0..1
      renderMeter(els.micBarFill, level);
      if (level >= MIC_SPEAK_THRESHOLD && !micOk) {
        micOk = true;
        els.micStatus.dataset.ok = 'true';
        maybeFireReady();
      }
      meterRaf = window.requestAnimationFrame(tick);
    };
    meterRaf = window.requestAnimationFrame(tick);
  }

  // ── Boot ───────────────────────────────────────────────────────────────────────────
  startCamera();
  void startMic();

  return {
    stop(keepCamera = false): void {
      if (stopped) return;
      stopped = true;
      if (meterRaf != null) window.cancelAnimationFrame(meterRaf);
      meterRaf = null;
      if (previewLinkTimer != null) window.clearInterval(previewLinkTimer);
      previewLinkTimer = null;
      if (cameraDeniedTimer != null) window.clearTimeout(cameraDeniedTimer);
      cameraDeniedTimer = null;
      // Release ONLY the mic meter's own audio stream — the proctor opens its own mic at
      // session start, so this one has no further use.
      audioStream?.getTracks().forEach((t) => t.stop());
      audioStream = null;
      analyser = null;
      void audioCtx?.close().catch(() => {});
      audioCtx = null;
      // Detach the preview from the shared stream without stopping the tracks.
      els.preview.srcObject = null;
      // Camera lifecycle:
      // - keepCamera=true  → interview handoff: leave the warmup + camera stream alive; the
      //   caller now owns `cameraWarmupCleanup` and releases it at end of session (one stream).
      // - keepCamera=false → reset/abandon: tear down the warmup and release the camera now.
      if (!keepCamera) {
        cameraWarmupCleanup?.();
        cameraWarmupCleanup = null;
      }
    },
    get cameraWarmupCleanup(): () => void {
      return () => cameraWarmupCleanup?.();
    },
  };
}

// ── Pure helpers (kept side-effect-free so they are unit-testable later) ─────────────

// Root-mean-square amplitude of the current audio frame, normalized to ~0..1.
export function computeRms(analyser: AnalyserNode, buffer: Float32Array): number {
  analyser.getFloatTimeDomainData(buffer);
  let sumSquares = 0;
  for (let i = 0; i < buffer.length; i++) {
    const sample = buffer[i] ?? 0;
    sumSquares += sample * sample;
  }
  return Math.sqrt(sumSquares / buffer.length);
}

// Maps a 0..1 level to the bar's width (%) and color. Grey below the speak threshold,
// green at/above it. Width is boosted (level * 100 * gain) so normal speech visibly fills
// the bar rather than hugging the low end.
export function renderMeter(fill: HTMLElement, level: number): void {
  const widthPct = Math.min(100, Math.round(level * 100 * 4));
  fill.style.width = `${widthPct}%`;
  fill.dataset.ok = level >= MIC_SPEAK_THRESHOLD ? 'true' : 'false';
}

function isPermissionDenied(err: unknown): boolean {
  return err instanceof DOMException && err.name === 'NotAllowedError';
}
