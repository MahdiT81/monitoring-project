# Web Application Monitoring with Prometheus & Grafana

English | [فارسی](README.fa.md)

A hands-on DevOps project demonstrating end-to-end monitoring of a web application using **Docker**, **Prometheus**, and **Grafana**.

The monitored application is a deliberately simple Flask API whose only purpose is to *generate realistic traffic data* (varying latencies, occasional errors). The real focus of this project is the monitoring stack.

## Architecture

```
                    ┌───────────────────────────────────────────────────┐
                    │                  Docker network                   │
                    │                                                   │
   :5000           │  ┌────────┐  scrape  ┌────────────┐  alerts      │
  Browser ─────────┼─►│ WebApp │◄─────────│ Prometheus │──────────┐   │
                    │  │ (Flask)│  /metrics│    :9090   │          ▼   │
                    │  └────┬───┘          └─▲───▲──▲───┘  ┌────────────┐│
                    │       │ logs           │   │  │      │Alertmanager││
                    │  ┌────▼───┐     probes  │   │  │      └────────────┘
                    │  │ Promtail│            │   │  │                   │
                    │  └────┬───┘   ┌─────────┴┐  │  └► node-exporter   │
                    │  ┌────▼───┐   │ Blackbox │  │     cadvisor        │
                    │  │  Loki  │   └──────────┘  │                     │
                    │  └────┬───┘                 │ queries             │
                    │       │               ┌─────┴──────┐              │
   :3000           │       └──────────────►│   Grafana  │              │
  Browser ─────────┼───────────────────────│    :3000   │              │
                    │                       └────────────┘              │
                    └───────────────────────────────────────────────────┘
```

| Service | Purpose | Port |
|---|---|---|
| `webapp` | Flask API exposing custom `/metrics` (counters, histograms, gauges); its endpoints generate realistic traffic | 5000 |
| `prometheus` | Scrapes & stores metrics, evaluates alert rules | 9090 |
| `alertmanager` | Groups, deduplicates & delivers fired alerts (webhook/email ready) | 9093 |
| `grafana` | Dashboards: metrics + live logs (auto-provisioned) | 3000 |
| `loki` + `promtail` | Log aggregation — promtail tails all containers via the Docker socket and ships to Loki | 13100 (host) → 3100 |
| `node-exporter` | Host-level metrics (CPU, RAM, disk) | 9100 |
| `cadvisor` | Per-container resource usage metrics | 8080 |
| `blackbox-exporter` | Synthetic HTTP uptime probes (`/health` endpoints) | 9115 |

## Metrics exposed by the web app

| Metric | Type | Meaning |
|---|---|---|
| `app_http_requests_total{method, endpoint, status}` | Counter | Total requests per endpoint/status code |
| `app_http_request_duration_seconds_bucket{endpoint}` | Histogram | Request latency distribution (enables p50/p95/p99) |
| `app_http_requests_in_progress{endpoint}` | Gauge | Requests currently being served |
| `app_info{version}` | Gauge | Build metadata |

## Endpoints for generating traffic

- `GET /` — fast endpoint (~10–80 ms)
- `GET /api/users` — medium latency
- `GET /api/orders` — **~10% of requests fail with HTTP 500** (drives error-rate alerts)
- `GET /api/slow` — takes 1–3 s (drives latency alerts)
- `GET /health` — health check

## Quick start

```bash
docker compose up --build -d
```

Then open:

- **Web app:** http://localhost:5000
- **Prometheus:** http://localhost:9090 (Status → Targets to confirm scraping)
- **Alertmanager:** http://localhost:9093 (fired alerts & silences)
- **Grafana:** http://localhost:3000 — log in with `admin` / `admin`

The dashboard **"Web App Monitoring"** (12 panels: metrics, live logs, uptime probes) is provisioned automatically — no manual import.

## Helper scripts

```powershell
.\validate.ps1                     # validate Prometheus + Alertmanager configs with promtool/amtool before deploying
.\traffic.ps1                      # generate realistic load against the app until Ctrl+C
.\demo.ps1                         # live failure demo: stop webapp -> WebAppDown fires -> recover -> alert resolves
```

### Live failure demo (demo.ps1)

With the stack running, `.\demo.ps1` performs a complete, reproducible outage cycle and
measures every step — the numbers make a great evaluation chapter for a thesis:

1. **Preflight** — verifies Docker, all containers, and Prometheus scraping
2. **Baseline** — generates traffic and confirms no alerts are firing
3. **Outage** — `docker compose stop webapp` → watches `up{job="webapp"}` drop to 0
4. **Firing** — waits for `WebAppDown` to fire (5s evaluation interval + 30s `for:` clause) and confirms Alertmanager received it
5. **Recovery** — `docker compose start webapp` → watches the scrape come back and the alert auto-resolve

Use `-Unattended` to skip the pauses between phases (handy for screen recordings), and
`-TimeoutSeconds` to widen the windows on a slow machine. The script is safe to Ctrl+C:
if it exits while the app is down, it tells you the one command to restore it.

## Generate traffic

In a second terminal:

```bash
while ($true) {
  Invoke-RestMethod http://localhost:5000/ | Out-Null
  Invoke-RestMethod http://localhost:5000/api/users | Out-Null
  try { Invoke-RestMethod http://localhost:5000/api/orders | Out-Null } catch {}
  try { Invoke-RestMethod http://localhost:5000/api/slow | Out-Null } catch {}
  Start-Sleep -Milliseconds 200
}
```

Within a minute you'll see request rates, latency percentiles, and error rates fill the dashboard.

## Alerts (prometheus/alerts.yml)

Evaluated by Prometheus every 5 seconds; routed through Alertmanager (http://localhost:9093):

| Alert | Trigger | Severity |
|---|---|---|
| `WebAppDown` | Scrape target unreachable for 30 s | critical |
| `HealthProbeFailing` | Blackbox probe can't get HTTP 200 for 1 min | critical |
| `HighErrorRate` | >5% of requests return 5xx over 2 min | warning |
| `HighLatencyP95` | p95 latency >1 s for 2 min | warning |
| `ContainerUsingTooMuchCpu` | Any container >80% CPU for 5 min | warning |

`alertmanager/alertmanager.yml` contains a routing tree with grouping, a repeat interval and an inhibit rule (`WebAppDown` silences the noisy warnings). Uncomment the webhook or email receiver to get real notifications.

To trigger alerts manually: stop the app (`docker compose stop webapp`) or hammer `/api/slow`.

## Key concepts demonstrated

- **Instrumentation vs. exposition:** the app instruments its own code and exposes metrics via `/metrics`
- **Pull model:** Prometheus scrapes targets on an interval rather than receiving pushes
- **Metric types:** counters (monotonic), histograms (latency distributions → percentiles), gauges (point-in-time values)
- **PromQL:** `rate()`, `histogram_quantile()`, aggregation with `sum by (...)`
- **Alerting pipeline:** rules → Alertmanager → routing/grouping/inhibition → notification channels
- **Log aggregation:** Promtail service discovery via Docker API → Loki → Grafana logs panel (metrics + logs in one place)
- **Blackbox / synthetic monitoring:** probing endpoints from "the user's perspective" with relabeling tricks
- **Multi-layer metrics:** application (webapp), container (cAdvisor), host (node-exporter)
- **Infrastructure as configuration:** Grafana datasources/dashboards provisioned from files, everything reproducible via docker-compose
- **Golden signals:** traffic, errors, latency (+ saturation via node/cAdvisor)
- **Config validation as a habit:** `validate.ps1` runs promtool/amtool checks before deploy

## Project layout

```
├── app/
│   ├── app.py               # Flask app with instrumentation
│   ├── requirements.txt
│   └── Dockerfile
├── prometheus/
│   ├── prometheus.yml       # scrape config + alerting + rule files
│   └── alerts.yml           # alerting rules
├── alertmanager/
│   └── alertmanager.yml     # routing, grouping, receivers
├── blackbox/
│   └── blackbox.yml         # http_2xx probe module
├── loki/
│   ├── loki-config.yml      # Loki storage & schema
│   └── promtail-config.yml  # docker_sd log scraping
├── grafana/
│   ├── provisioning/
│   │   ├── datasources/prometheus.yml   # Prometheus + Loki datasources
│   │   └── dashboards/dashboards.yml
│   └── dashboards/webapp-dashboard.json
├── traffic.ps1              # load generator
├── validate.ps1             # promtool/amtool config validation
└── docker-compose.yml       # 9 services on one network
```

## Cleanup

```bash
docker compose down -v
```
