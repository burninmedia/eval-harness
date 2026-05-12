# eval-harness

Portable agent coding eval harness. Drop it into any cloned app repo and run the full eval suite.

## How it works

```
┌─────────────────────────────────────────────────────────┐
│  Agent builds app + Docker/K8s (scaffold context)       │
│  Output on: claude/habit-tracker-xxx                   │
└─────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────┐
│  eval-harness/              app/                        │
│  (this repo)  ──────►  (cloned agent output)            │
│                          │                               │
│                          ▼                               │
│              run-eval.sh .                              │
│                          │                               │
│                          ▼                               │
│              Docker spins up full stack                  │
│              5 checks run                                │
│              report.json + report.md generated          │
└─────────────────────────────────────────────────────────┘
```

## Prerequisites

- Docker + docker-compose
- Node.js 20+ (for npm install before running)

## Quick Start

```bash
# Pull the harness
git clone https://github.com/burninmedia/eval-harness.git

# Go to your app root (cloned agent output)
cd ~/projects/habit-tracker-app

# Run the harness (from app root, pointing to harness)
../eval-harness/run-eval.sh .
```

## The 5 Checks

| # | Check | Tool | Pass Criteria |
|---|-------|------|---------------|
| 1 | Unit Tests | `jest` | All tests pass |
| 2 | Coverage | `jest --coverage` | >= 80% global threshold |
| 3 | Scaffold Conventions | Shell script | DAL in src/dal/, error envelope, auth guards, graceful shutdown, no hardcoded secrets |
| 4 | Security | `npm audit` | No critical/high vulnerabilities |
| 5 | Functional | Docker smoke test | App starts, endpoints respond |

## Output

Results written to `~/.eval-results/<timestamp>/`:

```
report.json    — Machine-readable scores
report.md     — Human-readable report
check-*.log   — Raw output from each check
```

## Adding Your Own Checks

Drop a script in `checks/` numbered in order:

```bash
checks/
├── 01-tests.sh
├── 02-coverage.sh
├── 03-conventions.sh
├── 04-security.sh
├── 05-functional.sh
└── 99-custom.sh   # Your custom check
```

Each script must exit 0 for pass, non-zero for fail.

## Env Vars

| Var | Default | Description |
|-----|---------|-------------|
| `APP_PORT` | `3000` | Port app runs on inside Docker |
| `SESSION_SECRET` | `change-me` | Session secret for Docker run |
| `DB_PASSWORD` | `change-me` | Postgres password |

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
- `Dockerfile` (or one will be generated)
- `docker-compose.yml` (or one will be generated)
- `src/` directory with the app code

If Docker files are missing, the harness generates basic templates from `templates/`.
