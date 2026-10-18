SHELL := /bin/bash
CLUSTER_NAME := elastic-scale-lab
MISE := mise -C . exec --

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*63898' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-25s\033[0m %s\n", $$1, $$2}'

.PHONY: kind-up cluster-up
cluster-up kind-up: ## Create the local Kind cluster with K8s 1.36 and feature gates
	$(MISE) kind create cluster --config kind-config.yaml

.PHONY: kind-down cluster-down
cluster-down kind-down: ## Tear down the local Kind cluster
	$(MISE) kind delete cluster --name $(CLUSTER_NAME)

.PHONY: install-crds
install-crds: ## Install CRDs for Kueue, KubeRay, and Karpenter
	$(MISE) kubectl apply --server-side -f https://github.com/kubernetes-sigs/kueue/releases/download/v0.10.1/manifests.yaml
	$(MISE) kubectl apply --server-side -f https://raw.githubusercontent.com/ray-project/kuberay/v1.2.2/ray-operator/config/crd/bases/ray.io_rayclusters.yaml
	$(MISE) kubectl apply --server-side -f https://raw.githubusercontent.com/kubernetes-sigs/karpenter/v1.2.1/pkg/apis/crds/karpenter.sh_nodeclaims.yaml
	$(MISE) kubectl apply --server-side -f https://raw.githubusercontent.com/kubernetes-sigs/karpenter/v1.2.1/pkg/apis/crds/karpenter.sh_nodepools.yaml

.PHONY: fmt
fmt: ## Format Go source files
	$(MISE) gofmt -w .

.PHONY: vet
vet: ## Run go vet
	$(MISE) go vet ./...

.PHONY: build
build: fmt vet ## Build the Kyield binary
	mkdir -p bin
	$(MISE) go build -o bin/kyield ./cmd/coordinator
	ln -sf kyield bin/coordinator

.PHONY: run
run: build ## Run Kyield locally against current kubecontext with node simulation
	./bin/kyield --enable-node-simulator

.PHONY: test
test: ## Run the full 9-scenario Chainsaw test suite
	$(MISE) chainsaw test --config tests/chainsaw-config.yaml tests/scenarios/

.PHONY: test-scenario-1 test-scenario-2 test-scenario-3 test-scenario-4 test-scenario-5 test-scenario-6 test-scenario-7 test-scenario-8 test-scenario-9
test-scenario-1:
	$(MISE) chainsaw test --config tests/chainsaw-config.yaml tests/scenarios/01-cold-start-gang/

test-scenario-2:
	$(MISE) chainsaw test --config tests/chainsaw-config.yaml tests/scenarios/02-elastic-scaleup-quota/

test-scenario-3:
	$(MISE) chainsaw test --config tests/chainsaw-config.yaml tests/scenarios/03-collaborative-preemption/

test-scenario-4:
	$(MISE) chainsaw test --config tests/chainsaw-config.yaml tests/scenarios/04-spot-interruption/

test-scenario-5:
	$(MISE) chainsaw test --config tests/chainsaw-config.yaml tests/scenarios/05-anti-theft-reservation/

test-scenario-6:
	$(MISE) chainsaw test --config tests/chainsaw-config.yaml tests/scenarios/06-elastic-reexpansion/

test-scenario-7:
	$(MISE) chainsaw test --config tests/chainsaw-config.yaml tests/scenarios/07-min-viable-replicas/

test-scenario-8:
	$(MISE) chainsaw test --config tests/chainsaw-config.yaml tests/scenarios/08-actor-aware-drain/

test-scenario-9:
	$(MISE) chainsaw test --config tests/chainsaw-config.yaml tests/scenarios/09-cohort-borrowing-reclaim/
