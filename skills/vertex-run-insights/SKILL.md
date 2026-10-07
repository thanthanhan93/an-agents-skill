---
name: vertex-run-insights
description: Inspect Vertex AI pipeline runs in JET's ML platform (jet-ml-dev / jet-ml-staging / jet-ml-prod, europe-west1) for per-task CPU and RAM peaks, runtimes, machine types and USD cost, plus a local history store that survives Vertex's ~6-week monitoring retention. Use for any cost, right-sizing or performance question about a Vertex AI pipeline.
---

# Vertex Run Insights

Query Vertex AI pipeline runs in JET's ML platform for per-task CPU and RAM peaks,
runtime, machine type and an estimated USD cost.

## Scope

- Read-only inspection of Vertex AI pipelines in `jet-ml-dev`, `jet-ml-staging` and
  `jet-ml-prod` (region `europe-west1`).
- Answers questions about runs that have already executed. It does not trigger, retry
  or modify pipelines.

## Guardrails

- **Only the three platform projects are allowed.** The script refuses anything else.
- **Default env is `prod`, region `europe-west1`.** The script always echoes the
  effective defaults; if a non-default region is used it prints a warning. Pass
  `--env dev|staging` or `--region` only when the user explicitly asks for it.
- **Do not explore the repo's application code.** This skill is about the platform's
  runs, not about the source of the pipelines. Everything you need is reachable through
  the script.
- **Do not hand-roll API calls.** `scripts/vertex_runs.sh` is the single entry point;
  it already encodes the correct resource types, filters, pricing and store format.
  Only fall back to raw API calls if the script is genuinely missing a capability, and
  read the reference files first if you do.
- **Never trigger or modify a pipeline** as part of this skill.
- **Auth failure means stop.** If `gcloud auth print-access-token` fails the script
  exits with a clear message and exit code 2. Tell the user to run `gcloud auth login`
  and retry; do not try to work around it.

## The one script

All commands go through `scripts/vertex_runs.sh` (bash + `jq`). Run it with `bash` or
directly; it is executable. Paths below are relative to this skill directory.

```bash
scripts/vertex_runs.sh runs  --pipeline NAME [--env prod] [--limit 10] [--no-save]
scripts/vertex_runs.sh tasks --pipeline NAME --run-id ID [--env prod] [--no-save]
scripts/vertex_runs.sh usage --pipeline NAME --run-id ID [--task TASK] [--env prod] [--no-save]
```

Common flags:

| Flag | Meaning | Default |
| --- | --- | --- |
| `--env dev\|staging\|prod` | Platform environment | `prod` |
| `--project ID` | Override GCP project (must be one of the three allowed) | `jet-ml-<env>` |
| `--region R` | Override region | `europe-west1` |
| `--limit N` | Number of runs listed by `runs` | `10` |
| `--run-id ID` | Run id (short) or full resource name | - |
| `--task NAME` | Restrict `usage` to a single task | all tasks |
| `--no-save` | Do not write to the local history store | save is on |

### `runs` - list recent runs of a pipeline

Use this to find the run id, or to answer "what is the latest run".

```bash
scripts/vertex_runs.sh runs \
  --pipeline customer-representation-oss-finetuned --limit 5
```

- `--pipeline` must be an **exact** `displayName`. On a miss the script prints an
  `ERROR:` line plus a list of known pipeline names and exits 3 - do not guess or
  fuzzy-match; pick the exact name from that list (or ask the user).
- Output columns: `RUN_ID`, `STATE`, `CREATED (UTC)`, `RUNTIME`.

### `tasks` - task breakdown without usage metrics

Fast, cheap listing of the tasks in one run: state, runtime, machine type, vCPU, RAM.

```bash
scripts/vertex_runs.sh tasks \
  --pipeline customer-representation-oss-finetuned \
  --run-id customer-representation-oss-finetuned-20261006023020
```

Use this when the user only wants the shape of a run (which tasks, what machines,
how long) and not resource peaks or cost. It still writes the task rows to the
history store.

### `usage` - CPU/RAM peaks and cost (the main command)

This is the command to reach for by default: it adds CPU peak, RAM peak and cost on
top of the `tasks` view.

```bash
scripts/vertex_runs.sh usage \
  --pipeline customer-representation-oss-finetuned \
  --run-id customer-representation-oss-finetuned-20261006023020
```

Output columns: `TASK`, `STATE`, `CPU_PEAK`, `CPU(vCPU)`, `RAM_PEAK`, `RAM(GiB)`,
`RUNTIME`, `COST_USD`.

Add `--task NAME` to focus on one task (for example the biggest cost driver):

```bash
scripts/vertex_runs.sh usage \
  --pipeline customer-representation-oss-finetuned \
  --run-id customer-representation-oss-finetuned-20261006023020 \
  --task load-and-save-data
```

Always show the user the actual table (or a trimmed version of it) and quote real
numbers; do not paraphrase without the underlying figures. How to read each column,
and the local history store, are documented in `references/monitoring.md`.

## Reference files

Read these only when you need to interpret the numbers, understand or change the
script's internals, or refresh prices - the normal workflow does not require them.

- `references/monitoring.md` - how to read the columns (peaks, absolute units, cost as
  a lower bound), the local history store, and why the script queries Cloud Monitoring
  the way it does: the `cloudml_job` monitored resource, the `job_id` == CustomJob ID
  detail, the `ml.googleapis.com/training/*` metric types and the padded time window.
- `references/pricing.md` - the SKU source, the EMEA rates, the `prices.tsv` format,
  the refresh procedure and the "last updated" date.

## Requirements

- `bash`, `curl`, `jq`.
- `gcloud` authenticated with access to the three ML projects. If auth is missing or
  expired the script tells the user to run `gcloud auth login` and stops.
