---
name: vertex-run-insights
description: Inspect Vertex AI pipeline runs in JET's ML platform (jet-ml-dev / jet-ml-staging / jet-ml-prod, europe-west1) and report per-task CPU and RAM peaks, runtimes, machine types and USD cost. Use this whenever the user asks about a Vertex AI pipeline run or job - for example "how much did this pipeline cost", "which task used the most memory", "show me the latest run of <pipeline>", "why is this pipeline slow", "what machine does this task run on", "is this run over-provisioned", "break down the run by task", "CPU/RAM usage of the last run", or any right-sizing / cost / performance question about a Vertex AI pipeline. Also use it to persist per-task usage locally before Vertex deletes monitoring data after ~6 weeks. Trigger even when the user only names a pipeline and a run id, or says "the last run", without mentioning Vertex or cost explicitly.
---

# Vertex Run Insights

Inspect Vertex AI pipeline runs in JET's ML platform: per-task CPU and RAM peaks,
runtimes, machine types and an estimated USD cost - plus a local history store that
survives Vertex's ~6-week monitoring retention.

## Scope

- Read-only inspection of Vertex AI pipelines in `jet-ml-dev`, `jet-ml-staging` and
  `jet-ml-prod` (region `europe-west1`).
- The skill answers questions about runs that have already executed. It does not
  trigger, retry or modify pipelines.

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
directly; it is executable.

```bash
vertex_runs.sh runs  --pipeline NAME [--env prod] [--limit 10] [--no-save]
vertex_runs.sh tasks --pipeline NAME --run-id ID [--env prod] [--no-save]
vertex_runs.sh usage --pipeline NAME --run-id ID [--task TASK] [--env prod] [--no-save]
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

Output columns:

```
TASK  STATE  CPU_PEAK  CPU(vCPU)  RAM_PEAK  RAM(GiB)  RUNTIME  COST_USD
```

Verified output for the reference run above:

```
TASK                           STATE      CPU_PEAK    CPU(vCPU)  RAM_PEAK    RAM(GiB)   RUNTIME     COST_USD
qa-4                           SUCCEEDED  8.54%       0.34       4.64%       0.74       1m32s       0.0043
load-metadata-and-predictions  SUCCEEDED  0.23%       0.14       0.09%       0.22       8m48s       0.56
qa-2                           SUCCEEDED  9.53%       0.38       4.13%       0.66       3m54s       0.01
qa-3                           SUCCEEDED  8.58%       0.34       4.05%       0.65       2m2s        0.0057
batch-job                      SUCCEEDED  0.37%       0.01       4.7%        0.75       19h24m      3.29
load-and-save-data             SUCCEEDED  1.05%       0.67       31.43%      75.44      1h11m       4.55
qa                             SUCCEEDED  9.71%       0.39       3.96%       0.63       3m44s       0.01
```

Add `--task NAME` to focus on one task (for example the biggest cost driver):

```bash
scripts/vertex_runs.sh usage \
  --pipeline customer-representation-oss-finetuned \
  --run-id customer-representation-oss-finetuned-20261006023020 \
  --task load-and-save-data
```

### Reading the numbers

- `CPU_PEAK` / `RAM_PEAK` are the maximum observed utilization over the task's
  lifetime, as a percentage of the machine's allocated vCPU / RAM.
- `CPU(vCPU)` and `RAM(GiB)` are the same peaks in absolute units (peak fraction
  multiplied by the machine's vCPU / RAM).
- `COST_USD` is machine node-hours only: `usd_per_node_hour * runtime_hours`. It is a
  lower bound - storage and other services are out of scope by design.
- A task with a very low peak on a very large machine is a right-sizing candidate.
  In the reference run `load-and-save-data` peaks at 1.05% CPU and 31% RAM on an
  `n1-standard-64`, which is the kind of signal worth surfacing to the user.
- `RUNNING` tasks show `running` and are costed up to "now".
- An unknown machine type yields `price unknown` rather than a guessed number.

## Local history store

Vertex deletes monitoring time series after roughly six weeks, so every `tasks` and
`usage` call also appends the per-task rows to a local file:

```
<git repo root>/.vertex-history/history.jsonl
```

- One JSON object per line, one line per task, no schema version.
- Key is `run_id` + `task`. Re-running a task replaces its line in place, so a run
  first captured as `RUNNING` is updated once it becomes `SUCCEEDED`.
- Saving is **on by default**; pass `--no-save` to skip it (for example for a quick
  read-only look).
- There is no read-back command - the file is meant to be read with `jq` or a
  notebook when the user wants history.
- The store root is derived from `git rev-parse --show-toplevel`, falling back to the
  current directory.
- `.vertex-history/` is listed in the repo's `.gitignore`.

Record fields: `run_id`, `pipeline`, `env`, `project`, `region`, `task`, `state`,
`start_time`, `end_time`, `runtime_s`, `machine_type`, `vcpu`, `ram_gib`,
`cpu_peak_frac`, `cpu_peak_vcpu`, `ram_peak_frac`, `ram_peak_gib`, `cost_usd`,
`captured_at`.

Inspect the store with:

```bash
jq -s 'sort_by(.cost_usd) | reverse | .[0:5]' .vertex-history/history.jsonl
```

## How to answer common questions

- "How much did this pipeline cost?" -> `usage`, then sum `COST_USD` across tasks and
  report the per-task breakdown, calling out the top cost driver.
- "Which task used the most memory?" -> `usage`, then compare `RAM(GiB)` across tasks.
- "Show me the latest run" -> `runs --limit 1`, then `usage` on that run id.
- "Is this run over-provisioned?" -> `usage`, then compare `CPU(vCPU)` / `RAM(GiB)`
  against the machine's `vCPU` / `RAM_GiB` and suggest smaller machine types.
- "Why is this pipeline slow?" -> `usage`, then rank tasks by `RUNTIME`.

Always show the user the actual table (or a trimmed version of it) and quote real
numbers; do not paraphrase without the underlying figures.

## Reference files

Read these only when you need to understand or change the script's internals - the
normal workflow does not require them.

- `references/monitoring.md` - why the script queries Cloud Monitoring the way it
  does: the `cloudml_job` monitored resource, the `job_id` == CustomJob ID detail, the
  `ml.googleapis.com/training/*` metric types and the padded time window.
- `references/pricing.md` - the SKU source, the EMEA rates, the `prices.tsv` format,
  the refresh procedure and the "last updated" date.

## Requirements

- `bash`, `curl`, `jq`.
- `gcloud` authenticated with access to the three ML projects. If auth is missing or
  expired the script tells the user to run `gcloud auth login` and stops.
