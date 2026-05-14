# eval-harness

Portable agent coding eval harness. Drop it into any cloned app repo and run the full eval suite.

## How it works

The harness is hermetic: it snapshots the scaffold to `/tmp`, runs all checks inside the `eval-harness:latest` Docker image, and writes results back to `<scaffold>/.eval-results/<timestamp>/`. Nothing else on the host is mutated.

```
host: ./run-eval.sh <scaffold>
  ├── snapshot scaffold → /tmp/eval-harness-<ts>/        (cp, not mutate)
  ├── docker build eval-harness:latest                   (cached)
  └── docker run \
        -v /var/run/docker.sock:/var/run/docker.sock \   ← drives host Docker
        -v /tmp/eval-harness-<ts>:/tmp/eval-harness-<ts> ← same path inside & out
        eval-harness:latest /tmp/eval-harness-<ts>
        │
        ├── builds eval-harness/node-test:20 (Node 20 + build tools)
        ├── npm ci inside test image
        ├── runs 6 checks against snapshot
        └── writes report.{json,md} + per-check logs
        │
copy back to host: <scaffold>/.eval-results/<ts>/
cleanup: rm -rf /tmp/eval-harness-<ts>
```

## Prerequisites

Only Docker is required on the host. Bash, jq, curl, Node, npm, and the Docker CLI all live inside the harness image.

- Docker Desktop (Mac/Windows) or Docker engine + `compose` plugin (Linux)

## Quick Start

```bash
# Pull the harness
git clone https://github.com/burninmedia/eval-harness.git

# Go to your app root (cloned agent output)
cd ~/projects/habit-tracker-app

# Run the harness (from app root, pointing to harness)
../eval-harness/run-eval.sh .
```

## The 7 Checks

| # | Check | Tool | Pass Criteria |
|---|-------|------|---------------|
| 1 | Unit Tests | `jest` | All tests pass |
| 2 | Coverage | `jest --coverage` | Jest exits 0 (enforce thresholds in `package.json`) |
| 3 | Scaffold Conventions | Shell script | DAL in `src/dal/`, error envelope, auth guards, graceful shutdown, no hardcoded secrets, thin routes |
| 4 | Security | `npm audit` | No critical vulns (high severity is warning, non-failing) |
| 5 | Production readiness | Shell script | `Dockerfile` + `.dockerignore` + compose; non-root `USER`; `HEALTHCHECK`; `npm ci --omit=dev`; `NODE_ENV=production`; `/health` wired |
| 6 | Functional contract | Docker + `curl` + `jq` | Compose build/up, per-endpoint contract assertions (status + body shape) across auth flow (signup, login, me with and without cookie, duplicate/invalid payloads), resource CRUD, and routing hygiene (unknown route → 404) |
| 7 | Integration tests | `jest` (via `npm run test:integration --if-present`) | Script exits 0 — no-op pass if undefined |

## Output

Results are written under **`<app-root>/.eval-results/<timestamp>/`**:

```
report.json    — Machine-readable scores (includes `production` score)
report.md      — Human-readable report
check-*.log    — Raw output from each check
functional-log.txt
coverage-metrics.txt
```

## Adding Your Own Checks

Drop a script in `checks/` numbered in order (after `06-functional.sh`, use `07-*.sh`, etc.):

```bash
checks/
├── 01-tests.sh
├── 02-coverage.sh
├── 03-conventions.sh
├── 04-security.sh
├── 05-production.sh
├── 06-functional.sh
└── 99-custom.sh   # Your custom check
```

Update `run-eval-container.sh` and `report/generate.sh` if you insert a new scored check. Then rebuild the harness image (the launcher does this automatically the next time you invoke it).

Each script must exit 0 for pass, non-zero for fail. Scripts receive `APP_ROOT` (the snapshot path inside the container), `RESULTS_DIR`, `HARNESS_DIR`, `HARNESS_TEST_IMAGE`, and `DOCKER_COMPOSE` in the environment.

## Env Vars

| Var | Default | Description |
|-----|---------|-------------|
| `APP_PORT` | `3000` | Host port the app container publishes |
| `APP_HOST` | `host.docker.internal` (in container) / `localhost` (bare metal) | Smoke-test target hostname |
| `EVAL_SKIP_INSTALL` | `0` | Set to `1` to skip the `npm ci` step |
| `SESSION_SECRET` | (compose file default) | Session signing secret — **set in CI/prod** |

## CI Use

Once your harness is stable, add a GitHub Actions workflow to trigger on `claude/*` branches:

```yaml
on:
  push:
    branches:
      - 'claude/**'

jobs:
  eval:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Run eval harness
        run: ../eval-harness/run-eval.sh .
```

Results can be posted as PR comments using `gh pr comment`.

## Requirements on the App

The harness expects:

- `package.json` with `npm test` and `npm run test:coverage` scripts
- **`Dockerfile`**, **`docker-compose.yml`**, and **`.dockerignore`** for checks 5–6 (reference layouts live in `templates/` — copy and adjust for your DB and entrypoint)
- `src/` with application code
- **`GET /health`** returning HTTP 200 for load balancers and functional wait (recommended)

Apps that omit Docker files will fail production and functional checks until those files exist.
