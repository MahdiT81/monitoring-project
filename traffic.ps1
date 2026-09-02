# Simulates realistic user traffic against the app so the dashboards have data.
# Runs until you press Ctrl+C.
param(
    [int]$IntervalMs = 200   # delay between request rounds
)

$base = "http://localhost:5000"
Write-Host "Generating traffic to $base — press Ctrl+C to stop." -ForegroundColor Cyan

while ($true) {
    try { Invoke-WebRequest "$base/" -UseBasicParsing | Out-Null } catch {}
    try { Invoke-WebRequest "$base/api/users" -UseBasicParsing | Out-Null } catch {}

    # orders intentionally fails ~10% of the time -> error metrics + alerts
    try { Invoke-WebRequest "$base/api/orders" -UseBasicParsing | Out-Null } catch {}
    try { Invoke-WebRequest "$base/api/slow" -UseBasicParsing -TimeoutSec 5 | Out-Null } catch {}

    Start-Sleep -Milliseconds $IntervalMs
}
