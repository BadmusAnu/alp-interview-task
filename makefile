# Makefile (bash)
SHELL := /usr/bin/bash
.ONESHELL:
.SHELLFLAGS := -eu -o pipefail -c

# ------------------------------------------------------------
# User-configurable variables
# ------------------------------------------------------------
RELEASE_NAME  ?= kube-prometheus-stack
VALUES_FILE   ?= ./deployment/kube-promethues-stack-helm/values.yaml
MANIFESTS_DIR ?= ./deployment/app-kubernetes-manifests

# kind cluster name (only used when --kind is passed)
KIND_CLUSTER ?= kind

# Detect flags
ifneq (,$(findstring --no-prompt,$(MAKECMDGOALS)))
  NO_PROMPT := 1
endif
ifneq (,$(findstring --kind,$(MAKECMDGOALS)))
  USE_KIND := 1
endif

# Pick build step based on flag (default = minikube build)
BUILD_STEP := build
ifeq ($(USE_KIND),1)
  BUILD_STEP := kind-build
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

	@echo "init complete."

# ------------------------------------------------------------
# make build  (default path: Minikube)
# ------------------------------------------------------------
.PHONY: build
build:
	# Build images locally into Minikube (no registry)
	BACKEND_NAME="python-guestbook-backend"; BACKEND_CONTEXT="./app/backend"; \
	FRONTEND_NAME="python-guestbook-frontend"; FRONTEND_CONTEXT="./app/frontend"; \
	echo "Building $$BACKEND_NAME -> $$BACKEND_NAME:latest"; \
	minikube image build -t "$$BACKEND_NAME:latest" "$$BACKEND_CONTEXT"; \
	echo "Building $$FRONTEND_NAME -> $$FRONTEND_NAME:latest"; \
	minikube image build -t "$$FRONTEND_NAME:latest" "$$FRONTEND_CONTEXT"; \
	echo "build complete for backend and frontend"

# kind build/load path (invoked when --kind is passed)
.PHONY: kind-build
kind-build:
	@echo "Building and loading images into kind..."
	docker build -t python-guestbook-backend:latest ./app/backend
	docker build -t python-guestbook-frontend:latest ./app/frontend
	kind load docker-image python-guestbook-backend:latest --name $(KIND_CLUSTER)
	kind load docker-image python-guestbook-frontend:latest --name $(KIND_CLUSTER)

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
	  kubectl apply -f $(MANIFESTS_DIR) -n app
	else
	  echo "No $(MANIFESTS_DIR) directory found; skipping app deployment."
	fi

	@echo "Ensuring monitoring secrets (Grafana admin creds)..."
	GRAF_USER="admin"; \
	GRAF_PASS="$$( (command -v openssl >/dev/null 2>&1 && openssl rand -base64 24) || head -c 32 /dev/urandom | base64 )"; \
	GRAF_PASS="$${GRAF_PASS//[^a-zA-Z0-9]/}"; GRAF_PASS="$${GRAF_PASS:0:24}"; \
	kubectl -n monitoring create secret generic grafana-admin-credentials \
	  --from-literal=admin-user="$$GRAF_USER" \
	  --from-literal=admin-password="$$GRAF_PASS" \
	  --dry-run=client -o yaml | kubectl apply -f -

	@echo "Installing/Upgrading kube-prometheus-stack..."
	helm upgrade --install $(RELEASE_NAME) prometheus-community/kube-prometheus-stack \
	  --namespace monitoring \
	  -f $(VALUES_FILE)

	@echo "Starting port-forwards..."
	# Stop any existing forwards for the same services
	pkill -f "[k]ubectl -n app port-forward svc/python-guestbook-frontend 8080:80" || true
	pkill -f "[k]ubectl -n monitoring port-forward svc/$(RELEASE_NAME)-grafana 3000:80" || true

	# Run forwards in a simple restart loop to survive restarts
	nohup bash -c 'while true; do kubectl -n app port-forward svc/python-guestbook-frontend 8080:80 --address 127.0.0.1; sleep 1; done' >/dev/null 2>&1 &
	nohup bash -c 'while true; do kubectl -n monitoring port-forward svc/$(RELEASE_NAME)-grafana 3000:80 --address 127.0.0.1; sleep 1; done' >/dev/null 2>&1 &
	sleep 2

	@echo "apply complete."
	@echo "Frontend: http://localhost:8080"
	@echo "Grafana : http://localhost:3000"

# ------------------------------------------------------------
# make all (validate + build (minikube by default / kind with --kind) + prompt + apply)
# ------------------------------------------------------------
.PHONY: all
all: validate
	@$(MAKE) $(BUILD_STEP)
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

# Flag targets (no-ops, used for detection)
.PHONY: --no-prompt
--no-prompt:
	@true

.PHONY: --kind
--kind:
	@true
