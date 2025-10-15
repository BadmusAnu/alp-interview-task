# Makefile (bash)
SHELL := /usr/bin/env bash
.ONESHELL:
.SHELLFLAGS := -eu -o pipefail -c

# ------------------------------------------------------------
# User-configurable variables
# ------------------------------------------------------------
RELEASE_NAME  ?= kube-prometheus-stack
VALUES_FILE   ?= ./deployment/kube-prometheus-stack-helm/monitoring-values.yaml
MANIFESTS_DIR ?= ./app-kubernetes-manifests

# Internal file for local registry info
ENV_FILE := .local.env

# Detect non-interactive flag
ifneq (,$(findstring --no-prompt,$(MAKECMDGOALS)))
  NO_PROMPT := 1
endif

# ------------------------------------------------------------
# make init
# ------------------------------------------------------------
.PHONY: init
init:
	@echo "Checking Kubernetes cluster..."
	if ! kubectl cluster-info >/dev/null 2>&1; then
	  echo "No cluster detected. Please start Minikube: 'minikube start'"; exit 1; fi

	@echo "Checking Helm installation..."
	if ! command -v helm >/dev/null 2>&1; then
	   echo "Helm not found, installing...";
	   curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3;
	   chmod 700 get_helm.sh;
	   ./get_helm.sh;
	fi

	@echo "Adding prometheus-community Helm repo..."
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
	helm repo update >/dev/null

	@echo "Creating namespaces..."
	kubectl get ns app >/dev/null 2>&1 || kubectl create ns app
	kubectl get ns monitoring >/dev/null 2>&1 || kubectl create ns monitoring

	@echo "Enabling Minikube registry..."
	if command -v minikube >/dev/null 2>&1; then
	  echo "Enabling Minikube registry..."
	  minikube addons enable registry >/dev/null 2>&1 || true

	  echo "Configuring registry as a pull-through cache for quay.io..."
	  kubectl -n kube-system set env deploy/registry REGISTRY_PROXY_REMOTEURL=https://quay.io >/dev/null

	  echo "Restarting registry to apply settings..."
	  kubectl -n kube-system rollout restart deploy/registry >/dev/null
	  kubectl -n kube-system rollout status deploy/registry --timeout=120s || true
	  sleep 2

	  REG_URL=$$(minikube -n kube-system service registry --url 2>/dev/null | head -n1 || true)
	  CLUSTER_SVC="registry.kube-system.svc.cluster.local:5000"

	  if [ -n "$$REG_URL" ]; then
	    { echo "REGISTRY_URL=$$REG_URL"; echo "REGISTRY_CLUSTER=$$CLUSTER_SVC"; } > $(ENV_FILE)
	    echo "Local registry (host): $$REG_URL"
	    echo "Local registry (cluster DNS): $$CLUSTER_SVC"
	    echo "Proxying upstream: quay.io"
	  else
	    echo "Could not detect registry URL; run 'minikube addons list' to confirm it's running."
	  fi
	else
	  echo "Minikube not detected; skipping registry setup."
	fi


	@echo "init complete."

# ------------------------------------------------------------
# make build
# ------------------------------------------------------------
.PHONY: build
build:
	@source $(ENV_FILE) 2>/dev/null || true; \
	REG_URL="$${REGISTRY_URL:-}"; \
	if [ -z "$$REG_URL" ]; then \
	  echo "Missing REGISTRY_URL. Run 'make init' first."; exit 1; fi; \
	TARGET="$${REG_URL#http://}/myapp:local"; \
	echo "Building Docker image: $$TARGET"; \
	docker build -t $$TARGET .; \
	echo "Pushing image to local registry..."; \
	if ! docker push $$TARGET; then \
	  echo "Push failed. Re-run 'make init' to ensure registry is running."; exit 1; fi; \
	echo "build complete."

# ------------------------------------------------------------
# make validate
# ------------------------------------------------------------
.PHONY: validate
validate:
	@echo "Validating app manifests (server-side dry-run)..."
	if [ -d "$(MANIFESTS_DIR)" ]; then
	  kubectl apply --dry-run=server -f $(MANIFESTS_DIR)
	else
	  echo "Directory $(MANIFESTS_DIR) not found; skipping app validation."
	fi

	@echo "Validating kube-prometheus-stack Helm install..."
	helm upgrade --install $(RELEASE_NAME) prometheus-community/kube-prometheus-stack \
	  --namespace monitoring \
	  -f $(VALUES_FILE) \
	  --dry-run --debug

	@echo "validate complete."

# ------------------------------------------------------------
# make apply
# ------------------------------------------------------------
.PHONY: apply
apply:
	@echo "Applying app manifests..."
	if [ -d "$(MANIFESTS_DIR)" ]; then
	  kubectl apply -f $(MANIFESTS_DIR)
	else
	  echo "No $(MANIFESTS_DIR) directory found; skipping app deployment."
	fi

	@echo "Installing/Upgrading kube-prometheus-stack..."
	helm upgrade --install $(RELEASE_NAME) prometheus-community/kube-prometheus-stack \
	  --namespace monitoring \
	  -f $(VALUES_FILE)

	@echo "Starting port-forwards..."
	nohup kubectl -n app port-forward svc/frontend 8080:80 >/dev/null 2>&1 &
	nohup kubectl -n monitoring port-forward svc/$(RELEASE_NAME)-grafana 3000:80 >/dev/null 2>&1 &
	sleep 2

	@echo "apply complete."
	@echo "Frontend: http://localhost:8080"
	@echo "Grafana : http://localhost:3000"

# ------------------------------------------------------------
# make all (validate + prompt + apply)
# ------------------------------------------------------------
.PHONY: all
all: validate
	@if [[ "$${NO_PROMPT:-}" == "1" ]]; then \
	  $(MAKE) apply; \
	else \
	  read -p "Proceed to apply? [y/N]: " ans; \
	  if [[ "$$ans" =~ ^([yY]|[yY][eE][sS])$$ ]]; then \
	    $(MAKE) apply; \
	  else \
	    echo "Aborted."; \
	  fi; \
	fi

.PHONY: --no-prompt
--no-prompt:
	@true
