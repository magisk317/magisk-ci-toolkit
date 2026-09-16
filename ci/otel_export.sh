#!/usr/bin/env bash
# Export a single OTLP/HTTP JSON span to GitLab Observability.
# Safe no-op on missing curl/network; never fails the caller job.
set -u

span_name="${1:-ci.job}"
shift || true

: "${MAGISK_OTEL_EXPORT:=1}"
: "${MAGISK_OTEL_ENDPOINT:=https://136325658.otel.gitlab-o11y.com:14318/v1/traces}"
: "${MAGISK_OTEL_SERVICE_NAME:=magisk-ci}"
: "${MAGISK_OTEL_TIMEOUT_SEC:=8}"

if [ "${MAGISK_OTEL_EXPORT}" = "0" ] || [ "${MAGISK_OTEL_EXPORT}" = "false" ]; then
  echo "otel: export disabled"
  exit 0
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "otel: curl missing, skip"
  exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "otel: python3 missing, skip"
  exit 0
fi

extra_attrs=()
for arg in "$@"; do
  extra_attrs+=("$arg")
done

# Default CI context attributes
: "${CI_PROJECT_ID:=}"
: "${CI_PROJECT_NAME:=}"
: "${CI_COMMIT_SHA:=}"
: "${CI_COMMIT_TAG:=}"
: "${CI_COMMIT_REF_NAME:=}"
: "${CI_PIPELINE_ID:=}"
: "${CI_JOB_ID:=}"
: "${CI_JOB_NAME:=}"
: "${CI_JOB_STAGE:=}"
: "${CI_JOB_STATUS:=}"
: "${CI_RUNNER_DESCRIPTION:=}"
: "${CI_ENVIRONMENT_NAME:=ci}"

payload="$(
  SPAN_NAME="$span_name" \
  SERVICE_NAME="$MAGISK_OTEL_SERVICE_NAME" \
  ENDPOINT="$MAGISK_OTEL_ENDPOINT" \
  PROJECT_ID="$CI_PROJECT_ID" \
  PROJECT_NAME="$CI_PROJECT_NAME" \
  COMMIT_SHA="$CI_COMMIT_SHA" \
  COMMIT_TAG="$CI_COMMIT_TAG" \
  REF_NAME="$CI_COMMIT_REF_NAME" \
  PIPELINE_ID="$CI_PIPELINE_ID" \
  JOB_ID="$CI_JOB_ID" \
  JOB_NAME="$CI_JOB_NAME" \
  JOB_STAGE="$CI_JOB_STAGE" \
  JOB_STATUS="$CI_JOB_STATUS" \
  RUNNER="$CI_RUNNER_DESCRIPTION" \
  ENVIRONMENT="${CI_ENVIRONMENT_NAME:-ci}" \
  EXTRA_ATTRS="$(printf '%s\n' "${extra_attrs[@]}")" \
  python3 - <<'PY'
import json, os, time, uuid

def sid(n=16):
    return uuid.uuid4().hex[:n]

def attr(key, value):
    if value is None:
        return None
    value = str(value)
    if value == "":
        return None
    return {"key": key, "value": {"stringValue": value}}

now = time.time_ns()
start = now - 1_000_000
attrs = [
    attr("magisk.event", os.environ.get("SPAN_NAME", "ci.job")),
    attr("ci.pipeline_id", os.environ.get("PIPELINE_ID")),
    attr("ci.job.id", os.environ.get("JOB_ID")),
    attr("ci.job.name", os.environ.get("JOB_NAME")),
    attr("ci.job.stage", os.environ.get("JOB_STAGE")),
    attr("ci.job.status", os.environ.get("JOB_STATUS")),
    attr("ci.ref", os.environ.get("REF_NAME")),
    attr("ci.tag", os.environ.get("COMMIT_TAG")),
    attr("ci.runner", os.environ.get("RUNNER")),
]
for line in os.environ.get("EXTRA_ATTRS", "").splitlines():
    line = line.strip()
    if not line or "=" not in line:
        continue
    k, v = line.split("=", 1)
    attrs.append(attr(k.strip(), v.strip()))
attrs = [a for a in attrs if a is not None]

resource_attrs = [
    attr("service.name", os.environ.get("SERVICE_NAME", "magisk-ci")),
    attr("service.version", os.environ.get("COMMIT_SHA") or "unknown"),
    attr("deployment.environment.name", os.environ.get("ENVIRONMENT") or "ci"),
    attr("gitlab.project.id", os.environ.get("PROJECT_ID")),
    attr("gitlab.project.name", os.environ.get("PROJECT_NAME")),
]
resource_attrs = [a for a in resource_attrs if a is not None]

status_code = 1  # STATUS_CODE_OK
job_status = (os.environ.get("JOB_STATUS") or "").lower()
if job_status in {"failed", "canceled", "cancelled"}:
    status_code = 2  # STATUS_CODE_ERROR

body = {
    "resourceSpans": [{
        "resource": {"attributes": resource_attrs},
        "scopeSpans": [{
            "scope": {"name": "magisk.ci.otel", "version": "1"},
            "spans": [{
                "traceId": sid(32),
                "spanId": sid(16),
                "name": os.environ.get("SPAN_NAME", "ci.job"),
                "kind": 1,
                "startTimeUnixNano": str(start),
                "endTimeUnixNano": str(now),
                "attributes": attrs,
                "status": {"code": status_code},
            }],
        }],
    }]
}
print(json.dumps(body, separators=(",", ":")))
PY
)" || {
  echo "otel: failed to build payload"
  exit 0
}

code="$(
  curl -sS -m "${MAGISK_OTEL_TIMEOUT_SEC}" \
    -o /tmp/magisk-otel-response.json \
    -w '%{http_code}' \
    -X POST "${MAGISK_OTEL_ENDPOINT}" \
    -H 'Content-Type: application/json' \
    --data-binary "${payload}" \
    || true
)"

if [ "${code}" = "200" ] || [ "${code}" = "202" ]; then
  echo "otel: exported span '${span_name}' http=${code}"
else
  echo "otel: export skipped/failed span='${span_name}' http=${code:-000}"
fi
exit 0
