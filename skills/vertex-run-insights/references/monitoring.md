# Cloud Monitoring queries for Vertex AI runs

Why `scripts/vertex_runs.sh` queries Cloud Monitoring the way it does, and how to
find more metrics if you need them. Verified against real data in JET's ML platform
(`jet-ml-dev`, `jet-ml-staging`, `jet-ml-prod`, region `europe-west1`).

## Table of contents

- [Monitoring API basics](#monitoring-api-basics)
- [How to explore available metrics and resources](#how-to-explore-available-metrics-and-resources)
- [Verified findings](#verified-findings)
- [Reading the output columns](#reading-the-output-columns)
- [Local history store](#local-history-store)
- [Gotchas](#gotchas)

## Monitoring API basics

- Base URL: `https://monitoring.googleapis.com/v3/projects/<project>`.
- Auth: a short-lived token, `-H "Authorization: Bearer $(gcloud auth print-access-token)"`.
- A series is identified by a **metric type** (`metric.type`) plus a **monitored
  resource type** and its labels (`resource.type`, `resource.label.*`).
- Filters are combined with `AND`. Always send them with `curl -G --data-urlencode`
  so quotes and `AND` are URL-encoded correctly; hand-built URLs break on them.
- Values arrive in `.timeSeries[].points[].value.doubleValue`. `pageSize=1000` and
  paginate on `.nextPageToken` if a window is busy.

## How to explore available metrics and resources

Use these when you need a metric the script does not already report (GPU, network,
disk). They are how the metrics below were found in the first place.

List the monitored resource types available in the project:

```bash
curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  "https://monitoring.googleapis.com/v3/projects/PROJECT/monitoredResourceDescriptors"
```

List metric types by prefix (`starts_with` is the cheapest way to find a namespace):

```bash
curl -s -G -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  --data-urlencode 'filter=metric.type=starts_with("ml.googleapis.com/training/")' \
  "https://monitoring.googleapis.com/v3/projects/PROJECT/metricDescriptors"
```

Probe live series for one resource id and metric:

```bash
curl -s -G -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  --data-urlencode 'filter=metric.type="ml.googleapis.com/training/cpu/utilization" AND resource.label.job_id="CUSTOMJOB_ID"' \
  --data-urlencode 'interval.startTime=2026-10-06T02:25:00Z' \
  --data-urlencode 'interval.endTime=2026-10-06T03:45:00Z' \
  "https://monitoring.googleapis.com/v3/projects/PROJECT/timeSeries"
```

## Verified findings

- **The metrics are under `cloudml_job`, not `gce_instance`.** The custom-job
  container runs on a Compute Engine VM, but that VM lives in a Google-managed tenant
  project, so it never appears in `gcloud compute instances list` and its
  `compute.googleapis.com/instance/*` series are not in your project's scope. Query
  the resource type `cloudml_job` (labels `project_id`, `job_id`, `region`) directly.
- **`job_id` is the CustomJob ID, not the pipeline task id.** A pipeline task and its
  CustomJob are different objects, so a filter built from the task id returns an empty
  series. Resolve the CustomJob ID from the pipeline job first, at
  `.jobDetail.taskDetails[].executorDetail.containerDetail.mainJob`, and take the last
  path segment (for example `4512620604880322560`).
- **Metric types** under `ml.googleapis.com/training/`: `cpu/utilization` and
  `memory/utilization`, both fractions `0.0`-`1.0` of what was allocated to the job.
  Multiply by 100 for a percentage, or by the machine's vCPU / RAM for absolute units.
  `disk/utilization` is present but **unreliable** (reported ~36-64 KB for a real job)
  and is deliberately excluded. `accelerator/*` exists for GPU/TPU jobs only.
- **The time window is padded by -300s / +600s** around the task. Sampling is once per
  minute, series start a few minutes late (image pull) and lag past job end, so a tight
  window clips the peaks. For a `RUNNING` task the window end is "now".

A human can sanity-check any number in the Vertex AI console under
Custom Jobs -> `<job>` -> CPU / Memory tabs; those tabs read the same metrics.

## Reading the output columns

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
- Saving is **on by default**; pass `--no-save` to skip it.
- There is no read-back command - read the file with `jq` or a notebook.
- The store root is derived from `git rev-parse --show-toplevel`, falling back to the
  current directory. `.vertex-history/` is listed in the repo's `.gitignore`.

Record fields: `run_id`, `pipeline`, `env`, `project`, `region`, `task`, `state`,
`start_time`, `end_time`, `runtime_s`, `machine_type`, `vcpu`, `ram_gib`,
`cpu_peak_frac`, `cpu_peak_vcpu`, `ram_peak_frac`, `ram_peak_gib`, `cost_usd`,
`captured_at`.

Inspect the store with:

```bash
jq -s 'sort_by(.cost_usd) | reverse | .[0:5]' .vertex-history/history.jsonl
```

## Gotchas

- Metric values are fractions (`0.0`-`1.0`), not percentages. Forgetting to multiply
  by 100 is the most common mistake.
- `job_id` is the CustomJob ID, not the pipeline task id.
- Always quote `gcloud compute machine-types describe --format='value(guestCpus,memoryMb)'`;
  the unquoted parentheses break parsing.
- Pipeline job timestamps carry fractional seconds; strip them before `fromdateiso8601`.
