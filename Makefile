SHELL := /bin/bash
CLUSTER_NAME := elastic-scale-lab
MISE := mise -C . exec --

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-25s\033[0m %s\n", $$1, $$2}'

.PHONY: cluster-up
cluster-up: ## Create the local Kind cluster with K8s 1.36 and feature gates
	$(MISE) kind create cluster --config kind-config.yaml

.PHONY: cluster-down
cluster-down: ## Tear down the local Kind cluster
	$(MISE) kind delete cluster --name $(CLUSTER_NAME)

.PHONY: install-crds
install-crds: ## Install CRDs for Kueue, KubeRay, and Karpenter
	$(MISE) kubectl apply --server-side -f https://github.com/kubernetes-sigs/kueue/releases/download/v0.10.1/manifests.yaml
	$(MISE) kubectl apply --server-side -f https://raw.githubusercontent.com/ray-project/kuberay/v1.2.2/ray-operator/config/crd/bases/ray.io_rayclusters.yaml
	$(MISE) kubectl apply --server-side -f https://raw.githubusercontent.com/kubernetes-sigs/karpenter/v1.2.1/pkg/apis/crds/karpenter.sh_nodeclaims.yaml
	$(MISE) kubectl apply --server-side -f https://raw.githubusercontent.com/kubernetes-sigs/karpenter/v1.2.1/pkg/apis/crds/karpenter.sh_nodepools.yaml

.PHONY: test
test: ## Run the full Chainsaw test suite
	$(MISE) chainsaw test --config tests/chainsaw-config.yaml tests/scenarios/

.PHONY: test-scenario-1
test-scenario-1:
	$(MISE) chainsaw test --config tests/chainsaw-config.yaml tests/scenarios/01-cold-start-gang/

.PHONY: test-scenario-2
test-scenario-2:
	$(MISE) chainsaw test --config tests/chainsaw-config.yaml tests/scenarios/02-elastic-scaleup-quota/

.PHONY: test-scenario-3
test-scenario-3:
	$(MISE) chainsaw test --config tests/chainsaw-config.yaml tests/scenarios/03-collaborative-preemption/

.PHONY: test-scenario-4
test-scenario-4:
	$(MISE) chainsaw test --config tests/chainsaw-config.yaml tests/scenarios/04-spot-interruption/

.PHONY: test-scenario-5
test-scenario-5:
	$(MISE) chainsaw test --config tests/chainsaw-config.yaml tests/scenarios/05-anti-theft-reservation/

.PHONY: build
build: ## Build the coordinator binary
	$(MISE) go build -o bin/coordinator ./cmd/coordinator

.PHONY: run
run: build ## Run the coordinator locally against current kubecontext
	./bin/coordinator
