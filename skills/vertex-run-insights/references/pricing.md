# Pricing reference for `vertex-run-insights`

**Last updated: 2026-10-07**

This document records where the prices in `scripts/prices.tsv` came from and how to refresh them.
The `scripts/vertex_runs.sh` script reads that table to turn a Vertex AI pipeline run's runtime into a USD estimate.

## Scope of what is priced

Only custom-trained model compute is priced: the Vertex AI training machine, measured in node-hours.
Storage, networking and every other GCP service are explicitly out of scope.
This is a deliberate decision by the skill owner: the goal is a fast, dependency-free estimate of the training machine cost, not a full GCP bill.
Because of that, the estimate is intentionally a lower bound on the true cost of a run.

## Where the numbers come from

All rates originate from the Google Cloud Billing Catalog API for the Vertex AI service, service id `C7E2-9256-1C43`.
The SKU list for that service is fetched with:

```
GET https://cloudbilling.googleapis.com/v1/services/C7E2-9256-1C43/skus?currencyCode=USD&pageSize=100
```

The request needs an OAuth bearer token, which `gcloud` can mint on the spot:

```
curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  "https://cloudbilling.googleapis.com/v1/services/C7E2-9256-1C43/skus?currencyCode=USD&pageSize=100"
```

### API limitations that shaped the design

- There is no server-side filter for machine type or region, so a full scan is needed to find the SKUs we care about.
- A full scan is roughly 92 pages at `pageSize=100`.
- The endpoint is rate-limited and returns HTTP 429 under load, so a full scan must paginate with a backoff between pages.
- SKU descriptions are stable enough to parse by hand, and region groups are named in prose, for example "running in EMEA".
  The "running in EMEA" group maps to the `europe-west1` region used by this skill.

Because the API is slow and rate-limited, the skill ships a static table (`scripts/prices.tsv`) instead of calling the API at run time.

## EMEA (`europe-west1`) rates used to build the table

Vertex AI prices machine compute as two separate rates: one per vCPU (core) and one per GiB of memory.
The EMEA rates used to build `prices.tsv` are:

| Family | Core rate (USD per vCPU-hour) | RAM rate (USD per GiB-hour) |
| --- | --- | --- |
| N1 | 0.03998895 | 0.00536015 |
| N2 | 0.03998895 | 0.00536015 |
| E2 | 0.027592375 | 0.003698503 |

N1 and N2 share the same rates in this region.
The node-hour price is then:

```
node_hour_price = (vcpu * core_rate) + (ram_gib * ram_rate)
```

## Format of `scripts/prices.tsv`

The table lives at `scripts/prices.tsv`, relative to the skill directory.
It is tab-separated, and line 1 is a `#` comment header.
The columns are:

| Column | Meaning |
| --- | --- |
| `machine_type` | Vertex AI machine type, for example `n1-standard-64` |
| `region` | GCP region, always `europe-west1` in the current table |
| `usd_per_node_hour` | Computed price per node-hour in USD |
| `vcpu` | Number of vCPUs for the machine type |
| `ram_gib` | Memory in GiB for the machine type |

The current file has 65 rows.
They cover the N1, N2 and E2 families in standard, highmem and highcpu variants, all for `europe-west1`.

Example rows:

```
n1-standard-64	europe-west1	3.845729	64	240.0
e2-standard-4	europe-west1	0.169546	4	16.0
```

Use `n1-standard-64 = $3.845729 per node-hour` as a spot-check reference value.
That is the machine used by the `load-and-save-data` task in the reference pipeline.

## How the script uses the table

1. The script reads the machine type from the CustomJob at `jobSpec.workerPoolSpecs[0].machineSpec.machineType`.
2. It finds the matching `usd_per_node_hour` value in `prices.tsv`.
3. It computes `cost = usd_per_node_hour * (runtime_seconds / 3600)`.

If the machine type is not present in the table, the script prints `price unknown` rather than guessing a price.
This keeps the estimate honest: an unknown machine type is surfaced, not silently approximated.

## Refresh procedure

Refreshing the table is a manual, occasionally-run task.

1. Mint a token and page through the SKU listing with a backoff between requests to avoid HTTP 429:

   ```
   TOKEN=$(gcloud auth print-access-token)
   PAGE_TOKEN=""
   while true; do
     URL="https://cloudbilling.googleapis.com/v1/services/C7E2-9256-1C43/skus?currencyCode=USD&pageSize=100"
     if [ -n "$PAGE_TOKEN" ]; then URL="$URL&pageToken=$PAGE_TOKEN"; fi
     curl -s -H "Authorization: Bearer $TOKEN" "$URL" > "skus-$PAGE_TOKEN.json"
     PAGE_TOKEN=$(jq -r '.nextPageToken // empty' "skus-$PAGE_TOKEN.json")
     [ -z "$PAGE_TOKEN" ] && break
     sleep 2
   done
   ```

2. Filter the SKUs whose description matches the N1, N2 or E2 machine families.
3. Keep only SKUs in the "running in EMEA" region group, which corresponds to `europe-west1`.
4. Separate the core rate from the memory rate for each family.
5. Compute each node-hour price with `(vcpu * core_rate) + (ram_gib * ram_rate)`.
6. Rewrite `scripts/prices.tsv`, keeping the `#` header line first and the tab-separated columns in the same order.
7. Update the "Last updated" date at the top of this document.

Re-run the spot-check on `n1-standard-64` afterwards and confirm it is still `$3.845729 per node-hour` before trusting the refreshed table.
