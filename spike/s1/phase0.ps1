#Requires -Version 7.0
<#
  spike/s1/phase0.ps1 — Phase 0 driver: accelerator probe + probe-guest boot measurement.

  It writes one evidence JSONL for the whole phase, then:
    1. runs probe-accel.ps1 (WHPX combinations, 2 s hold),
    2. if the accelerator is `whpx`, runs probe-boot-guest.ps1 (Alpine 3.24.4 probe guest),
    3. writes `phase0.verdict` and validates the JSONL.

  No elevation is used or requested. The probe guest runs without a network device (`-nic none`).
  Exit: 0 = go, 3 = WHPX/K-1 failure, 4 = boot measurement incomplete, 5 = JSONL invalid.
#>
[CmdletBinding()]
param(
    [string]$JsonlPath,
    [int]$Runs = 3,
    [int]$HoldSeconds = 2,
    [int]$TimeoutSeconds = 180,
    [switch]$SkipBoot
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$resultsDir = Join-Path $PSScriptRoot 'results'
New-Item -ItemType Directory -Force -Path $resultsDir | Out-Null

$utc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH-mm-ssZ')
if (-not $JsonlPath) { $JsonlPath = Join-Path $resultsDir "phase0-$utc.jsonl" }
if (Test-Path -LiteralPath $JsonlPath) {
    throw "phase0: refusing to overwrite existing evidence at $JsonlPath"
}
$runId = [IO.Path]::GetFileNameWithoutExtension($JsonlPath)
$JsonlPath = [IO.Path]::GetFullPath($JsonlPath)

function Write-JsonlEvent {
    param([string]$Path, [System.Collections.IDictionary]$Event)
    $lines = 0
    if (Test-Path -LiteralPath $Path) { $lines = [IO.File]::ReadAllLines($Path).Length }
    $Event['v'] = 1
    $Event['seq'] = $lines + 1
    $Event['ts'] = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    $json = $Event | ConvertTo-Json -Compress -Depth 10
    [IO.File]::AppendAllText($Path, $json + "`n", [Text.UTF8Encoding]::new($false))
}

function Read-JsonlEvents {
    param([string]$Path)
    $events = @()
    if (-not (Test-Path -LiteralPath $Path)) { return $events }
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        if ($line.Trim() -eq '') { continue }
        $events += ($line | ConvertFrom-Json)
    }
    return $events
}

function Get-Median {
    param([double[]]$Values)
    if ($Values.Count -eq 0) { return $null }
    $s = @($Values | Sort-Object)
    if ($s.Count % 2 -eq 1) { return $s[[int][math]::Floor($s.Count / 2)] }
    return [math]::Round((($s[$s.Count / 2 - 1] + $s[$s.Count / 2]) / 2), 3)
}

# ---------------------------------------------------------------- host facts
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
$elevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$wmi = Get-CimInstance Win32_OptionalFeature -Filter "Name='HypervisorPlatform'" -ErrorAction SilentlyContinue
$qemu = Join-Path $root '.tools\qemu\qemu-system-x86_64.exe'
$iso = Join-Path $root '.tools\alpine\alpine-virt-3.24.4-x86_64.iso'
$driveLetter = (Split-Path -Qualifier $root).TrimEnd(':')
$diskFreeGb = [math]::Round((Get-PSDrive -Name $driveLetter).Free / 1GB, 1)

Write-JsonlEvent -Path $JsonlPath -Event ([ordered]@{
    kind = 'phase0.start'
    run_id = $runId
    elevated = $elevated
    host = [ordered]@{
        computer = $env:COMPUTERNAME
        os_build = (Get-CimInstance Win32_OperatingSystem).BuildNumber
        os_caption = (Get-CimInstance Win32_OperatingSystem).Caption
        ps_version = $PSVersionTable.PSVersion.ToString()
        hypervisor_present = (Get-CimInstance Win32_ComputerSystem).HypervisorPresent
        hypervisor_platform_install_state = if ($wmi) { $wmi.InstallState } else { $null }
        winhvplatform_dll = Test-Path 'C:\Windows\System32\WinHvPlatform.dll'
        cpu_cores = (Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfCores -Sum).Sum
        cpu_threads = (Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
        ram_gb = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
        disk_free_gb = $diskFreeGb
    }
    qemu = [ordered]@{
        exe = $qemu
        exists = Test-Path -LiteralPath $qemu
        version = if (Test-Path -LiteralPath $qemu) { (& $qemu --version 2>&1 | Select-Object -First 1) } else { $null }
        sha256 = if (Test-Path -LiteralPath $qemu) { (Get-FileHash -Algorithm SHA256 -LiteralPath $qemu).Hash.ToLower() } else { $null }
    }
    probe_guest = [ordered]@{
        iso = $iso
        url = 'https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/x86_64/alpine-virt-3.24.4-x86_64.iso'
        role = 'probe-guest'
        expected_sha256 = '157d353f8e54252cad2d9812a0d56bb7fa2231fc154a110e1d180d7480ef8b4f'
        expected_bytes = 70254592
    }
})

if ($elevated) {
    Write-JsonlEvent -Path $JsonlPath -Event ([ordered]@{
        kind = 'error'; run_id = $runId; where = 'phase0.start'
        message = 'process is elevated; Phase 0 is defined to run without admin rights'
        remedy = 'run this script from a normal shell'
    })
    throw 'phase0: refusing to run elevated; Phase 0 must not need admin rights'
}

# ---------------------------------------------------------------- accelerator probe
Write-Host 'phase 0: accelerator probe' -ForegroundColor Cyan
$pwshExe = Join-Path $PSHOME 'pwsh.exe'
& $pwshExe -NoProfile -File (Join-Path $PSScriptRoot 'probe-accel.ps1') -JsonlPath $JsonlPath -HoldSeconds $HoldSeconds
$accelExit = $LASTEXITCODE

$events = Read-JsonlEvents -Path $JsonlPath
$accelVerdictEvent = $events | Where-Object { $_.kind -eq 'accel.verdict' } | Select-Object -Last 1
$accelVerdict = if ($accelVerdictEvent) { $accelVerdictEvent.verdict } else { 'unknown' }

if ($accelVerdict -ne 'whpx') {
    Write-JsonlEvent -Path $JsonlPath -Event ([ordered]@{
        kind = 'phase0.verdict'; run_id = $runId; verdict = 'no-go'
        k1 = 'fire'; accelerator = $accelVerdict; accel_exit_code = $accelExit
        boot_samples = @()
        notes = 'WHPX did not initialize. D-016 has no software-emulation fallback; K-1 is the decision point.'
    })
    Write-Host "phase 0: NO-GO — accelerator verdict $accelVerdict (K-1)" -ForegroundColor Red
    exit 3
}

# ---------------------------------------------------------------- probe-guest boot
$bootSamples = @()
$bootMethods = @()
if ($SkipBoot) {
    Write-Host 'phase 0: boot probe skipped (-SkipBoot)' -ForegroundColor Yellow
    $bootExit = 0
} else {
    Write-Host 'phase 0: probe-guest boot measurement (Alpine 3.24.4, probe guest only)' -ForegroundColor Cyan
    & $pwshExe -NoProfile -File (Join-Path $PSScriptRoot 'probe-boot-guest.ps1') `
        -JsonlPath $JsonlPath -Runs $Runs -TimeoutSeconds $TimeoutSeconds
    $bootExit = $LASTEXITCODE
    $events = Read-JsonlEvents -Path $JsonlPath
    $bootEnds = @($events | Where-Object { $_.kind -eq 'boot.end' })
    $bootSamples = @($bootEnds | Where-Object { $_.reached -eq 'login' } | ForEach-Object { [double]$_.boot_time_s })
    $bootMethods = @($events | Where-Object { $_.kind -eq 'boot.start' } | ForEach-Object {
        if ($_.attempts) { $_.attempts[-1].method } else { $null }
    } | Where-Object { $_ })
}

$median = Get-Median -Values ([double[]]$bootSamples)
$go = ($bootSamples.Count -eq $Runs) -and (-not $SkipBoot)

Write-JsonlEvent -Path $JsonlPath -Event ([ordered]@{
    kind = 'phase0.verdict'
    run_id = $runId
    verdict = if ($go) { 'go' } else { 'no-go' }
    k1 = if ($go) { 'accelerator + probe-guest boot pass; NixOS S1 exit still owed' } else { 'incomplete' }
    accelerator = $accelVerdict
    probe_guest = 'alpine-virt-3.24.4 (probe guest, NOT the product image)'
    boot_samples = $bootSamples
    boot_median_s = $median
    boot_methods = $bootMethods
    accel_exit_code = $accelExit
    boot_exit_code = $bootExit
    jsonl = $JsonlPath
    notes = 'Probe-guest numbers are evidence for WHPX boot capability only; they are not the NixOS product-image boot time and are not NFR-2 evidence. No TCG fallback was used (D-016).'
})

# ---------------------------------------------------------------- validity check
$events = Read-JsonlEvents -Path $JsonlPath
$bad = @()
for ($i = 0; $i -lt $events.Count; $i++) {
    $e = $events[$i]
    if ($e.v -ne 1) { $bad += "line $($i + 1): v != 1" }
    if ($e.seq -ne ($i + 1)) { $bad += "line $($i + 1): seq $($e.seq) != $($i + 1)" }
    foreach ($k in @('v', 'seq', 'ts', 'kind', 'run_id')) {
        if ($null -eq $e.$k) { $bad += "line $($i + 1): missing $k" }
    }
}
$bytes = (Get-Item -LiteralPath $JsonlPath).Length
$sha = (Get-FileHash -Algorithm SHA256 -LiteralPath $JsonlPath).Hash.ToLower()

Write-Host ''
Write-Host 'phase 0 summary' -ForegroundColor Cyan
Write-Host "  accelerator            : $accelVerdict"
Write-Host "  probe guest            : alpine-virt-3.24.4 (probe only, not product image)"
Write-Host "  boot samples (s)       : $($bootSamples -join ', ')"
Write-Host "  boot median (s)        : $median"
Write-Host "  jsonl                  : $JsonlPath ($($events.Count) events, $bytes B, sha256 $($sha.Substring(0,16))…)"
Write-Host "  elevated               : $elevated"
if ($bad.Count -gt 0) {
    Write-Host '  JSONL VALIDATION       : FAIL' -ForegroundColor Red
    $bad | ForEach-Object { Write-Host "    $_" }
    exit 5
}
Write-Host '  JSONL validation       : ok'
Write-Host "  verdict                : $(if ($go) { 'GO' } else { 'NO-GO' })" -ForegroundColor $(if ($go) { 'Green' } else { 'Red' })

if ($go) { exit 0 } else { exit 4 }
