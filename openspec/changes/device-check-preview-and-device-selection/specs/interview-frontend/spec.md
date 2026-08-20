# Delta for Interview Frontend

Note: browser/device scope (desktop Chrome/Edge/Opera/Safari only; Firefox and
mobile excluded) is already fully specified by the existing `Browser Support Gate
(SA-11)` requirement, which runs before this screen renders. No change to that
requirement is needed or made here.

## MODIFIED Requirements

### Requirement: Pre-join device check

Before entering the live interview, the system MUST present a device-check gate that:
(a) acquires exactly one live camera and microphone stream at a time — whenever the
candidate switches camera or microphone, the system MUST acquire a fresh stream via a
new `getUserMedia` call and MUST stop every track of the previous stream before the
replacement stream becomes active, MUST NEVER hold two live streams concurrently, and
MUST NEVER leave a previous camera or microphone hot after a switch,
(b) verifies the camera produces a live video track,
(c) verifies the microphone produces audio above an RMS threshold after the candidate
speaks,
(d) after the candidate confirms both checks, hands the camera stream to the
proctoring collector without issuing a second `getUserMedia` call.
A candidate MUST NOT be able to proceed to fullscreen until both checks pass. All
device-check UI copy MUST be i18n-keyed.

(Previously: clause (a) mandated a single `getUserMedia` call for the entire
device-check lifetime, with no provision for switching devices; clause (d)'s "without
a second getUserMedia" was unscoped and read as contradicting re-acquisition on
switch. It is now explicitly scoped to after confirmation.)

#### Scenario: Both devices confirmed — proceed allowed

- GIVEN a supported browser with camera and microphone available
- WHEN the candidate completes the device check (video track live + mic RMS above threshold)
- THEN the "continue" control is enabled and the single shared camera stream is passed
  to the proctoring collector without a second `getUserMedia` call

#### Scenario: Camera unavailable — proceed blocked

- GIVEN `getUserMedia` throws `NotFoundError` or returns no video track
- WHEN the device check runs
- THEN the camera error state is shown; the proceed control remains disabled

#### Scenario: Microphone RMS never exceeds threshold — proceed blocked

- GIVEN a live video track is present but the candidate does not speak above threshold
- WHEN the device check timer expires without passing the mic test
- THEN the mic error state is shown and the proceed control remains disabled

#### Scenario: Device switch releases the previous stream before acquiring the replacement

- GIVEN a confirmed-not-yet camera or microphone stream is live
- WHEN the candidate selects a different camera or microphone
- THEN every track of the previous stream reaches `readyState !== 'live'` before the
  new `getUserMedia` call resolves, AND at no point do two live streams coexist

#### Scenario: Switch fails mid-flight — no stream left hot

- GIVEN a device switch is in progress and the previous stream has already been stopped
- WHEN the new `getUserMedia` call rejects
- THEN no camera or microphone remains live, the pickers stay interactive, and an
  actionable error state is shown instead of a silent failure

#### Scenario: Stale deviceId throws OverconstrainedError

- GIVEN a switch requests a `deviceId: { exact }` constraint for a device no longer present
- WHEN `getUserMedia` throws `OverconstrainedError`
- THEN the system retries once with unconstrained defaults instead of surfacing a raw
  error, and on success reconciles the active selection to the device actually acquired

#### Scenario: Two rapid switches — only the latest survives

- GIVEN the candidate triggers a second device switch before the first one resolves
- WHEN both `getUserMedia` calls eventually settle
- THEN only the stream matching the most recent switch remains live; any stream
  belonging to the superseded switch is stopped immediately on arrival

#### Scenario: Component unmounts during a switch

- GIVEN a device switch is in flight when the device-check screen is torn down
- WHEN the pending `getUserMedia` call resolves after teardown
- THEN the late-arriving stream is stopped immediately and never becomes the active stream

#### Scenario: Microphone unavailable — retry recovers the gate

- GIVEN no audio track is available, or the audio analysis context cannot be created
- WHEN the mic check runs
- THEN the mic gate reports unavailable rather than silently and permanently no-oping,
  and an explicit Retry control re-runs the full device check, restoring the ability to pass

## ADDED Requirements

### Requirement: Device preview geometry

The preview MUST fill the full width of its container and adopt the camera's
MEASURED native aspect ratio, read from the live video track. The system MUST NOT
crop the image and MUST NOT assume a fixed ratio.

#### Scenario: Ratio unknown before track metadata loads

- GIVEN the camera stream has just been acquired and track metadata has not resolved
- WHEN the preview first renders
- THEN a placeholder occupies the reserved space and no layout shift occurs once the
  measured ratio becomes available

#### Scenario: Aspect ratio changes on device switch

- GIVEN the candidate switches to a camera with a different native aspect ratio
- WHEN the new track's geometry is measured
- THEN the preview adopts the new ratio without cropping either camera's image

#### Scenario: Portrait camera does not distort the layout

- GIVEN a camera reports a portrait (taller-than-wide) native ratio
- WHEN the preview renders
- THEN the displayed ratio is clamped so the preview cannot become disproportionately
  tall, and the full frame remains visible (letterboxed, never cropped)

### Requirement: Live microphone level meter

The system MUST surface the microphone's live audio level as a numeric, smoothed
value, and MUST provide a non-visual equivalent for screen reader users.

#### Scenario: Speaking moves the visible level indicator

- GIVEN the microphone check is active
- WHEN the candidate speaks
- THEN a visible level indicator rises and falls with the candidate's voice, smoothed
  so momentary silence does not cause visible flicker

#### Scenario: Screen reader receives a non-visual equivalent

- GIVEN a screen reader user reaches the microphone check
- WHEN the level first crosses the pass threshold
- THEN a single, one-time status announcement communicates the pass, and static
  instructional text (not the continuously changing level) is exposed as the
  meter's accessible description — the level indicator MUST NOT sit inside a
  continuously updating live region

### Requirement: Camera and microphone device selection

The system MUST offer a picker for camera and a picker for microphone, populated via
`enumerateDevices()` and kept current when the platform reports a `devicechange` event.

#### Scenario: Pickers populate with real labels only after permission is granted

- GIVEN the candidate has not yet granted camera/microphone access
- WHEN `enumerateDevices()` runs before any grant
- THEN entries are not identified by platform label; once access is granted, the
  pickers repopulate using the real device labels

#### Scenario: Plugging in or removing a device updates the pickers live

- GIVEN the device-check screen is open
- WHEN the operating system reports a `devicechange` event
- THEN the camera and microphone pickers reflect the updated device list without a
  page reload

#### Scenario: Denied permission — pickers still usable via fallback labels

- GIVEN the candidate denied camera/microphone access
- WHEN the pickers render
- THEN each entry shows a numbered fallback label (e.g. "Camera 1") instead of an
  empty option, and selection remains possible

### Requirement: Device preference persistence

The system MUST persist the candidate's selected camera and microphone across a
reload using a cookie readable on every interview route regardless of the active
locale's URL path, and MUST fall back to system defaults when a stored device is no
longer present.

#### Scenario: Returning candidate gets the same device

- GIVEN a candidate previously selected a specific camera and microphone
- WHEN they reload or return to the device-check screen in the same browser
- THEN the same devices are pre-selected and acquired

#### Scenario: Stored device no longer exists — falls back to default

- GIVEN a stored device id is absent from `enumerateDevices()`, or acquiring it
  throws `OverconstrainedError`
- WHEN the device check runs
- THEN the system drops the stale id, acquires the system default instead, and
  updates the stored preference to the device actually in use — never a dead end

#### Scenario: Persisted preference applies regardless of locale path

- GIVEN a candidate previously selected devices on one locale's interview URL path
- WHEN they return via a different locale's interview URL path
- THEN the previously selected devices are still honored, because the preference is
  not scoped to a single locale's path segment

### Requirement: Instructional and permission-recovery copy

Each device-check step MUST carry instructional copy describing what to do and how to
recognize success, and the denied-permission state MUST carry an explicit,
browser-neutral path to re-grant access and retry. Every string MUST resolve through
an i18n key present in both `it` and `en` locale files; no literal UI strings are
permitted.

#### Scenario: Denied permission shows recovery instructions

- GIVEN the candidate denied camera or microphone access
- WHEN the error state renders
- THEN instructional copy explains how to re-grant permission in the browser and
  offers a Retry control, and no part of this copy is a hardcoded literal string

#### Scenario: All device-check copy is i18n-keyed in both locales

- GIVEN the device-check screen in any state (instructions, errors, recovery, picker
  labels, meter label)
- WHEN the screen renders in `it` or `en`
- THEN every visible string resolves from that locale's translation file; no string
  is hardcoded in the component

### Requirement: Device-check accessibility

Device pickers, the microphone level meter, and instructional copy MUST be reachable
and operable via assistive technology.

#### Scenario: Pickers are labelled for assistive technology

- GIVEN a screen reader user navigates to a device picker
- WHEN the picker receives focus
- THEN its accessible name identifies it as the camera or microphone picker, and its
  current selection is announced

#### Scenario: Zero automated accessibility violations

- GIVEN the device-check screen in its default, error, and confirmed states
- WHEN an automated accessibility audit runs
- THEN no violations are reported
