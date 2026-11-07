#!/usr/bin/env bash
# Run patched Kueue integration test suites against envtest.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT/third_party/kueue"

make test-integration \
  INTEGRATION_TARGET=./test/integration/singlecluster/scheduler \
  INTEGRATION_NPROCS=1 \
  'INTEGRATION_FILTERS=--focus="Greedy flavor fill"'

make test-integration \
  INTEGRATION_TARGET=./test/integration/singlecluster/tas/... \
  INTEGRATION_NPROCS=4

make test-integration \
  INTEGRATION_TARGET=./test/integration/singlecluster/controller/jobs/rayjob/... \
  INTEGRATION_NPROCS=1

make test-integration \
  INTEGRATION_TARGET=./test/integration/singlecluster/controller/jobs/raycluster/... \
  INTEGRATION_NPROCS=1

make test-integration \
  INTEGRATION_TARGET=./test/integration/singlecluster/webhook/jobs/... \
  INTEGRATION_NPROCS=1 \
  'INTEGRATION_FILTERS=--focus="RayCluster Webhook"'
