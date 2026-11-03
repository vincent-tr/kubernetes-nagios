#!/bin/bash
# Nagios check: every Kubernetes CronJob must be healthy.
# Usage: check_kube_cronjobs.sh [-n <namespace>] [-m <max age in hours>] [-k <kube config>]
# For each CronJob (all namespaces by default):
#   CRITICAL if a Job it created failed after its last success
#   CRITICAL if -m is given and the last success is older than that (also catches skipped runs)
#   WARNING  if it is suspended or has never succeeded
# Needs kubectl and jq.

NAMESPACE_TARGET=""
MAX_HOURS=0
KUBE_CONFIG=""

while getopts "n:m:k:h" opt; do
  case "$opt" in
    n) NAMESPACE_TARGET=$OPTARG ;;
    m) MAX_HOURS=$OPTARG ;;
    k) KUBE_CONFIG="--kubeconfig $OPTARG" ;;
    *) echo "usage: $0 [-n <namespace>] [-m <max age in hours>] [-k <kube config>]"; exit 3 ;;
  esac
done

type jq >/dev/null 2>&1 || { echo "CRITICAL: The jq utility is required for this script to run."; exit 2; }
type kubectl >/dev/null 2>&1 || { echo "CRITICAL: The kubectl utility is required for this script to run."; exit 3; }

if [ -n "$NAMESPACE_TARGET" ]; then
  NS_OPTION="--namespace $NAMESPACE_TARGET"
else
  NS_OPTION="--all-namespaces"
fi

if ! CRONJOBS=$(kubectl $KUBE_CONFIG get cronjobs $NS_OPTION -o json 2>&1); then
  echo "UNKNOWN - unable to read cronjobs: $CRONJOBS"
  exit 3
fi
if ! JOBS=$(kubectl $KUBE_CONFIG get jobs $NS_OPTION -o json 2>&1); then
  echo "UNKNOWN - unable to read jobs: $JOBS"
  exit 3
fi

EXITCODE=0
RESULT=""
COUNT=0
NOW=$(date +%s)
MAX=$((MAX_HOURS * 3600))

function returnResult () {
  RESULT="$RESULT$1: $2"$'\n'
  if [[ "$1" == "Critical" ]]; then EXITCODE=2; fi
  if [[ "$1" == "Warning" ]] && [ $EXITCODE -eq 0 ]; then EXITCODE=1; fi
}

while IFS=$'\t' read -r NS NAME SUSPEND LAST_OK CREATED; do
  [ -z "$NAME" ] && continue
  [ "$LAST_OK" == "-" ] && LAST_OK=""
  COUNT=$((COUNT + 1))
  ID="$NS/$NAME"

  # Most recent failed Job of this CronJob (ISO timestamps compare lexicographically)
  LAST_FAILED=$(echo "$JOBS" | jq -r --arg ns "$NS" --arg name "$NAME" '
    [.items[]
     | select(.metadata.namespace == $ns)
     | select(any(.metadata.ownerReferences[]?; .kind == "CronJob" and .name == $name))
     | select(any(.status.conditions[]?; .type == "Failed" and .status == "True"))
     | .metadata.creationTimestamp] | max // empty')

  if [ -n "$LAST_FAILED" ] && { [ -z "$LAST_OK" ] || [[ "$LAST_FAILED" > "$LAST_OK" ]]; }; then
    returnResult Critical "$ID: a job failed ($LAST_FAILED) after the last success (${LAST_OK:-never})"
    continue
  fi

  if [ -n "$LAST_OK" ]; then
    AGE=$((NOW - $(date -d "$LAST_OK" +%s)))
    if [ "$MAX" -gt 0 ] && [ "$AGE" -gt "$MAX" ]; then
      returnResult Critical "$ID: last succeeded $((AGE / 3600))h ago (max ${MAX_HOURS}h)"
      continue
    fi
  else
    returnResult Warning "$ID: has never succeeded (created $CREATED)"
    continue
  fi

  if [ "$SUSPEND" == "true" ]; then
    returnResult Warning "$ID: is suspended"
    continue
  fi

  returnResult OK "$ID: last succeeded $((AGE / 3600))h ago"
done < <(echo "$CRONJOBS" | jq -r '.items[] | [.metadata.namespace, .metadata.name, (.spec.suspend // false), (.status.lastSuccessfulTime // "-"), .metadata.creationTimestamp] | @tsv')

case $EXITCODE in
  0) echo "OK - Kubernetes cronjobs are all OK ($COUNT checked)" ;;
  1) echo "WARNING - One or more cronjobs show warning status!" ;;
  2) echo "CRITICAL - One or more cronjobs show critical status!" ;;
esac
printf "%s" "$RESULT"
exit $EXITCODE
