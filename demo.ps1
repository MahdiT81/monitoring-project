<#
.SYNOPSIS
    Live failure & recovery demonstration for the monitoring stack.

.DESCRIPTION
    Drives a complete outage cycle against the running Docker Compose stack:

      PHASE 0  Preflight    - Docker, containers, Prometheus scraping
      PHASE 1  Baseline     - traffic + confirm no alerts are firing
      PHASE 2  Outage       - stop webapp -> up=0 -> WebAppDown FIRES
      PHASE 3  Alertmanager - show the alert on :9093 (inhibition explained)
      PHASE 4  Recovery     - start webapp -> alert auto-resolves
      PHASE 5  Summary      - measured detection / firing / recovery times

.PARAMETER Unattended
    Skip the "Press Enter" pauses between phases (for recording runs).

.PARAMETER TimeoutSeconds
    How long to wait for each state transition before giving up.

.EXAMPLE
    .\demo.ps1
    .\demo.ps1 -Unattended -TimeoutSeconds 180

.NOTES
    Safe to interrupt (Ctrl+C): if the webapp is left stopped, the script
    reminds you how to bring it back (docker compose start webapp).
#>
param(
    [switch]$Unattended,
    [int]$TimeoutSeconds = 150
)

# NOTE: keep ErrorActionPreference at Continue. "Stop" turns harmless native
# stderr lines (e.g. docker's "Container webapp  Stopping") into terminating
# errors on Windows PowerShell 5.1. Every native call below checks its exit
# code explicitly instead.
$ErrorActionPreference = "Continue"
$root    = $PSScriptRoot
$promUrl = "http://localhost:9090"
$amUrl   = "http://localhost:9093"
$appUrl  = "http://localhost:5000"

# ---------------- output helpers ----------------

function Step([string]$Title) {
    Write-Host ""
    Write-Host ("=" * 64) -ForegroundColor DarkCyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host ("=" * 64) -ForegroundColor DarkCyan
    if (-not $Unattended) {
        Read-Host "  Press Enter to continue" | Out-Null
    }
}

function Info([string]$Msg) { Write-Host "  $Msg" -ForegroundColor DarkGray }
function Ok([string]$Msg)   { Write-Host "  [OK] $Msg" -ForegroundColor Green }
function Warn([string]$Msg) { Write-Host "  [!!] $Msg" -ForegroundColor Yellow }
function Fail([string]$Msg) { Write-Host "  [XX] $Msg" -ForegroundColor Red }

# ---------------- query helpers ----------------

function Invoke-PromQuery([string]$Query) {
    # Returns the Prometheus instant-query result vector, or $null if the API is unreachable.
    $url = "$promUrl/api/v1/query?query=" + [uri]::EscapeDataString($Query)
    try {
        $resp = Invoke-RestMethod -Uri $url -TimeoutSec 10
        return $resp.data.result
    } catch {
        return $null
    }
}

function Get-WebappUp {
    # 1 = scraped OK, 0 = failing, $null = no series / Prometheus unreachable
    $r = Invoke-PromQuery 'up{job="webapp"}'
    if ($r -and @($r).Count -gt 0) { return [double]@($r)[0].value[1] }
    return $null
}

function Get-FiringAlertNames {
    $r = Invoke-PromQuery 'ALERTS{alertstate="firing"}'
    if ($null -eq $r) { return @() }
    return @($r | ForEach-Object { $_.metric.alertname })
}

function Get-AmAlerts {
    try { return @(Invoke-RestMethod -Uri "$amUrl/api/v2/alerts" -TimeoutSec 10) }
    catch { return @() }
}

function Wait-Until {
    param(
        [scriptblock]$Condition,
        [string]$What,
        [int]$TimeoutSec = $TimeoutSeconds
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (& $Condition) { Write-Host ""; return $true }
        Write-Host "." -NoNewline -ForegroundColor DarkGray
        Start-Sleep -Seconds 5
    }
    Write-Host ""
    Fail "Timed out after ${TimeoutSec}s waiting for: $What"
    return $false
}

function Invoke-Compose([string]$ComposeArgs) {
    # Run via cmd so docker's stderr never becomes a PowerShell error record.
    Push-Location $root
    try {
        cmd /c "docker compose $ComposeArgs >nul 2>&1"
        return ($LASTEXITCODE -eq 0)
    } finally {
        Pop-Location
    }
}

# ---------------- script ----------------

Clear-Host
Write-Host ""
Write-Host "  Monitoring Stack - Live Failure & Recovery Demo" -ForegroundColor White
Write-Host "  ('stop the app and watch the alerting pipeline do its job')" -ForegroundColor DarkGray

$outageInjected = $false
$measured = @{}

try {
    # ------------------------------------------------ PHASE 0: preflight
    Step "PHASE 0/5 - Preflight checks"

    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Fail "docker CLI not found. Install/start Docker Desktop first."
        exit 1
    }
    cmd /c "docker info >nul 2>&1"
    if ($LASTEXITCODE -ne 0) {
        Fail "Docker engine is not running."
        exit 1
    }
    Ok "Docker engine is up."

    $running = @(cmd /c 'docker ps --format "{{.Names}}"')
    $required = @("webapp", "prometheus", "alertmanager", "grafana", "loki", "blackbox")
    $missing = $required | Where-Object { $running -notcontains $_ }
    if ($missing) {
        Fail "Stack incomplete. Not running: $($missing -join ', ')"
        Info  "Start everything with:  docker compose up -d"
        exit 1
    }
    Ok "All core containers are running."

    $up = Get-WebappUp
    if ($null -eq $up) {
        Fail "Prometheus API not reachable on :9090."
        Info  "Is the prometheus container healthy? Try:  docker compose restart prometheus"
        exit 1
    }
    if ($up -ne 1) {
        Fail "Prometheus is NOT successfully scraping the webapp (up = $up)."
        exit 1
    }
    Ok "Prometheus is scraping the webapp (up = 1)."

    # ------------------------------------------------ PHASE 1: baseline
    Step "PHASE 1/5 - Baseline: healthy traffic"

    Info "Generating a short burst of requests so there is fresh data..."
    1..15 | ForEach-Object {
        try { Invoke-WebRequest "$appUrl/" -UseBasicParsing -TimeoutSec 5 | Out-Null } catch {}
        try { Invoke-WebRequest "$appUrl/api/users" -UseBasicParsing -TimeoutSec 5 | Out-Null } catch {}
        Start-Sleep -Milliseconds 300
    }

    $total = Invoke-PromQuery 'sum(app_http_requests_total)'
    $up = Get-WebappUp
    $firing = Get-FiringAlertNames
    Ok "webapp scrape up = $up"
    if ($total) { Info "Total requests counted so far: $(@($total)[0].value[1])" }
    if ($firing.Count -eq 0) { Ok "No alerts firing (as expected in a healthy state)." }
    else { Warn "Already firing before the outage: $($firing -join ', ')" }

    # ------------------------------------------------ PHASE 2: outage
    Step "PHASE 2/5 - Inject outage:  docker compose stop webapp"

    Info "What to expect:"
    Info "  - within ~10s : Prometheus scrape starts failing (up = 0)"
    Info "  - after +30s  : WebAppDown leaves 'pending' and FIRES (rule: for: 30s)"
    Info ""

    $outageStart = Get-Date
    $outageInjected = $true   # set optimistically; any crash after this point must warn the user
    if (-not (Invoke-Compose "stop webapp")) {
        Fail "'docker compose stop webapp' failed."
        exit 1
    }
    Warn "webapp container STOPPED at $($outageStart.ToString('HH:mm:ss'))"

    $done = Wait-Until -What "up{job=`"webapp`"} == 0" -Condition { (Get-WebappUp) -eq 0 }
    if (-not $done) { exit 1 }
    $detectedAt = Get-Date
    $measured.detect = ($detectedAt - $outageStart).TotalSeconds
    Ok ("Prometheus noticed the outage in {0:n0} seconds (up = 0)" -f $measured.detect)

    $done = Wait-Until -What "WebAppDown alert to fire" -Condition { (Get-FiringAlertNames) -contains "WebAppDown" }
    if (-not $done) { exit 1 }
    $firedAt = Get-Date
    $measured.fire = ($firedAt - $outageStart).TotalSeconds
    Ok ("WebAppDown FIRED {0:n0} seconds after the outage began" -f $measured.fire)

    # ------------------------------------------------ PHASE 3: alertmanager
    Step "PHASE 3/5 - Alertmanager receives the alert"

    $am = Get-AmAlerts
    if ($am.Count -eq 0) {
        Warn "Nothing visible in Alertmanager yet (group_wait is 30s - give it a moment)."
    } else {
        Ok "Alertmanager is currently holding $($am.Count) alert(s):"
        $am | ForEach-Object {
            Info ("    - {0}  [{1}]  since {2}" -f $_.labels.alertname, $_.status.state, $_.startsAt)
        }
    }
    Info ""
    Info "Expected here:"
    Info "  - WebAppDown (critical) is active; shortly after, HealthProbeFailing"
    Info "    (blackbox synthetic check) fires for the same root cause."
    Info "  - Any *warning* alerts would be silenced by the inhibit rule in"
    Info "    alertmanager/alertmanager.yml (WebAppDown suppresses warnings)."
    Info "  - See it live at http://localhost:9093"

    # ------------------------------------------------ PHASE 4: recovery
    Step "PHASE 4/5 - Recover:  docker compose start webapp"

    $recoverStart = Get-Date
    if (-not (Invoke-Compose "start webapp")) {
        Fail "'docker compose start webapp' failed."
        Warn "Bring the app back manually:  docker compose start webapp"
        exit 1
    }
    $outageInjected = $false
    Warn "webapp container STARTED at $($recoverStart.ToString('HH:mm:ss'))"

    $done = Wait-Until -What "up{job=`"webapp`"} == 1" -Condition { (Get-WebappUp) -eq 1 }
    if (-not $done) { exit 1 }
    $measured.recover = ((Get-Date) - $recoverStart).TotalSeconds
    Ok ("Scrape recovered in {0:n0} seconds" -f $measured.recover)

    $done = Wait-Until -What "WebAppDown alert to resolve" -Condition { (Get-FiringAlertNames) -notcontains "WebAppDown" }
    if (-not $done) { exit 1 }
    $measured.resolve = ((Get-Date) - $recoverStart).TotalSeconds
    Ok ("WebAppDown RESOLVED {0:n0} seconds after recovery started" -f $measured.resolve)

    # ------------------------------------------------ PHASE 5: summary
    Step "PHASE 5/5 - Summary (numbers for the thesis evaluation chapter)"

    Info ("Outage -> detected (up=0)        : {0,5:n0} s" -f $measured.detect)
    Info ("Outage -> WebAppDown firing      : {0,5:n0} s   (5s eval interval + 30s 'for')" -f $measured.fire)
    Info ("Recovery -> scrape healthy       : {0,5:n0} s" -f $measured.recover)
    Info ("Recovery -> alert resolved       : {0,5:n0} s" -f $measured.resolve)
    Write-Host ""
    Ok "Full outage cycle demonstrated: healthy -> down -> ALERT -> recovered -> resolved."
    Info ""
    Info "Also worth showing live:"
    Info "  - Grafana :3000  - the 'App Scrape Health' panel dipped to 0 during the outage"
    Info "  - Alertmanager   - the resolved alert lingers as 'resolved' for a while"
    Info "  - Other alerts   - run .\traffic.ps1 and hammer /api/slow (latency) or"
    Info "                     /api/orders (error rate) to fire the warning alerts"
}
finally {
    # Leave the environment in a sane state if something went wrong mid-outage.
    if ($outageInjected) {
        Write-Host ""
        Warn "Script ended while the webapp is still DOWN."
        Info  "Bring it back with:  docker compose start webapp"
    }
}
