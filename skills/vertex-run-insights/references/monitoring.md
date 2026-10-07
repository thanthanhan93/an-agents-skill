# Cloud Monitoring queries for Vertex AI runs

This document explains *why* `scripts/vertex_runs.sh` queries Cloud Monitoring the way it does.
The goal is to save a future maintainer the hours of trial and error that led to the current query pattern.
Everything here was verified against real production data in JET's ML platform (`jet-ml-dev`, `jet-ml-staging`, `jet-ml-prod`, region `europe-west1`).

## Table of contents

- [Where Vertex custom-job metrics actually live](#where-vertex-custom-job-metrics-actually-live)
- [Metric types under `ml.googleapis.com/training/`](#metric-types-under-mlgoogleapiscomtraining)
- [The query pattern](#the-query-pattern)
- [Why the time window is padded](#why-the-time-window-is-padded)
- [Console equivalent for sanity checks](#console-equivalent-for-sanity-checks)
- [Gotchas](#gotchas)

## Where Vertex custom-job metrics actually live

The single most important discovery is that Vertex AI custom-job resource usage is **not** exposed as the monitored resource type `gce_instance`.
The container does run on a Compute Engine VM, but that VM lives in a Google-managed tenant project.
As a consequence the VM never appears in `gcloud compute instances list` run against your own project.
Anyone who assumes `gce_instance` and greps their own instances will find nothing and wrongly conclude the metrics are missing.

Instead, the metrics are exposed under the monitored resource type `cloudml_job`, with the labels `project_id`, `job_id` and `region`.
Query the resource type directly rather than trying to locate the underlying VM.

The critical detail is what `job_id` actually contains.
It equals the **CustomJob ID** (for example `4512620604880322560`), *not* the pipeline task id.
A pipeline task and its CustomJob are different objects, so a filter built from the task id returns an empty series.

Resolve the CustomJob ID from the pipeline job before querying.
The field `.jobDetail.taskDetails[].executorDetail.containerDetail.mainJob` gives the CustomJob resource name, for example:

```
projects/555228168644/locations/europe-west1/customJobs/4512620604880322560
```

Take the last path segment (`4512620604880322560`) and use it as the `job_id` label value.

## Metric types under `ml.googleapis.com/training/`

All the relevant metric types share the prefix `ml.googleapis.com/training/`.
The script uses the first two and deliberately skips the rest.

- `cpu/utilization` - fraction `0.0`-`1.0` of the CPU allocated to the job.
  Multiply by 100 for a percentage, or by the machine's vCPU count for an absolute vCPU figure.
- `memory/utilization` - fraction `0.0`-`1.0` of the allocated memory.
  Multiply by 100 for a percentage, or by the machine's RAM in GiB for an absolute GiB figure.
- `disk/utilization` - **unreliable and therefore excluded from the script**.
  It reported only about 36-64 KB for a real job, which is obviously wrong.
  Do not use it for real disk figures.
- `accelerator/utilization` and `accelerator/memory/utilization` - present for GPU/TPU jobs but return no data for CPU jobs.
- `network/received_bytes_count` and `network/sent_bytes_count` - available, but not used by the script.

Because CPU and memory are reported as fractions, the script converts them using the machine type's `guestCpus` and `memoryMb` so the report shows absolute units next to percentages.

## The query pattern

The script calls the Cloud Monitoring API directly:

```
GET https://monitoring.googleapis.com/v3/projects/<project>/timeSeries
    ?filter=metric.type="ml.googleapis.com/training/cpu/utilization"
            AND resource.label.job_id="<customJobId>"
    &interval.startTime=<taskStart-300s>&interval.endTime=<taskEnd+600s>
    &pageSize=1000
```

Authentication uses a short-lived access token in the header:

```bash
-H "Authorization: Bearer $(gcloud auth print-access-token)"
```

The values arrive in `.timeSeries[].points[].value.doubleValue`.
The script reduces each series to its peak by taking the `max` over all returned points.

The request is issued with `curl -G --data-urlencode` so the `filter` and `interval` parameters are URL-encoded correctly.
Hand-building the URL tends to break on the quotes and the `AND` inside the filter.

## Why the time window is padded

The script pads the requested window by 5 minutes before the task start and 10 minutes after the task end.
This is not arbitrary; it compensates for two properties of the sampling.

- Sampling is once per minute, so a window that is too tight can clip the boundary points.
- Series typically start a few minutes *after* the task starts, because the container image pull happens first.
- Series also tend to lag past the job end while the last samples flush.

Without the padding the first and last points are missed, which understates peaks.
For a task that is still `RUNNING`, the end of the window is "now" rather than a task end time.

## Console equivalent for sanity checks

A human can verify any number the script reports by opening the Vertex AI console:

```
Vertex AI console -> Custom Jobs -> <job> -> CPU / Memory tabs
```

Those tabs read exactly the same `ml.googleapis.com/training/*` metrics.
Use them to sanity-check a suspicious peak before changing the script.

## Gotchas

- Metric values are fractions (`0.0`-`1.0`), not percentages. Forgetting to multiply by 100 is the most common mistake.
- Always quote `gcloud compute machine-types describe --format='value(guestCpus,memoryMb)'` in bash; the unquoted parentheses break parsing.
- `job_id` is the CustomJob ID, not the pipeline task id. Resolve it via `.jobDetail.taskDetails[].executorDetail.containerDetail.mainJob` first.
