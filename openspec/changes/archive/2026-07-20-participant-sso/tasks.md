# Tasks: Participant + SSO Ingress (C6)

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | ~580–720 LOC (excl. tests); tests add ~400–500 |
| 400-line budget risk | High |
| Chained PRs recommended | Yes |
| Suggested split | PR 1 (foundation) → PR 2 (exchange + controllers) |
| Delivery strategy | ask-on-risk |
| Chain strategy | feature-branch-chain |

Decision needed before apply: Yes
Chained PRs recommended: Yes
Chain strategy: feature-branch-chain
400-line budget risk: High

### Suggested Work Units

| Unit | Goal | Likely PR | Notes |
|------|------|-----------|-------|
| 1 | Migration + Participant model + ParticipantTransitionException + api-candidate guard + config + TenantContextCandidate | PR 1 | Base = `feature/c6-participant-sso`; ~280–320 LOC |
| 2 | CandidateTokenFactory + SsoLinkController + SsoExchangeController + ParticipantController + SessionController + ParticipantResource + routes + all tests | PR 2 | Base = PR 1 branch; ~300–400 LOC code + tests |

## Status

All 40/40 tasks complete ✓

- Phase 1 (1.1–1.13): 13 tasks complete ✓
- Phase 2 (2.1–2.16): 16 tasks complete ✓
- Phase 3 (3.1–3.7): 7 tasks complete ✓
- Phase 4 (4.1–4.4): 4 tasks complete ✓

Verification: sdd-verify PASS (558/558 tests, 97.4% coverage, all requirements met).
