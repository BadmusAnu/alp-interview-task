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


# Control variables (override at invocation: PROMPT=false KIND=true)
PROMPT ?= true
KIND ?= false

# kind cluster name (only used when --kind is passed)
KIND_CLUSTER ?= kind

# Pick build step based on flag (default = minikube build)
BUILD_STEP := build
ifeq ($(KIND),true)
  BUILD_STEP := kind-build
endif

# ------------------------------------------------------------
# make init
# ------------------------------------------------------------
.PHONY: init
init:
	@echo "Checking Kubernetes cluster..."
	if ! kubectl cluster-info >/dev/null 2>&1; then
	  echo "No cluster detected. Please start Minikube: 'minikube start' or start kind cluster"; exit 1; fi

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
	if kubectl -n monitoring get secret grafana-admin-credentials >/dev/null 2>&1; then \
	  echo "grafana-admin-credentials exists; leaving unchanged."; \
	else \
	  GRAF_USER="$${GRAFANA_ADMIN_USER:-admin}"; \
	  GRAF_PASS="$${GRAFANA_ADMIN_PASSWORD:-}"; \
	  if [[ -z "$${GRAF_PASS:-}" ]]; then \
	    if command -v openssl >/dev/null 2>&1; then \
	      GRAF_PASS="$$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | cut -c1-24)"; \
	    else \
	      GRAF_PASS="$$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-24)"; \
	    fi; \
	  fi; \
	  kubectl -n monitoring create secret generic grafana-admin-credentials \
	    --from-literal=admin-user="$$GRAF_USER" \
	    --from-literal=admin-password="$$GRAF_PASS"; \
	  echo "Created grafana-admin-credentials secret."; \
	fi

	@echo "Installing/Upgrading kube-prometheus-stack..."
	helm upgrade --install $(RELEASE_NAME) prometheus-community/kube-prometheus-stack \
	  --namespace monitoring \
	  -f $(VALUES_FILE)

	@echo "Installing/Upgrading prometheus-blackbox-exporter..."
	helm upgrade --install prometheus-blackbox-exporter prometheus-community/prometheus-blackbox-exporter \
	  --namespace monitoring \
	  --wait

	@echo "Starting background port-forwards (silent, daemonized)..."
	# Clean previous
	-@start-stop-daemon --stop --pidfile /tmp/pf-frontend.pid >/dev/null 2>&1 || true
	-@start-stop-daemon --stop --pidfile /tmp/pf-grafana.pid  >/dev/null 2>&1 || true
	@rm -f /tmp/pf-frontend.pid /tmp/pf-grafana.pid

	# Prefer start-stop-daemon if available
	@if command -v start-stop-daemon >/dev/null 2>&1; then \
	  start-stop-daemon --start --background --make-pidfile \
	    --pidfile /tmp/pf-frontend.pid \
	    --exec /usr/bin/bash -- -c 'while true; do \
	      kubectl -n app port-forward svc/python-guestbook-frontend 8080:80 --address 127.0.0.1 >/dev/null 2>&1; \
	      sleep 2; \
	    done' >/dev/null 2>&1; \
	  start-stop-daemon --start --background --make-pidfile \
	    --pidfile /tmp/pf-grafana.pid \
	    --exec /usr/bin/bash -- -c 'while true; do \
	      kubectl -n monitoring port-forward svc/$(RELEASE_NAME)-grafana 3000:80 --address 127.0.0.1 >/dev/null 2>&1; \
	      sleep 2; \
	    done' >/dev/null 2>&1; \
	else \
	  ( nohup setsid bash -c 'while true; do \
	      kubectl -n app port-forward svc/python-guestbook-frontend 8080:80 --address 127.0.0.1 >/dev/null 2>&1 < /dev/null || true; \
	      sleep 2; \
	    done' >/dev/null 2>&1 < /dev/null & echo $$! > /tmp/pf-frontend.pid ) >/dev/null 2>&1; \
	  ( nohup setsid bash -c 'while true; do \
	      kubectl -n monitoring port-forward svc/$(RELEASE_NAME)-grafana 3000:80 --address 127.0.0.1 >/dev/null 2>&1 < /dev/null || true; \
	      sleep 2; \
	    done' >/dev/null 2>&1 < /dev/null & echo $$! > /tmp/pf-grafana.pid ) >/dev/null 2>&1; \
	fi

	@echo "apply complete."
	@echo "Frontend:  http://localhost:8080"
	@echo "Grafana :  http://localhost:3000"

# ------------------------------------------------------------
# admin helpers
# ------------------------------------------------------------
.PHONY: grafana-show-admin
grafana-show-admin:
	@echo "Grafana admin user:"; \
	kubectl -n monitoring get secret grafana-admin-credentials -o jsonpath='{.data.admin-user}' | base64 --decode; echo
	@echo "Grafana admin password:"; \
	kubectl -n monitoring get secret grafana-admin-credentials -o jsonpath='{.data.admin-password}' | base64 --decode; echo

.PHONY: grafana-rotate-admin
grafana-rotate-admin:
	@echo "Updating grafana-admin-credentials secret..."
	GRAF_USER="$${GRAFANA_ADMIN_USER:-admin}"; \
	GRAF_PASS="$${GRAFANA_ADMIN_PASSWORD:-}"; \
	if [[ -z "$${GRAF_PASS:-}" ]]; then \
	  if command -v openssl >/dev/null 2>&1; then \
	    GRAF_PASS="$$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | cut -c1-24)"; \
	  else \
	    GRAF_PASS="$$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-24)"; \
	  fi; \
	fi; \
	kubectl -n monitoring create secret generic grafana-admin-credentials \
	  --from-literal=admin-user="$$GRAF_USER" \
	  --from-literal=admin-password="$$GRAF_PASS" \
	  --dry-run=client -o yaml | kubectl apply -f -; \
	echo "Restarting Grafana deployment..."; \
	kubectl -n monitoring rollout restart deploy/$(RELEASE_NAME)-grafana; \
	kubectl -n monitoring rollout status deploy/$(RELEASE_NAME)-grafana

.PHONY: stop-forward
stop-forward:
	-@start-stop-daemon --stop --pidfile /tmp/pf-frontend.pid >/dev/null 2>&1 || true
	-@start-stop-daemon --stop --pidfile /tmp/pf-grafana.pid  >/dev/null 2>&1 || true
	-@xargs -r kill < /tmp/pf-frontend.pid >/dev/null 2>&1 || true
	-@xargs -r kill < /tmp/pf-grafana.pid  >/dev/null 2>&1 || true
	@rm -f /tmp/pf-frontend.pid /tmp/pf-grafana.pid >/dev/null 2>&1 || true


# ------------------------------------------------------------
# make all (init + validate + build (minikube by default / kind with --kind) + prompt + apply)
# ------------------------------------------------------------
.PHONY: all
all: init validate
	@$(MAKE) $(BUILD_STEP)
	@if [ "$(PROMPT)" = "false" ]; then \
	  $(MAKE) apply; \
	else \
	  read -p "Proceed to apply? [y/N]: " ans; \
	  if [[ "$$ans" =~ ^([yY]|[yY][eE][sS])$$ ]]; then \
	    $(MAKE) apply; \
	  else \
	    echo "Aborted."; \
	  fi; \
	fi

# (No flag targets; use PROMPT=false and/or KIND=true instead)
