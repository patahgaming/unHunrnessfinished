#Requires -Version 7.0
<#
  build-bundle.ps1 — one build, one artifact (D-052).

  Builds the Rust core and the vendored NullClaw, then assembles dist/:
      bothea.exe  nullclaw.exe  config/bothea.toml  skills/bothea/SKILL.md
      LICENSES/nullclaw-LICENSE  bundle.json  manifest.sha256

  NullClaw is built from vendor/nullclaw at the pinned release commit with Zig 0.16.0,
  and -Dversion is passed so the binary reports the tag instead of "dev".

  Usage:
      pwsh scripts/build-bundle.ps1
      pwsh scripts/build-bundle.ps1 -SkipNullClaw      # reuse an existing nullclaw.exe
      pwsh scripts/build-bundle.ps1 -ForceNullClaw     # rebuild the gateway
#>
[CmdletBinding()]
param(
    [string]$Zig,
    [string]$OutDir = 'dist',
    [switch]$SkipNullClaw,
    [switch]$ForceNullClaw
)

$ErrorActionPreference = 'Stop'

# ---- constants: the pin lives here and in bundle.json, never guessed -------------------
$NullClawTag    = 'v2026.5.29'
$NullClawCommit = 'b25c6eb59f845f4f8cdbb50d6f284cb56d723435'
$ZigVersion     = '0.16.0'
$NullClawUrl    = 'https://github.com/nullclaw/nullclaw'
$Deps = @(
    @{ Name = 'websocket'; Url = 'https://github.com/nullclaw/websocket'; Commit = '9151f70b27024a072ea04425b9e7609eb6b1386c' },
    @{ Name = 'wasm3';     Url = 'https://github.com/nullclaw/wasm3';     Commit = '8a29b0080f1f65dbbe8b8f8c4d8148480feff377' }
)

function Fail([string]$Message) {
    Write-Host "build-bundle: FAIL — $Message" -ForegroundColor Red
    exit 1
}

function Invoke-Git {
    param([string[]]$GitArgs)
    & git @GitArgs
    if ($LASTEXITCODE -ne 0) { Fail "git $($GitArgs -join ' ') failed" }
}

$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
    # ---- 1. Zig toolchain -------------------------------------------------------------
    if (-not $Zig) {
        $Zig = Join-Path $root '.tools\zig\zig-x86_64-windows-0.16.0\zig.exe'
    }
    if (-not (Test-Path -LiteralPath $Zig)) {
        Fail "Zig not found at $Zig. Install Zig $ZigVersion or pass -Zig <path>."
    }
    $zigActual = (& $Zig version).Trim()
    if ($zigActual -ne $ZigVersion) {
        Fail "Zig $zigActual found, but this project pins exactly $ZigVersion (upstream supports only that)."
    }
    Write-Host "zig       $zigActual  ($Zig)"

    # Zig's global cache must be inside the workspace; the default location is not writable here.
    $env:ZIG_GLOBAL_CACHE_DIR = Join-Path $root '.tools\zig-global-cache'
    $env:ZIG_LOCAL_CACHE_DIR  = Join-Path $root '.tools\zig-local-cache'
    $env:TMP = Join-Path $root '.tools\tmp'
    $env:TEMP = $env:TMP
    foreach ($d in @($env:ZIG_GLOBAL_CACHE_DIR, $env:ZIG_LOCAL_CACHE_DIR, $env:TMP)) {
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    }

    # ---- 2. vendored NullClaw ---------------------------------------------------------
    $vendor = Join-Path $root 'vendor\nullclaw'
    if (-not (Test-Path -LiteralPath (Join-Path $vendor 'build.zig.zon'))) {
        Write-Host "vendor/nullclaw missing; cloning $NullClawUrl at $NullClawTag ..."
        New-Item -ItemType Directory -Force -Path (Join-Path $root 'vendor') | Out-Null
        Invoke-Git @('clone', '--depth', '1', '--branch', $NullClawTag, $NullClawUrl, $vendor)
    }
    $head = (& git -C $vendor rev-parse HEAD).Trim()
    if ($head -ne $NullClawCommit) {
        Fail "vendor/nullclaw is at $head, expected $NullClawCommit. Re-clone at tag $NullClawTag."
    }
    Write-Host "nullclaw  $NullClawTag @ $($head.Substring(0,12))"

    # ---- 3. dependency forks (offline-safe; TLS cert fetch is not reliable here) -------
    $forks = Join-Path $root '.tmp\forks'
    foreach ($dep in $Deps) {
        $dir = Join-Path $forks $dep.Name
        if (-not (Test-Path -LiteralPath (Join-Path $dir '.git'))) {
            Write-Host "fetching dependency $($dep.Name) @ $($dep.Commit.Substring(0,12)) ..."
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            Invoke-Git @('-C', $dir, 'init', '-q')
            Invoke-Git @('-C', $dir, 'remote', 'add', 'origin', $dep.Url)
            Invoke-Git @('-C', $dir, 'fetch', '-q', '--depth', '1', 'origin', $dep.Commit)
            Invoke-Git @('-C', $dir, 'checkout', '-q', 'FETCH_HEAD')
        }
        $depHead = (& git -C $dir rev-parse HEAD).Trim()
        if ($depHead -ne $dep.Commit) { Fail "dependency $($dep.Name) is at $depHead, expected $($dep.Commit)" }
    }

    # ---- 4. build NullClaw ------------------------------------------------------------
    $nullclawExe = Join-Path $vendor 'zig-out\bin\nullclaw.exe'
    if ($ForceNullClaw -or -not (Test-Path -LiteralPath $nullclawExe)) {
        if ($SkipNullClaw) { Fail "-SkipNullClaw was given but $nullclawExe does not exist." }
        Write-Host "building nullclaw (ReleaseSmall, version $NullClawTag) ..."
        $forkArgs = @()
        foreach ($dep in $Deps) { $forkArgs += "--fork=$(Join-Path $forks $dep.Name)" }
        Push-Location $vendor
        try {
            & $Zig build -Doptimize=ReleaseSmall "-Dversion=$NullClawTag" @forkArgs
            if ($LASTEXITCODE -ne 0) { Fail "zig build failed (exit $LASTEXITCODE)" }
        } finally { Pop-Location }
        if (-not (Test-Path -LiteralPath $nullclawExe)) { Fail "zig build produced no nullclaw.exe" }
    } else {
        Write-Host "nullclaw  reusing $nullclawExe"
    }
    $nullclawVersion = (& $nullclawExe --version).Trim()
    if ($nullclawVersion -notmatch [regex]::Escape($NullClawTag)) {
        Fail "nullclaw reports '$nullclawVersion'; expected it to contain $NullClawTag (build without -Dversion?)"
    }
    Write-Host "nullclaw  reports $nullclawVersion"

    # ---- 5. build the Rust core -------------------------------------------------------
    Write-Host "building bothea (cargo release) ..."
    & cargo build --release
    if ($LASTEXITCODE -ne 0) { Fail "cargo build failed (exit $LASTEXITCODE)" }
    $botheaExe = Join-Path $root 'target\release\bothea.exe'
    if (-not (Test-Path -LiteralPath $botheaExe)) { Fail "cargo produced no bothea.exe" }

    # ---- 6. assemble dist/ ------------------------------------------------------------
    $out = Join-Path $root $OutDir
    if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $out, (Join-Path $out 'config'), (Join-Path $out 'skills\bothea'), (Join-Path $out 'LICENSES') | Out-Null

    Copy-Item -LiteralPath $botheaExe   -Destination (Join-Path $out 'bothea.exe')
    Copy-Item -LiteralPath $nullclawExe -Destination (Join-Path $out 'nullclaw.exe')
    Copy-Item -LiteralPath (Join-Path $root 'config\bothea.toml') -Destination (Join-Path $out 'config\bothea.toml')
    Copy-Item -LiteralPath (Join-Path $root 'skills\bothea\SKILL.md') -Destination (Join-Path $out 'skills\bothea\SKILL.md')
    $license = Join-Path $vendor 'LICENSE'
    if (Test-Path -LiteralPath $license) {
        Copy-Item -LiteralPath $license -Destination (Join-Path $out 'LICENSES\nullclaw-LICENSE')
    } else {
        Fail "vendor/nullclaw/LICENSE missing; the bundle must ship the MIT notice (D-052)"
    }

    # ---- 7. hashes and metadata -------------------------------------------------------
    $files = Get-ChildItem -LiteralPath $out -Recurse -File | Where-Object { $_.Name -notin @('bundle.json', 'manifest.sha256') } |
        ForEach-Object {
            [pscustomobject]@{
                rel  = [System.IO.Path]::GetRelativePath($out, $_.FullName) -replace '\\', '/'
                hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLower()
                size = $_.Length
            }
        } | Sort-Object rel

    $rows = $files | ForEach-Object { "{0}  {1}" -f $_.hash, $_.rel }
    Set-Content -LiteralPath (Join-Path $out 'manifest.sha256') -Value $rows -Encoding utf8NoBOM

    $botheaVersion = (& $botheaExe --version).Trim()
    $bundle = [ordered]@{
        schema           = 1
        built_at         = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        nullclaw_tag     = $NullClawTag
        nullclaw_commit  = $NullClawCommit
        nullclaw_zig     = $ZigVersion
        nullclaw_version = $nullclawVersion
        bothea_version   = $botheaVersion
        files            = @($files | ForEach-Object { [ordered]@{ path = $_.rel; sha256 = $_.hash; size = $_.size } })
    }
    $bundle | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $out 'bundle.json') -Encoding utf8NoBOM

    Write-Host ""
    Write-Host "dist/ assembled:" -ForegroundColor Green
    Get-ChildItem -LiteralPath $out -Recurse -File | ForEach-Object {
        $rel = [System.IO.Path]::GetRelativePath($out, $_.FullName)
        Write-Host ("  {0,-34} {1,12:N0} bytes" -f $rel, $_.Length)
    }

    # ---- 8. verify the bundle with the binary it contains -----------------------------
    $verifyOut = & (Join-Path $out 'bothea.exe') bundle verify --dir $out 2>&1
    $verifyCode = $LASTEXITCODE
    $verifyOut | ForEach-Object { Write-Host $_ }
    if ($verifyCode -ne 0) { Fail "bundled bothea failed to verify its own bundle (exit $verifyCode)" }
    Write-Host "build-bundle: OK" -ForegroundColor Green
}
finally {
    Pop-Location
}
