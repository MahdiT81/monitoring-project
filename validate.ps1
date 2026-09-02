# Validates Prometheus & Alertmanager configs using promtool / amtool
# before they ever reach the running containers.

Write-Host "== Checking prometheus.yml ==" -ForegroundColor Cyan
docker run --rm --entrypoint promtool -v "${PWD}/prometheus:/etc/prometheus:ro" `
  prom/prometheus:v2.53.0 check config /etc/prometheus/prometheus.yml

Write-Host "`n== Checking alert rules ==" -ForegroundColor Cyan
docker run --rm --entrypoint promtool -v "${PWD}/prometheus:/cfg:ro" `
  prom/prometheus:v2.53.0 check rules /cfg/alerts.yml

Write-Host "`n== Checking alertmanager.yml ==" -ForegroundColor Cyan
docker run --rm --entrypoint amtool -v "${PWD}/alertmanager:/cfg:ro" `
  prom/alertmanager:v0.27.0 check-config /cfg/alertmanager.yml
