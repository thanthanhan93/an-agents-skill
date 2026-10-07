#!/usr/bin/env bash
#
# vertex_runs.sh - inspect Vertex AI pipeline runs, per-task resource usage and cost.
#
# Scope: read-only inspection of Vertex AI pipelines in jet-ml-{dev,staging,prod}.
# See ../SKILL.md for the full contract and guardrails.
#
# Commands:
#   vertex_runs.sh runs  --pipeline NAME [--env prod] [--limit 10]
#   vertex_runs.sh tasks --pipeline NAME --run-id ID [--env prod]
#   vertex_runs.sh usage --pipeline NAME --run-id ID [--task TASK] [--env prod]
#
# Common flags: --env dev|staging|prod  --project ID  --region R  --no-save

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRICES="${SCRIPT_DIR}/prices.tsv"

# ---------------------------------------------------------------------------
# Defaults (always echoed to the user so a default is never silently applied)
# ---------------------------------------------------------------------------
ENV="prod"
PROJECT=""
REGION="europe-west1"
LIMIT="10"
PIPELINE=""
RUN_ID=""
TASK_FILTER=""
SAVE="1"

CMD="${1:-}"
shift || true

usage() {
  cat <<'EOF'
vertex_runs.sh - inspect Vertex AI pipeline runs, task usage and cost

Usage:
  vertex_runs.sh runs  --pipeline NAME [--env prod] [--limit 10]
  vertex_runs.sh tasks --pipeline NAME --run-id ID [--env prod]
  vertex_runs.sh usage --pipeline NAME --run-id ID [--task TASK] [--env prod]

Options:
  --env dev|staging|prod   Platform environment (default: prod)
  --project ID             Override GCP project (default: jet-ml-<env>)
  --region R               Override region (default: europe-west1)
  --limit N                Number of runs for 'runs' (default: 10)
  --run-id ID              Pipeline run id or full resource name
  --task NAME              Restrict 'usage' to one task
  --no-save                Do not append/update the local history store
  -h, --help               Show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --env) ENV="$2"; shift 2 ;;
    --project) PROJECT="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --limit) LIMIT="$2"; shift 2 ;;
    --pipeline) PIPELINE="$2"; shift 2 ;;
    --run-id) RUN_ID="$2"; shift 2 ;;
    --task) TASK_FILTER="$2"; shift 2 ;;
    --no-save) SAVE="0"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 64 ;;
  esac
done

# ---------------------------------------------------------------------------
# Guardrails: only the three platform environments/projects are allowed.
# ---------------------------------------------------------------------------
case "$ENV" in
  dev)     DEFAULT_PROJECT="jet-ml-dev" ;;
  staging) DEFAULT_PROJECT="jet-ml-staging" ;;
  prod)    DEFAULT_PROJECT="jet-ml-prod" ;;
  *) echo "ERROR: --env must be one of dev|staging|prod (got '$ENV')" >&2; exit 64 ;;
esac
[ -n "$PROJECT" ] || PROJECT="$DEFAULT_PROJECT"

case "$PROJECT" in
  jet-ml-dev|jet-ml-staging|jet-ml-prod) ;;
  *) echo "ERROR: refusing to query project '$PROJECT'. Allowed: jet-ml-dev, jet-ml-staging, jet-ml-prod" >&2; exit 64 ;;
esac

AI_BASE="https://${REGION}-aiplatform.googleapis.com/v1/projects/${PROJECT}/locations/${REGION}"
MON_BASE="https://monitoring.googleapis.com/v3/projects/${PROJECT}"

echo "# defaults: env=${ENV} project=${PROJECT} region=${REGION} (override with --env/--project/--region)"
[ "$REGION" = "europe-west1" ] || echo "# note: non-default region '${REGION}' in use"

# ---------------------------------------------------------------------------
# Auth - stop and tell the user to authenticate rather than working around it.
# ---------------------------------------------------------------------------
get_token() {
  local t
  if ! t="$(gcloud auth print-access-token 2>/dev/null)" || [ -z "$t" ]; then
    echo "ERROR: gcloud authentication failed or expired." >&2
    echo "Run:  gcloud auth login" >&2
    exit 2
  fi
  printf '%s' "$t"
}
TOKEN="$(get_token)"

api() { # $1 = full url ; streams JSON
  curl -sS -H "Authorization: Bearer ${TOKEN}" "$1"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
# jq filter: parse an ISO-8601 UTC timestamp with optional fractional seconds.
JQ_EPOCH='def ep: if (.==null or .=="") then null else (sub("\\.[0-9]+Z$";"Z")|fromdateiso8601) end;'
# jq filter: seconds -> compact "1h 2m 3s" style duration.
JQ_DUR='def dur: if .==null then "-" elif .<0 then "-" else ((./3600|floor) as $h | ((.%3600)/60|floor) as $m | (.%60) as $s | (if $h>0 then "\($h)h\($m)m" elif $m>0 then "\($m)m\($s)s" else "\($s)s" end)) end;'

# Live machine spec lookup; falls back to prices.tsv; else "unknown".
machine_specs() { # $1 = machine_type -> prints "vcpu<TAB>ram_gib" or "unknown<TAB>unknown"
  local mt="$1" out
  if [ -z "$mt" ] || [ "$mt" = "null" ]; then echo -e "unknown\tunknown"; return; fi
  if out="$(gcloud compute machine-types describe "$mt" --zone="${REGION}-b" --project="$PROJECT" \
            --format='value(guestCpus,memoryMb)' 2>/dev/null)" && [ -n "$out" ]; then
    echo "$out" | awk '{printf "%s\t%.2f\n", $1, $2/1024}'
    return
  fi
  # fallback: prices.tsv columns 4 (vcpu) and 5 (ram_gib)
  out="$(awk -F'\t' -v m="$mt" '!/^#/ && $1==m {print $4"\t"$5}' "$PRICES" | head -1)"
  if [ -n "$out" ]; then echo "$out"; else echo -e "unknown\tunknown"; fi
}

price_for() { # $1 = machine_type -> usd per node-hour or empty
  awk -F'\t' -v m="$1" '!/^#/ && $1==m {print $3; exit}' "$PRICES"
}

resolve_pipeline() { # validate exact displayName; on miss list candidates and exit
  local found
  found="$(api "${AI_BASE}/pipelineJobs?filter=displayName%3D%22${PIPELINE}%22&pageSize=1" \
            | jq -r '.pipelineJobs | length')"
  if [ "${found:-0}" != "0" ]; then return 0; fi
  echo "ERROR: no pipeline run found with displayName '${PIPELINE}' in ${PROJECT}." >&2
  echo "" >&2
  echo "Known pipeline names (recent runs in ${PROJECT}):" >&2
  api "${AI_BASE}/pipelineJobs?pageSize=100" \
    | jq -r '(.pipelineJobs // [])[].displayName' | sort -u | sed 's/^/  - /' >&2
  exit 3
}

# Fetch one pipelineJob -> JSON on stdout
get_pipeline_job() { # $1 = run id (short) or full resource name
  local name="$1"
  case "$name" in
    projects/*) api "https://${REGION}-aiplatform.googleapis.com/v1/${name}" ;;
    *)          api "${AI_BASE}/pipelineJobs/${name}" ;;
  esac
}

# Build a JSON array of real compute tasks (those backed by a custom job).
# Wrapper tasks such as the pipeline root and If-condition containers have no
# custom job, so they are skipped - they are not billable compute.
tasks_json() { # stdin = pipelineJob json
  jq -c '
    [ .jobDetail.taskDetails[]
      | select(.executorDetail.containerDetail.mainJob != null)
      | { task: .taskName,
          state: .state,
          start: .startTime,
          end: .endTime,
          custom_job: (.executorDetail.containerDetail.mainJob | split("/") | last) }
    ]'
}

# ---------------------------------------------------------------------------
# Local history store: <repo>/.vertex-history/history.jsonl
# One line per task. Key = run_id + task. Re-saving replaces that task's line.
# ---------------------------------------------------------------------------
store_path() {
  local root
  root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  printf '%s/.vertex-history/history.jsonl' "$root"
}

merge_store() { # $1 = store file, $2 = file of newline-delimited JSON records
  local store="$1" newf="$2" tmp
  [ "$SAVE" = "1" ] || return 0
  [ -s "$newf" ] || return 0
  mkdir -p "$(dirname "$store")"
  tmp="$(mktemp)"
  if [ -s "$store" ]; then
    jq -c -s --slurpfile new "$newf" '
      ($new | map(.run_id + "|" + .task)) as $keys
      | .[] | select((.run_id + "|" + .task) as $k | ($keys | index($k)) == null)
    ' "$store" > "$tmp"
  fi
  cat "$newf" >> "$tmp"
  mv "$tmp" "$store"
  echo "# saved: $(wc -l < "$newf" | tr -d ' ') task record(s) -> ${store}"
}

# ---------------------------------------------------------------------------
# Command: runs
# ---------------------------------------------------------------------------
cmd_runs() {
  [ -n "$PIPELINE" ] || { echo "ERROR: --pipeline is required" >&2; exit 64; }
  resolve_pipeline
  echo
  printf '%-46s %-10s %-20s %-12s\n' "RUN_ID" "STATE" "CREATED (UTC)" "RUNTIME"
  api "${AI_BASE}/pipelineJobs?filter=displayName%3D%22${PIPELINE}%22&orderBy=createTime%20desc&pageSize=${LIMIT}" \
    | jq -r --argjson lim "$LIMIT" "
      ${JQ_EPOCH}
      ${JQ_DUR}
      .pipelineJobs[:${LIMIT}][]
      | (.startTime|ep) as \$s | (.endTime|ep) as \$e
      | [ (.name|split(\"/\")|last), .state, (.createTime // \"-\"),
          (if \$s==null then \"-\" elif \$e==null then \"running\" else ((\$e-\$s)|dur) end) ]
      | @tsv" \
    | while IFS=$'\t' read -r rid state created runtime; do
        printf '%-52s %-10s %-20s %-12s\n' "$rid" "$state" "$created" "$runtime"
      done
}

# ---------------------------------------------------------------------------
# Command: tasks
# ---------------------------------------------------------------------------
cmd_tasks() {
  [ -n "$PIPELINE" ] || { echo "ERROR: --pipeline is required" >&2; exit 64; }
  [ -n "$RUN_ID" ]   || { echo "ERROR: --run-id is required"   >&2; exit 64; }
  local pj run_short store tmpf
  pj="$(get_pipeline_job "$RUN_ID")"
  run_short="$(printf '%s' "$pj" | jq -r '.name|split("/")|last')"
  store="$(store_path)"
  tmpf="$(mktemp)"
  echo
  printf '%-34s %-10s %-12s %-20s %-9s %-8s\n' "TASK" "STATE" "RUNTIME" "MACHINE" "vCPU" "RAM_GiB"
  printf '%s' "$pj" | tasks_json | jq -c '.[]' | while read -r t; do
    local task state start end cj mt rt rt_s
    task="$(printf '%s' "$t" | jq -r '.task')"
    state="$(printf '%s' "$t" | jq -r '.state')"
    start="$(printf '%s' "$t" | jq -r '.start // ""')"
    end="$(printf '%s' "$t" | jq -r '.end // ""')"
    cj="$(printf '%s' "$t" | jq -r '.custom_job')"
    rt_s="$(jq -nr --arg s "$start" --arg e "$end" "${JQ_EPOCH} (\$s|ep) as \$se | (\$e|ep) as \$ee | if \$se==null or \$ee==null then null else (\$ee-\$se) end")"
    rt="$(jq -nr --argjson v "${rt_s:-null}" "${JQ_DUR} if \$v==null then (if \"$start\"==\"\" then \"-\" else \"running\" end) else (\$v|dur) end")"
    mt="$(api "${AI_BASE}/customJobs/${cj}" | jq -r '.jobSpec.workerPoolSpecs[0].machineSpec.machineType // "unknown"')"
    local spec vcpu ram
    spec="$(machine_specs "$mt")"; vcpu="$(printf '%s' "$spec" | cut -f1)"; ram="$(printf '%s' "$spec" | cut -f2)"
    printf '%-34s %-10s %-12s %-20s %-9s %-8s\n' "$task" "$state" "$rt" "$mt" "$vcpu" "$ram"
    # persist (usage fields null here; 'usage' will enrich them)
    printf '{"run_id":"%s","pipeline":"%s","env":"%s","project":"%s","region":"%s","task":"%s","state":"%s","start_time":"%s","end_time":"%s","runtime_s":%s,"machine_type":"%s","vcpu":"%s","ram_gib":"%s","cpu_peak_frac":null,"cpu_peak_vcpu":null,"ram_peak_frac":null,"ram_peak_gib":null,"cost_usd":null,"captured_at":"%s"}\n' \
      "$run_short" "$PIPELINE" "$ENV" "$PROJECT" "$REGION" "$task" "$state" "$start" "$end" \
      "${rt_s:-null}" "$mt" "$vcpu" "$ram" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$tmpf"
  done
  merge_store "$store" "$tmpf"
  rm -f "$tmpf"
}

# ---------------------------------------------------------------------------
# Command: usage
# ---------------------------------------------------------------------------
cmd_usage() {
  [ -n "$PIPELINE" ] || { echo "ERROR: --pipeline is required" >&2; exit 64; }
  [ -n "$RUN_ID" ]   || { echo "ERROR: --run-id is required"   >&2; exit 64; }
  local pj run_short store tmpf
  pj="$(get_pipeline_job "$RUN_ID")"
  run_short="$(printf '%s' "$pj" | jq -r '.name|split("/")|last')"
  store="$(store_path)"
  tmpf="$(mktemp)"

  echo
  printf '%-30s %-10s %-11s %-10s %-11s %-10s %-11s %-10s\n' \
    "TASK" "STATE" "CPU_PEAK" "CPU(vCPU)" "RAM_PEAK" "RAM(GiB)" "RUNTIME" "COST_USD"
  printf '%s' "$pj" | tasks_json | jq -c '.[]' | while read -r t; do
    local task state start end cj mt spec vcpu ram cpu_peak ram_peak rt price cost
    task="$(printf '%s' "$t" | jq -r '.task')"
    [ -z "$TASK_FILTER" ] || [ "$task" = "$TASK_FILTER" ] || continue
    state="$(printf '%s' "$t" | jq -r '.state')"
    start="$(printf '%s' "$t" | jq -r '.start // ""')"
    end="$(printf '%s' "$t" | jq -r '.end // ""')"
    cj="$(printf '%s' "$t" | jq -r '.custom_job')"
    mt="$(api "${AI_BASE}/customJobs/${cj}" | jq -r '.jobSpec.workerPoolSpecs[0].machineSpec.machineType // "unknown"')"
    spec="$(machine_specs "$mt")"; vcpu="$(printf '%s' "$spec" | cut -f1)"; ram="$(printf '%s' "$spec" | cut -f2)"

    # time window padded around the task (monitoring lags and edges are sparse)
    local win wstart wend
    win="$(jq -nr --arg s "$start" --arg e "$end" "${JQ_EPOCH} (\$s|ep) as \$se | (if (\$e|length)>0 then (\$e|ep) else (now|floor) end) as \$ee | {start:((\$se-300)|strftime(\"%Y-%m-%dT%H:%M:%SZ\")), end:((\$ee+600)|strftime(\"%Y-%m-%dT%H:%M:%SZ\"))}")"
    wstart="$(printf '%s' "$win" | jq -r '.start')"
    wend="$(printf '%s' "$win" | jq -r '.end')"

    peak() { # $1 = cpu|memory
      curl -sS -G -H "Authorization: Bearer ${TOKEN}" \
        --data-urlencode "filter=metric.type=\"ml.googleapis.com/training/$1/utilization\" AND resource.label.job_id=\"${cj}\"" \
        --data-urlencode "interval.startTime=${wstart}" \
        --data-urlencode "interval.endTime=${wend}" \
        --data-urlencode "pageSize=1000" \
        "${MON_BASE}/timeSeries" \
        | jq -r '[.timeSeries[]?.points[]?.value.doubleValue] | if length>0 then max else null end'
    }
    cpu_peak="$(peak cpu)"
    ram_peak="$(peak memory)"

    rt="$(jq -nr --arg s "$start" --arg e "$end" "${JQ_EPOCH} (\$s|ep) as \$se | (if (\$e|length)>0 then (\$e|ep) else (now|floor) end) as \$ee | if \$se==null then null else (\$ee-\$se) end")"
    price="$(price_for "$mt")"
    cost="$(jq -nr --argjson rt "${rt:-null}" --arg p "${price:-}" 'if $rt==null or $p=="" then null else (($p|tonumber)*($rt/3600)) end')"

    local cpu_pct cpu_vcpu ram_pct ram_gib
    cpu_pct="$(jq -nr --argjson v "${cpu_peak:-null}" 'if $v==null then "-" else (($v*10000|round)/100|tostring)+"%" end')"
    cpu_vcpu="$(jq -nr --argjson v "${cpu_peak:-null}" --arg n "${vcpu:-unknown}" 'if $v==null or $n=="unknown" then "-" else (($v*($n|tonumber)*100|round)/100|tostring) end')"
    ram_pct="$(jq -nr --argjson v "${ram_peak:-null}" 'if $v==null then "-" else (($v*10000|round)/100|tostring)+"%" end')"
    ram_gib="$(jq -nr --argjson v "${ram_peak:-null}" --arg n "${ram:-unknown}" 'if $v==null or $n=="unknown" then "-" else (($v*($n|tonumber)*100|round)/100|tostring) end')"
    local cost_disp rt_disp
    cost_disp="$(jq -nr --argjson c "${cost:-null}" 'if $c==null then "unknown" elif $c < 0.01 then (($c*10000|round)/10000|tostring) else (($c*100|round)/100|tostring) end')"
    rt_disp="$(jq -nr --argjson v "${rt:-null}" --arg e "$end" "${JQ_DUR} if \$v==null then \"-\" elif (\$e|length)==0 then \"running\" else (\$v|dur) end")"

    printf '%-30s %-10s %-11s %-10s %-11s %-10s %-11s %-10s\n' "$task" "$state" "$cpu_pct" "$cpu_vcpu" "$ram_pct" "$ram_gib" "$rt_disp" "$cost_disp"

    printf '{"run_id":"%s","pipeline":"%s","env":"%s","project":"%s","region":"%s","task":"%s","state":"%s","start_time":"%s","end_time":"%s","runtime_s":%s,"machine_type":"%s","vcpu":"%s","ram_gib":"%s","cpu_peak_frac":%s,"cpu_peak_vcpu":%s,"ram_peak_frac":%s,"ram_peak_gib":%s,"cost_usd":%s,"captured_at":"%s"}\n' \
      "$run_short" "$PIPELINE" "$ENV" "$PROJECT" "$REGION" "$task" "$state" "$start" "$end" \
      "${rt:-null}" "$mt" "$vcpu" "$ram" \
      "${cpu_peak:-null}" "$(jq -nr --argjson v "${cpu_peak:-null}" --arg n "${vcpu:-unknown}" 'if $v==null or $n=="unknown" then "null" else ($v*($n|tonumber)) end')" \
      "${ram_peak:-null}" "$(jq -nr --argjson v "${ram_peak:-null}" --arg n "${ram:-unknown}" 'if $v==null or $n=="unknown" then "null" else ($v*($n|tonumber)) end')" \
      "${cost:-null}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$tmpf"
  done

  merge_store "$store" "$tmpf"
  rm -f "$tmpf"
}

# ---------------------------------------------------------------------------
case "$CMD" in
  runs)  cmd_runs ;;
  tasks) cmd_tasks ;;
  usage) cmd_usage ;;
  ""|-h|--help) usage ;;
  *) echo "Unknown command: $CMD" >&2; usage >&2; exit 64 ;;
esac
