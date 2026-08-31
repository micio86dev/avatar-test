# Non-functional requirements

## Platform and browsers

### Supported (desktop)

| Browser | Indicative minimum version |
|---------|---------------------------|
| Google Chrome | 66+ |
| Microsoft Edge | 79+ |
| Opera | 53+ |
| Safari (macOS) | 14.1+ |

### Not supported

| Environment | Reason |
|----------|--------|
| Firefox | Realtime audio streaming incompatibility (current version) |
| Mobile / tablet | Experience not optimised; desktop only |

> The new stack may widen support if technically feasible. Contractual minimum: recent desktop Chrome/Edge.

## Audio and microphone

- An explicit microphone permission request before the interview;
- Input audio device selection;
- Error handling: permission denied, device unavailable, environment too noisy (UX warning);
- Optional microphone test before the interview.

## Connectivity

- A stable internet connection is required for realtime streaming;
- Aggressive VPNs or proxies can degrade the experience → troubleshooting messages in the UI;
- Automatic retry on brief disconnections (desirable).

## Languages

- **Mandatory:** Italian, English;
- **Desirable:** Spanish, French, German, Portuguese;
- The UI, the TTS questions and the evaluation must be consistent with the project language.

## Performance

| Metric | Indicative target |
|---------|-------------------|
| Voice latency (question → audible audio) | < 2–3 seconds perceived |
| Session start after SSO | < 5 seconds |
| Post-interview evaluation | < 10 minutes (p95) |

## Security and privacy

- HTTPS everywhere;
- Assessment data (audio, transcripts, evaluations) treated as **personal data** (GDPR);
- Secrets (API, webhook, SSO) never in logs or client-side;
- Tenant isolation: one customer must never see another's data;
- Audit log of admin operations (recommended).

## Availability

- SLA target to be agreed with the client (e.g. 99.5% during business hours);
- Scheduled maintenance announced in advance.

## Scalability

- Concurrency support: multiple candidates interviewing simultaneously;
- Evaluation jobs on an asynchronous queue;
- Audio asset storage with a configurable retention policy.

## Accessibility

- Full WCAG is not mandatory for v1, but:
  - adequate UI contrast;
  - understandable error messages;
  - a keyboard path for the pre/post interview screens (not necessarily for the voice conversation).

## Troubleshooting (support)

Common failure causes to handle in the UX and the support documentation:

1. Unsupported browser → a message with a link to Chrome/Edge;
2. Blocked microphone → instructions for unblocking permissions;
3. Unstable connection / VPN → suggestions;
4. Browser extensions (ad-blockers) → try incognito.

Scenario detail: to be folded into the supplier's operations manual.

## Billing (if in scope)

- Linking completed interviews to billing records;
- An admin view of transactions per organization.
