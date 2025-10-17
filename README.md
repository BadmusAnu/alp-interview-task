# ALP Interview Task — Guestbook + Monitoring

This project deploys a simple Python guestbook app (frontend + backend) and a monitoring stack (kube-prometheus-stack) with:

- Prometheus, Alertmanager, Grafana
- Uptime monitoring using the Prometheus Blackbox Exporter (HTTP probe)
- A 30s downtime alert routed to Slack (via Incoming Webhook)


## Requirements

- A Kubernetes cluster and context configured (`kubectl config current-context` not empty)
  - Minikube or kind work well for local testing
- Docker (build images locally)
- Helm 3
- GNU Make
- Bash environment (Linux/macOS or Windows via WSL2)
- curl (for optional tests)


## Repo Layout

- `deployment/app-kubernetes-manifests/` — K8s YAML for the guestbook app
- `deployment/kube-promethues-stack-helm/values.yaml` — Helm values for kube-prometheus-stack
- `makefile` — Build/deploy helpers for app + monitoring


## First-Time Setup

1) Set your Slack Incoming Webhook

Alertmanager is configured to use a Slack Incoming Webhook directly. Edit the file below and replace the placeholder with your webhook URL:

- `alp-interview-task/deployment/kube-promethues-stack-helm/values.yaml`: find the Slack receiver and set `api_url` to your real URL.

Example:

receivers:
  - name: "slack"
    slack_configs:
      - api_url: https://hooks.slack.com/services/REPLACE/ME/WITH_REAL_WEBHOOK
        send_resolved: true

2) Initialize tooling and namespaces

Run once to verify cluster access, ensure Helm, add repos, and create namespaces:

- `make init`


## Build and Deploy

You can use Minikube (default) or kind. The Makefile supports a streamlined flow:

- Minikube (default, prompts before apply): `make all`
- Non-interactive: `make all PROMPT=false`
- Use kind: `make all KIND=true`
- Use kind non-interactive: `make all PROMPT=false KIND=true`

What `make all` does:

- `init` → checks cluster/helm, adds repos, creates `app` and `monitoring` namespaces
- `validate` → dry-run Helm and validate app manifests
- Build app images and load into the cluster (Minikube or kind)
- `apply` →
  - Deploys the app manifests to `app` namespace
  - Ensures Grafana admin Secret (idempotent)
  - Installs/Upgrades kube-prometheus-stack (using your `values.yaml`)
  - Installs/Upgrades Blackbox Exporter in `monitoring`
  - Starts background port-forwards:
    - Frontend → `http://localhost:8080`
    - Grafana  → `http://localhost:3000`

Stop port-forwards:

- `make stop-forward`


## Grafana Access

The Makefile creates a Secret `grafana-admin-credentials` if it does not exist.

- Show credentials: `make grafana-show-admin`
- Rotate credentials and restart Grafana:
  - Example: `GRAFANA_ADMIN_PASSWORD='StrongPass123!' make grafana-rotate-admin`

Grafana URL: `http://localhost:3000`


## Alerting and Uptime

Uptime is measured with a Prometheus Blackbox HTTP probe configured in `values.yaml` to check the in-cluster service:

- Target: `http://python-guestbook-frontend.app.svc.cluster.local`
- Probe job name: `blackbox-http`
- Alert: `HttpFrontendDown30s` triggers when `probe_success == 0` for 30 seconds

Alert delivery is routed to Slack via your Incoming Webhook configured in `values.yaml`.


## Test Slack Delivery (no waiting)

Send a synthetic alert to Alertmanager (v2 API) and verify a message appears in Slack:

1) Port-forward Alertmanager:

- `kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093`

2) Post a test alert (bash):

- `curl -X POST -H 'Content-Type: application/json' http://localhost:9093/api/v2/alerts -d '[{"labels":{"alertname":"TestSlack","severity":"critical"},"annotations":{"summary":"Test from AM v2 -> Slack"},"startsAt":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}]'`

If nothing shows up:

- Confirm your webhook URL is correct in `values.yaml`
- Check Alertmanager logs: `kubectl -n monitoring logs deploy/kube-prometheus-stack-alertmanager`


## Troubleshooting

- Helm template error referencing `alertmanagerSpec.portName`
  - Fixed in `values.yaml` by setting `alertmanager.alertmanagerSpec.portName: "http-web"`

- No Slack notifications
  - Ensure `values.yaml` has your real Slack Incoming Webhook in `slack_configs.api_url`
  - Try the synthetic v2 alert above

- Uptime alert didn’t fire when deleting the frontend for exactly 30s
  - The probe interval is 30s; allow ≥60–90s of downtime to be safe or reduce scrape interval

- Blackbox exporter status
  - Installed by `make apply` as `prometheus-blackbox-exporter` in `monitoring`
  - Check: `kubectl -n monitoring get pods -l app.kubernetes.io/name=prometheus-blackbox-exporter`


## Notes

- The app does not expose `/metrics`, so no ServiceMonitor is installed for it; uptime uses blackbox HTTP checks instead.
- For a public endpoint check, change the blackbox target in `values.yaml` to your real hostname (Ingress) instead of the ClusterIP URL.
