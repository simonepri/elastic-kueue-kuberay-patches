#!/bin/bash
# Bound fixture API requests and polling independently of the test runner's subprocess timeout.

kubectl() {
  local request_timeout=${KUBECTL_REQUEST_TIMEOUT_SECONDS:-5}
  local argument operation_timeout
  for argument in "$@"; do
    case "$argument" in
      --timeout=*)
        operation_timeout=${argument#--timeout=}
        operation_timeout=${operation_timeout%s}
        case "$operation_timeout" in
          ''|*[!0-9]*) echo "Expected a bounded timeout in seconds: $argument" >&2; return 1 ;;
        esac
        request_timeout=$((operation_timeout + 5))
        ;;
    esac
  done
  command kubectl --request-timeout="${request_timeout}s" "$@"
}

wait_for_count() {
  local expected deadline count
  expected=$1
  shift
  deadline=$(($(date +%s) + ${WAIT_TIMEOUT_SECONDS:-20}))
  while :; do
    count=$(kubectl "$@" -o json | jq '.items | length') || return 1
    if [ "$count" = "$expected" ]; then return 0; fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "Timed out waiting for $* count $expected; observed $count" >&2
      return 1
    fi
    sleep 1
  done
}
