#Requires -Version 7.0
<#
  spike/s1/probe-accel.ps1 — the accelerator probe from docs/vm.md §2.

  It launches a diskless QEMU for a few seconds and records whether the accelerator
  initialized. No guest image is needed: an accelerator that cannot create and run
  vCPUs fails during initialization, before firmware, and the process exits non-zero.

  The three combinations are the ones S1 exists to distinguish:
    whpx-recorded   -machine q35 -accel whpx,kernel-irqchip=off   (the recorded combination)
    whpx-plain      -machine q35 -accel whpx                      (known MSI-injection failures)
    tcg-control     -machine q35 -accel tcg                       (works everywhere; control)

  Output: results/accel-<utc>.json plus a human-readable summary on stdout.
#>
[CmdletBinding()]
param(
    [string]$Qemu,
    [int]$HoldSeconds = 5
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $Qemu) {
    $Qemu = Join-Path $root '.tools\qemu\qemu-system-x86_64.exe'
}
if (-not (Test-Path -LiteralPath $Qemu)) {
    Write-Host "probe-accel: FAIL — QEMU not found at $Qemu" -ForegroundColor Red
    exit 2
}

$resultsDir = Join-Path $PSScriptRoot 'results'
New-Item -ItemType Directory -Force -Path $resultsDir | Out-Null
$utc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH-mm-ssZ')

$hostFacts = [ordered]@{
    computer        = $env:COMPUTERNAME
    os_build        = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).BuildNumber
    hypervisor_present = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).HypervisorPresent
    winhvplatform_dll  = Test-Path 'C:\Windows\System32\WinHvPlatform.dll'
    qemu_exe        = (Resolve-Path $Qemu).Path
    qemu_version    = (& $Qemu --version 2>&1 | Select-Object -First 1)
    qemu_sha256     = (Get-FileHash -Algorithm SHA256 -LiteralPath $Qemu).Hash.ToLower()
    hold_seconds    = $HoldSeconds
}

$combos = @(
    @{ name = 'whpx-recorded'; args = @('-machine', 'q35', '-accel', 'whpx,kernel-irqchip=off') },
    @{ name = 'whpx-plain';    args = @('-machine', 'q35', '-accel', 'whpx') },
    @{ name = 'tcg-control';   args = @('-machine', 'q35', '-accel', 'tcg') }
)

$probes = @()
foreach ($combo in $combos) {
    $stderr = Join-Path $resultsDir "probe-$($combo.name)-$utc.stderr.log"
    $stdout = Join-Path $resultsDir "probe-$($combo.name)-$utc.stdout.log"
    $argv = $combo.args + @('-nodefaults', '-display', 'none', '-serial', 'none')

    $psi = Start-Process -FilePath $Qemu -ArgumentList $argv -PassThru -NoNewWindow `
        -RedirectStandardError $stderr -RedirectStandardOutput $stdout
    Start-Sleep -Seconds $HoldSeconds
    $alive = -not $psi.HasExited
    if ($alive) {
        $psi.Kill()
        $psi.WaitForExit()
    } else {
        $psi.WaitForExit()
    }

    $errText = if (Test-Path -LiteralPath $stderr) { (Get-Content -LiteralPath $stderr -Raw) } else { '' }
    $state = if ($alive) { 'initialized' }
             elseif ($errText -match 'WHPX|whpx' -and $errText -match 'missing|not|fail|unavailable|disabled') { 'whpx-present-but-failing' }
             else { 'failed' }

    $probes += [ordered]@{
        name            = $combo.name
        argv            = ($argv -join ' ')
        held_seconds    = $HoldSeconds
        still_running   = $alive
        exit_code       = if ($alive) { $null } else { $psi.ExitCode }
        state           = $state
        stderr_head     = ($errText -split "`r?`n" | Where-Object { $_ -ne '' } | Select-Object -First 5)
        stderr_file     = (Split-Path -Leaf $stderr)
    }

    $color = if ($state -eq 'initialized') { 'Green' } else { 'Yellow' }
    Write-Host ("  {0,-14} {1}" -f $combo.name, $state) -ForegroundColor $color
}

$record = [ordered]@{
    timestamp_utc = $utc
    host          = $hostFacts
    probes        = $probes
}
$json = Join-Path $resultsDir "accel-$utc.json"
$record | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $json -Encoding utf8NoBOM

$whpx = $probes | Where-Object { $_.name -eq 'whpx-recorded' }
$whpxPlain = $probes | Where-Object { $_.name -eq 'whpx-plain' }
$tcg = $probes | Where-Object { $_.name -eq 'tcg-control' }

Write-Host ""
Write-Host "probe-accel summary" -ForegroundColor Cyan
Write-Host "  host hypervisor present : $($hostFacts.hypervisor_present)"
Write-Host "  qemu                    : $($hostFacts.qemu_version)"
Write-Host "  whpx-recorded           : $($whpx.state)"
Write-Host "  whpx-plain              : $($whpxPlain.state)"
Write-Host "  tcg-control             : $($tcg.state)"
Write-Host "  evidence                : $json"

# The three states from docs/vm.md §2, as far as a diskless probe can tell them.
if ($whpx.state -eq 'initialized') {
    Write-Host "  accelerator verdict     : whpx" -ForegroundColor Green
    exit 0
} elseif ($whpxPlain.state -eq 'initialized') {
    Write-Host "  accelerator verdict     : whpx-present (plain works, recorded combination does not)" -ForegroundColor Yellow
    exit 1
} else {
    Write-Host "  accelerator verdict     : whpx-missing-or-broken (see stderr logs)" -ForegroundColor Red
    exit 3
}
