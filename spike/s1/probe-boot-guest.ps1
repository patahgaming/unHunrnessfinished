#Requires -Version 7.0
<#
  spike/s1/probe-boot-guest.ps1 — Phase 0 probe-guest boot measurement.

  Boots the Alpine 3.24.4 virt ISO headless under the recorded WHPX combination and measures
  the time from QEMU process start to the first `login:` prompt on the serial console.

  IMPORTANT: Alpine is a **probe guest**, not the product image. These numbers are evidence that
  WHPX can boot a guest on this host; they are NOT the NixOS product-image boot time and must not
  be used as NFR-2 evidence. Results are kept in separate files from any later NixOS run.

  Serial capture uses a loopback TCP chardev (`-serial tcp:...`) because QEMU's `file:` backend
  locks the log file on Windows while the VM runs, which prevents live marker detection. The
  captured bytes are written to a `.serial.log` artifact after QEMU is stopped.

  The x86_64 virt image autodetects a serial console from the initramfs (Alpine aports
  4ad0b08b), so no console=ttyS0 kernel parameter is needed for the prompt to appear.

  Output: a serial log per attempt, `boot.start` / `boot.marker` / `boot.end` JSONL events, and
  a JSON summary on stdout. Exit 0 = every requested run reached the marker; 4 = not.
#>
[CmdletBinding()]
param(
    [string]$Qemu,
    [string]$Iso,
    [int]$Runs = 3,
    [int]$TimeoutSeconds = 180,
    [string]$JsonlPath,
    [string]$SerialDir,
    [switch]$NoDownload
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $Qemu) { $Qemu = Join-Path $root '.tools\qemu\qemu-system-x86_64.exe' }
if (-not $Iso) { $Iso = Join-Path $root '.tools\alpine\alpine-virt-3.24.4-x86_64.iso' }
if (-not $SerialDir) { $SerialDir = Join-Path $PSScriptRoot 'results' }
if (-not $JsonlPath) { throw 'probe-boot-guest: -JsonlPath is required for Phase 0 evidence' }

$IsoUrl    = 'https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/x86_64/alpine-virt-3.24.4-x86_64.iso'
$IsoSha256 = '157d353f8e54252cad2d9812a0d56bb7fa2231fc154a110e1d180d7480ef8b4f'
$IsoBytes  = 70254592
$GuestRole = 'probe-guest'
$Marker    = 'login:'

if (-not (Test-Path -LiteralPath $Qemu)) {
    Write-Host "probe-boot-guest: FAIL — QEMU not found at $Qemu" -ForegroundColor Red
    exit 2
}

New-Item -ItemType Directory -Force -Path $SerialDir | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Iso) | Out-Null
$utc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH-mm-ssZ')
$runId = [IO.Path]::GetFileNameWithoutExtension($JsonlPath)

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

function Get-FreeTcpPort {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = [int]$listener.LocalEndpoint.Port
    $listener.Stop()
    return $port
}

# ---------------------------------------------------------------- ISO fetch and verification
if (-not (Test-Path -LiteralPath $Iso)) {
    if ($NoDownload) { Write-Host "probe-boot-guest: FAIL — ISO missing at $Iso (-NoDownload)" -ForegroundColor Red; exit 2 }
    Write-Host "downloading $IsoUrl"
    Invoke-WebRequest -Uri $IsoUrl -OutFile $Iso -TimeoutSec 600
}
$isoItem = Get-Item -LiteralPath $Iso
$isoHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Iso).Hash.ToLower()
if ($isoItem.Length -ne $IsoBytes -or $isoHash -ne $IsoSha256) {
    Write-Host "probe-boot-guest: FAIL — ISO does not match the published artifact" -ForegroundColor Red
    Write-Host ("  bytes  expected {0} / got {1}" -f $IsoBytes, $isoItem.Length)
    Write-Host ("  sha256 expected {0} / got {1}" -f $IsoSha256, $isoHash)
    exit 2
}
Write-Host ("ISO ok  alpine-virt-3.24.4-x86_64.iso  {0} B  sha256 {1}" -f $isoItem.Length, $isoHash)

# ---------------------------------------------------------------- boot attempts
# Attach variants, most representative first. Attempts only advance when QEMU exits before the VM
# can boot (a bad attach), never to hide a slow boot.
$attempts = @(
    [ordered]@{
        method = 'q35-cdrom'
        args   = @('-machine', 'q35', '-cdrom', $Iso, '-boot', 'd')
    },
    [ordered]@{
        method = 'q35-usb'
        args   = @('-machine', 'q35', '-device', 'qemu-xhci',
                   '-drive', "file=$Iso,format=raw,if=none,id=cd0,media=cdrom",
                   '-device', 'usb-storage,drive=cd0', '-boot', 'order=d')
    },
    [ordered]@{
        method = 'pc-cdrom'
        args   = @('-machine', 'pc', '-cdrom', $Iso, '-boot', 'd')
    }
)

$samples = @()
$usedMethods = @()

for ($run = 1; $run -le $Runs; $run++) {
    $attemptLog = @()
    $result = $null

    foreach ($variant in $attempts) {
        $port = Get-FreeTcpPort
        $serial = Join-Path $SerialDir ("phase0-boot-{0}-r{1}-{2}.serial.log" -f $utc, $run, $variant.method)
        $stderr = Join-Path $SerialDir ("phase0-boot-{0}-r{1}-{2}.stderr.log" -f $utc, $run, $variant.method)
        $stdout = Join-Path $SerialDir ("phase0-boot-{0}-r{1}-{2}.stdout.log" -f $utc, $run, $variant.method)
        $argv = $variant.args + @(
            '-accel', 'whpx,kernel-irqchip=off',
            '-m', '1024', '-smp', '1',
            '-display', 'none', '-vga', 'none', '-nic', 'none', '-monitor', 'none',
            '-no-reboot', '-serial', "tcp:127.0.0.1:$port,server=on,wait=off"
        )

        $startedUtc = (Get-Date).ToUniversalTime().ToString('o')
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $proc = Start-Process -FilePath $Qemu -ArgumentList $argv -PassThru -NoNewWindow `
            -RedirectStandardError $stderr -RedirectStandardOutput $stdout
        $bootTime = $null
        $earlyExit = $false
        $endedUtc = $null
        $captured = ''
        $client = $null
        $stream = $null
        $buffer = New-Object byte[] 8192

        try {
            while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
                if ($null -eq $client) {
                    if ($proc.HasExited) { $earlyExit = $true; break }
                    try {
                        $client = [Net.Sockets.TcpClient]::new()
                        $client.Connect('127.0.0.1', $port)
                        $client.ReceiveTimeout = 100
                        $stream = $client.GetStream()
                    } catch {
                        $client = $null
                        Start-Sleep -Milliseconds 50
                        continue
                    }
                }
                try {
                    while ($stream.DataAvailable) {
                        $n = $stream.Read($buffer, 0, $buffer.Length)
                        if ($n -le 0) { break }
                        $captured += [Text.Encoding]::ASCII.GetString($buffer, 0, $n)
                        if ($captured.Contains($Marker)) {
                            $bootTime = [math]::Round($sw.Elapsed.TotalSeconds, 3)
                            break
                        }
                    }
                } catch { }
                if ($bootTime -ne $null) { break }
                if ($proc.HasExited) { $earlyExit = $true; break }
                Start-Sleep -Milliseconds 50
            }
        } finally {
            if ($bootTime -ne $null) {
                # Let the login prompt settle, then stop the VM.
                Start-Sleep -Milliseconds 1500
            }
            if (-not $proc.HasExited) {
                $proc | Stop-Process -Force
                $proc.WaitForExit()
            }
            if ($stream) {
                try {
                    while ($stream.DataAvailable) {
                        $n = $stream.Read($buffer, 0, $buffer.Length)
                        if ($n -le 0) { break }
                        $captured += [Text.Encoding]::ASCII.GetString($buffer, 0, $n)
                    }
                } catch { }
            }
            if ($client) { $client.Close() }
            $endedUtc = (Get-Date).ToUniversalTime().ToString('o')
        }

        # Serial artifact is written from the captured stream, after QEMU stopped, so no lock.
        [IO.File]::WriteAllText($serial, $captured, [Text.UTF8Encoding]::new($false))
        $serialBytes = (Get-Item -LiteralPath $serial).Length
        $serialHash = if ($serialBytes -gt 0) { (Get-FileHash -Algorithm SHA256 -LiteralPath $serial).Hash.ToLower() } else { $null }
        $errText = if (Test-Path -LiteralPath $stderr) { Get-Content -LiteralPath $stderr -Raw -ErrorAction SilentlyContinue } else { '' }
        $exitStatus = if ($proc.HasExited) { $proc.ExitCode } else { $null }

        if ($bootTime -eq $null) {
            $attemptLog += [ordered]@{
                method       = $variant.method
                argv         = $argv
                early_exit   = $earlyExit
                exit_status  = $exitStatus
                serial_log   = (Split-Path -Leaf $serial)
                serial_bytes = $serialBytes
                stderr_head  = @($errText -split "`r?`n" | Where-Object { $_ -ne '' } | Select-Object -First 4)
            }
            # A bad attach exits within a couple of seconds with (almost) no serial output.
            if ($earlyExit -and $sw.Elapsed.TotalSeconds -lt 10 -and $serialBytes -lt 64) {
                Write-Host ("  run {0}: {1} attach failed, trying next variant" -f $run, $variant.method) -ForegroundColor Yellow
                continue
            }
            Write-JsonlEvent -Path $JsonlPath -Event ([ordered]@{
                kind = 'boot.start'; run_id = $runId; run = $run
                guest = (Split-Path -Leaf $Iso); guest_role = $GuestRole
                guest_sha256 = $isoHash; guest_bytes = $isoItem.Length
                machine = if ($variant.method -like 'pc-*') { 'pc' } else { 'q35' }
                accel = 'whpx,kernel-irqchip=off'
                marker = $Marker
                boot_timeout_s = $TimeoutSeconds
                started_ts = $startedUtc
                attempts = $attemptLog
            })
            Write-JsonlEvent -Path $JsonlPath -Event ([ordered]@{
                kind = 'boot.end'; run_id = $runId; run = $run
                reached = if ($earlyExit) { 'failed' } else { 'timeout' }
                boot_time_s = $null; serial_log = (Split-Path -Leaf $serial)
                serial_bytes = $serialBytes; serial_sha256 = $serialHash
                exit_status = $exitStatus; still_running = $false
                ended_ts = $endedUtc
            })
            $result = [ordered]@{ run = $run; reached = 'failed'; attempt_log = $attemptLog }
            break
        }

        $attemptLog += [ordered]@{
            method       = $variant.method
            argv         = $argv
            early_exit   = $false
            exit_status  = $null
            serial_log   = (Split-Path -Leaf $serial)
            serial_bytes = $serialBytes
            stderr_head  = @()
        }
        Write-JsonlEvent -Path $JsonlPath -Event ([ordered]@{
            kind = 'boot.start'; run_id = $runId; run = $run
            guest = (Split-Path -Leaf $Iso); guest_role = $GuestRole
            guest_sha256 = $isoHash; guest_bytes = $isoItem.Length
            machine = if ($variant.method -like 'pc-*') { 'pc' } else { 'q35' }
            accel = 'whpx,kernel-irqchip=off'
            marker = $Marker
            boot_timeout_s = $TimeoutSeconds
            started_ts = $startedUtc
            attempts = $attemptLog
        })
        Write-JsonlEvent -Path $JsonlPath -Event ([ordered]@{
            kind = 'boot.marker'; run_id = $runId; run = $run
            marker = $Marker; elapsed_ms = [math]::Round($bootTime * 1000)
        })
        Write-JsonlEvent -Path $JsonlPath -Event ([ordered]@{
            kind = 'boot.end'; run_id = $runId; run = $run
            reached = 'login'; boot_time_s = $bootTime
            serial_log = (Split-Path -Leaf $serial)
            serial_bytes = $serialBytes; serial_sha256 = $serialHash
            exit_status = $null; still_running = $false
            ended_ts = $endedUtc
        })
        $samples += [double]$bootTime
        $usedMethods += $variant.method
        $result = [ordered]@{ run = $run; reached = 'login'; boot_time_s = $bootTime; method = $variant.method }
        break
    }

    if ($result -and $result.reached -eq 'login') {
        Write-Host ("  run {0}: booted in {1} s via {2}" -f $run, $result.boot_time_s, $result.method) -ForegroundColor Green
    } else {
        Write-Host ("  run {0}: no login marker (see serial logs)" -f $run) -ForegroundColor Red
        break
    }
}

$sorted = @($samples | Sort-Object)
$median = if ($sorted.Count -eq 0) { $null }
          elseif ($sorted.Count % 2 -eq 1) { $sorted[[int][math]::Floor($sorted.Count / 2)] }
          else { [math]::Round((($sorted[$sorted.Count / 2 - 1] + $sorted[$sorted.Count / 2]) / 2), 3) }
$summary = [ordered]@{
    guest        = (Split-Path -Leaf $Iso)
    guest_role   = $GuestRole
    guest_sha256 = $isoHash
    runs         = $Runs
    samples      = $samples
    median_s     = $median
    min_s        = if ($sorted.Count) { $sorted[0] } else { $null }
    max_s        = if ($sorted.Count) { $sorted[$sorted.Count - 1] } else { $null }
    methods      = $usedMethods
    jsonl        = $JsonlPath
}
$summary | ConvertTo-Json -Depth 5

if ($samples.Count -eq $Runs) { exit 0 } else { exit 4 }
