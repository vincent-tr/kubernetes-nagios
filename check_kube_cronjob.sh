#!/bin/bash
# Nagios check: a Kubernetes CronJob must have succeeded recently.
# Usage: check_kube_cronjob.sh -n <namespace> -j <cronjob> [-m <max age in hours>] [-k <kube config>]
# CRITICAL if the last successful run is older than the max age (default 26h),
# which also covers failed runs, skipped runs and a suspended CronJob.
# Needs kubectl and jq.

namespace=""
cronjob=""
max_hours=26
KUBE_CONFIG=""

while getopts "n:j:m:k:" opt; do
  case "$opt" in
    n) namespace=$OPTARG ;;
    j) cronjob=$OPTARG ;;
    m) max_hours=$OPTARG ;;
    k) KUBE_CONFIG="--kubeconfig $OPTARG" ;;
    *) echo "UNKNOWN - usage: $0 -n <namespace> -j <cronjob> [-m <hours>] [-k <kube config>]"; exit 3 ;;
  esac
done

if [ -z "$namespace" ] || [ -z "$cronjob" ]; then
  echo "UNKNOWN - usage: $0 -n <namespace> -j <cronjob> [-m <hours>] [-k <kube config>]"
  exit 3
fi

if ! json=$(kubectl $KUBE_CONFIG -n "$namespace" get cronjob "$cronjob" -o json 2>&1); then
  echo "UNKNOWN - cannot read cronjob $namespace/$cronjob: $json"
  exit 3
fi

last=$(echo "$json" | jq -r '.status.lastSuccessfulTime // empty')
created=$(echo "$json" | jq -r '.metadata.creationTimestamp')
now=$(date +%s)
max=$((max_hours * 3600))

if [ -z "$last" ]; then
  age=$((now - $(date -d "$created" +%s)))
  if [ "$age" -lt "$max" ]; then
    echo "WARNING - cronjob $namespace/$cronjob has not succeeded yet (created $((age / 3600))h ago)"
    exit 1
  fi
  echo "CRITICAL - cronjob $namespace/$cronjob never succeeded"
  exit 2
fi

age=$((now - $(date -d "$last" +%s)))
if [ "$age" -gt "$max" ]; then
  echo "CRITICAL - cronjob $namespace/$cronjob last succeeded $((age / 3600))h ago (max ${max_hours}h)"
  exit 2
fi

echo "OK - cronjob $namespace/$cronjob last succeeded $((age / 3600))h ago"
exit 0
