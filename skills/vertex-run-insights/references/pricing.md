# Pricing reference for `vertex-run-insights`

**Last updated: 2026-10-07**

`scripts/vertex_runs.sh` reads `scripts/prices.tsv` to turn a run's runtime into a USD
estimate. This document records where those prices come from and how to update them.

## Scope of what is priced

Only custom-trained model compute is priced: the Vertex AI training machine, measured in
node-hours. Storage, networking and every other GCP service are out of scope, so the
estimate is intentionally a **lower bound** on the true cost of a run.

## Where the numbers come from

Rates originate from the Google Cloud Billing Catalog API for the Vertex AI service,
service id `C7E2-9256-1C43`:

```bash
curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  "https://cloudbilling.googleapis.com/v1/services/C7E2-9256-1C43/skus?currencyCode=USD&pageSize=100"
```

The API has no server-side filter for machine type or region, so a full scan is needed
(~92 pages at `pageSize=100`), and it rate-limits with HTTP 429. That is why the skill
ships a static table instead of calling the API at run time. Region groups are named in
prose; "running in EMEA" maps to `europe-west1`.

Vertex AI prices machine compute as two rates, one per vCPU and one per GiB of memory.
The EMEA rates used to build the table are:

| Family | Core rate (USD per vCPU-hour) | RAM rate (USD per GiB-hour) |
| --- | --- | --- |
| N1 | 0.03998895 | 0.00536015 |
| N2 | 0.03998895 | 0.00536015 |
| E2 | 0.027592375 | 0.003698503 |

N1 and N2 share the same rates in this region. The node-hour price is:

```
node_hour_price = (vcpu * core_rate) + (ram_gib * ram_rate)
```

## Format of `scripts/prices.tsv`

Tab-separated, with a `#` comment header on line 1. The current file has 65 rows
covering the N1, N2 and E2 families in standard, highmem and highcpu variants, all for
`europe-west1`.

| Column | Meaning |
| --- | --- |
| `machine_type` | Vertex AI machine type, for example `n1-standard-64` |
| `region` | GCP region, always `europe-west1` in the current table |
| `usd_per_node_hour` | Computed price per node-hour in USD |
| `vcpu` | Number of vCPUs for the machine type |
| `ram_gib` | Memory in GiB for the machine type |

Example rows:

```
n1-standard-64	europe-west1	3.845729	64	240.0
e2-standard-4	europe-west1	0.169546	4	16.0
```

The script reads the machine type from the CustomJob at
`jobSpec.workerPoolSpecs[0].machineSpec.machineType`, looks up `usd_per_node_hour`, and
computes `cost = usd_per_node_hour * (runtime_seconds / 3600)`. A machine type that is
not in the table prints `price unknown` rather than a guess.

## How to update the cost data

Manual and occasionally run:

1. Mint a token and page through the SKU listing with a backoff between requests to
   avoid HTTP 429:

   ```bash
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
6. Rewrite `scripts/prices.tsv`, keeping the `#` header line first and the tab-separated
   columns in the same order.
7. Update the "Last updated" date at the top of this document.

Spot-check `n1-standard-64` afterwards and confirm it is still `$3.845729 per
node-hour` before trusting the refreshed table.
