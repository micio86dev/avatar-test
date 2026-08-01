# Load Testing — BEAI API

K6 load tests for the `api` service (D35). All tests run against the **local Docker Compose
stack** only — never against Railway stage/prod to avoid bandwidth costs.

## Prerequisites

1. `k6` installed: `brew install k6` (macOS) or see [k6 installation docs](https://grafana.com/docs/k6/latest/set-up/install-k6/)
2. Local stack healthy: `task up` (wrapper Taskfile.yml) or `docker compose up -d`
3. API service running and healthy: `curl http://localhost:8000/api/health`

## Running Load Tests

Via the wrapper Taskfile:

```bash
task test:load
```

Or directly from the `api/` directory:

```bash
# Baseline: 10 VU × 60 s
k6 run tests/k6/scenarios/baseline.js

# Stress: 50 VU × 120 s
k6 run tests/k6/scenarios/stress.js

# Spike: 0 → 200 VU ramp in 10 s, hold 30 s, ramp down
k6 run tests/k6/scenarios/spike.js
```

With JSON report export:

```bash
k6 run --summary-export=docs/load-testing/baseline-report.json tests/k6/scenarios/baseline.js
```

## Thresholds (D35)

| Scenario | VUs | Duration | p95 latency | Error rate |
|----------|-----|----------|-------------|------------|
| baseline | 10 | 60 s | < 100 ms | < 0.5% |
| stress | 50 | 120 s | < 200 ms | < 1% |
| spike | 0→200→0 | ~50 s | — | < 5% |

Scoring endpoint (C8+, LLM-mocked): p95 < 10 s.

## Report Files

Raw JSON and HTML reports are gitignored (generated at run time). The latest
capacity analysis narrative is committed here as part of a release.

### Latest Run: (not yet executed — C1 scaffold)

Capacity estimate for Railway instance sizing will be added after the first
`docker compose up -d` + `task test:load` run on local hardware.
