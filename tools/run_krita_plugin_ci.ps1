[CmdletBinding()]
param(
    [string]$KritaPath = "",
    [int]$TimeoutSeconds = 180,
    [switch]$KeepArtifacts
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $ProjectRoot

if (-not [Environment]::UserInteractive) {
    throw "The real Krita smoke test requires an interactive Windows session; configure the self-hosted runner accordingly."
}

function Resolve-Krita {
    param([string]$ExplicitPath)
    if ($ExplicitPath) {
        if (-not (Test-Path -LiteralPath $ExplicitPath)) { throw "Krita executable not found: $ExplicitPath" }
        return (Resolve-Path -LiteralPath $ExplicitPath).Path
    }
    $candidates = @(
        (Join-Path ${env:ProgramFiles} "Krita (x64)\bin\krita.exe"),
        (Join-Path ${env:ProgramFiles} "Krita\bin\krita.exe"),
        (Join-Path ${env:LOCALAPPDATA} "Programs\Krita\bin\krita.exe")
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    if ($candidates.Count -gt 0) { return (Resolve-Path -LiteralPath $candidates[0]).Path }
    $command = Get-Command krita.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    throw "Krita was not found on the runner."
}

function Get-ProcessTreeIds {
    param([int]$RootPid)
    $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    if (-not ($all | Where-Object { [int]$_.ProcessId -eq $RootPid })) { return @() }
    $ids = New-Object System.Collections.Generic.HashSet[int]
    [void]$ids.Add($RootPid)
    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($proc in $all) {
            $pid = [int]$proc.ProcessId
            $parent = [int]$proc.ParentProcessId
            if ($ids.Contains($parent) -and -not $ids.Contains($pid)) {
                [void]$ids.Add($pid)
                $changed = $true
            }
        }
    }
    @($ids)
}

function Stop-ProcessTree {
    param([int]$RootPid)
    if ($RootPid -eq 0) { return }
    foreach ($pid in @(Get-ProcessTreeIds -RootPid $RootPid | Sort-Object -Descending)) {
        try { Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue } catch { }
    }
}

function Set-PythonPluginEnabled {
    param([string]$PluginName)
    $key = "enable_$PluginName"
    if ($script:ConfigText -match '(?ms)^\[python\]\s*(?<body>.*?)(?=^\[|\z)') {
        $body = $Matches['body']
        if ($body -match "(?m)^\s*$([regex]::Escape($key))\s*=") {
            $body = [regex]::Replace($body, "(?m)^\s*$([regex]::Escape($key))\s*=.*$", "$key=true")
        } else {
            $body = "$key=true`r`n$body"
        }
        $script:ConfigText = [regex]::Replace($script:ConfigText, '(?ms)^\[python\]\s*.*?(?=^\[|\z)', "[python]`r`n$body")
    } else {
        if ($script:ConfigText.Length -gt 0 -and -not $script:ConfigText.EndsWith("`r`n")) { $script:ConfigText += "`r`n" }
        $script:ConfigText += "[python]`r`n$key=true`r`n"
    }
}

$KritaExe = Resolve-Krita $KritaPath
$KritaBin = Split-Path -Parent $KritaExe
$KritaCom = Join-Path $KritaBin "krita.com"
if (-not (Test-Path -LiteralPath $KritaCom)) { throw "Krita console executable not found: $KritaCom" }

$existingKrita = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -in @("krita.exe", "krita.com") })
if ($existingKrita.Count -gt 0) {
    $ids = ($existingKrita | ForEach-Object { $_.ProcessId }) -join ", "
    throw "Krita is already running on this runner (PID(s): $ids). Close it before running CI."
}

$ResourceRoot = Join-Path $env:APPDATA "krita"
$PyKrita = Join-Path $ResourceRoot "pykrita"
$TargetPlugin = Join-Path $PyKrita "importality_krita_layers"
$CiPlugin = Join-Path $PyKrita "importality_krita_ci"
$TargetDesktop = Join-Path $PyKrita "importality_krita_layers.desktop"
$CiDesktop = Join-Path $PyKrita "importality_krita_ci.desktop"
$Config = Join-Path $env:LOCALAPPDATA "kritarc"
$ConfigBackup = Join-Path $env:TEMP "importality-krita-kritarc-$([guid]::NewGuid().ToString('N')).bak"
$LogDir = Join-Path $ProjectRoot ".ci-local\krita-runtime"
$ResultPath = Join-Path $LogDir "result.json"
$StagePath = Join-Path $LogDir "stage.log"
$StdoutPath = Join-Path $LogDir "krita.stdout.log"
$StderrPath = Join-Path $LogDir "krita.stderr.log"
$KritaLogPath = Join-Path $LogDir "krita.log"
$KritaSysInfoPath = Join-Path $LogDir "krita-sysinfo.log"
$Backups = @(
    "$TargetPlugin.importality-ci-backup",
    "$CiPlugin.importality-ci-backup",
    "$TargetDesktop.importality-ci-backup",
    "$CiDesktop.importality-ci-backup"
)
$Process = $null
$RootPid = 0
$SavedExistingConfig = Test-Path -LiteralPath $Config

function Install-Plugins {
    foreach ($backup in $Backups) { Remove-Item -Force -Recurse -LiteralPath $backup -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $TargetPlugin) { Move-Item -LiteralPath $TargetPlugin -Destination $Backups[0] -Force }
    if (Test-Path -LiteralPath $CiPlugin) { Move-Item -LiteralPath $CiPlugin -Destination $Backups[1] -Force }
    if (Test-Path -LiteralPath $TargetDesktop) { Move-Item -LiteralPath $TargetDesktop -Destination $Backups[2] -Force }
    if (Test-Path -LiteralPath $CiDesktop) { Move-Item -LiteralPath $CiDesktop -Destination $Backups[3] -Force }
    New-Item -ItemType Directory -Force -Path $PyKrita | Out-Null
    Copy-Item -Recurse -Force -LiteralPath (Join-Path $ProjectRoot "tools\krita_plugin\importality_krita_layers") -Destination $TargetPlugin
    Copy-Item -Recurse -Force -LiteralPath (Join-Path $ProjectRoot "tools\krita_plugin\importality_krita_ci") -Destination $CiPlugin
    Copy-Item -Force -LiteralPath (Join-Path $ProjectRoot "tools\krita_plugin\importality_krita_layers.desktop") -Destination $TargetDesktop
    Copy-Item -Force -LiteralPath (Join-Path $ProjectRoot "tools\krita_plugin\importality_krita_ci.desktop") -Destination $CiDesktop
}

function Enable-Plugins {
    if ($SavedExistingConfig) {
        Copy-Item -Force -LiteralPath $Config -Destination $ConfigBackup
        $script:ConfigText = Get-Content -Raw -LiteralPath $Config
    } else {
        $script:ConfigText = ""
    }
    Set-PythonPluginEnabled "importality_krita_layers"
    Set-PythonPluginEnabled "importality_krita_ci"
    Set-Content -LiteralPath $Config -Value $script:ConfigText -Encoding UTF8
}

function Restore-State {
    Remove-Item -Force -Recurse -LiteralPath $TargetPlugin, $CiPlugin -ErrorAction SilentlyContinue
    Remove-Item -Force -LiteralPath $TargetDesktop, $CiDesktop -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $Backups[0]) { Move-Item -LiteralPath $Backups[0] -Destination $TargetPlugin -Force }
    if (Test-Path -LiteralPath $Backups[1]) { Move-Item -LiteralPath $Backups[1] -Destination $CiPlugin -Force }
    if (Test-Path -LiteralPath $Backups[2]) { Move-Item -LiteralPath $Backups[2] -Destination $TargetDesktop -Force }
    if (Test-Path -LiteralPath $Backups[3]) { Move-Item -LiteralPath $Backups[3] -Destination $CiDesktop -Force }
    if (Test-Path -LiteralPath $ConfigBackup) {
        Move-Item -Force -LiteralPath $ConfigBackup -Destination $Config
    } elseif (-not $SavedExistingConfig) {
        Remove-Item -Force -LiteralPath $Config -ErrorAction SilentlyContinue
    }
}

function Save-Diagnostics {
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    $knownLog = Join-Path $env:LOCALAPPDATA "krita.log"
    $knownSysInfo = Join-Path $env:LOCALAPPDATA "krita-sysinfo.log"
    if (Test-Path -LiteralPath $knownLog) { Copy-Item -Force -LiteralPath $knownLog -Destination $KritaLogPath -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $knownSysInfo) { Copy-Item -Force -LiteralPath $knownSysInfo -Destination $KritaSysInfoPath -ErrorAction SilentlyContinue }
}

try {
    Remove-Item -Force -Recurse -LiteralPath $LogDir -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    Install-Plugins
    Enable-Plugins

    $env:IMPORTALITY_KRITA_CI_PROJECT_ROOT = $ProjectRoot
    $env:IMPORTALITY_KRITA_CI_RESOURCE_ROOT = $ResourceRoot
    $env:IMPORTALITY_KRITA_CI_RESULT = $ResultPath
    $env:IMPORTALITY_KRITA_CI_STAGE = $StagePath

    Write-Host "Krita executable: $KritaExe"
    Write-Host "Krita console: $KritaCom"
    Write-Host "Starting real Importality Krita CI smoke..."

    $Process = Start-Process -FilePath $KritaCom -ArgumentList "--nosplash" -WorkingDirectory $ProjectRoot -WindowStyle Minimized -PassThru -RedirectStandardOutput $StdoutPath -RedirectStandardError $StderrPath
    $RootPid = $Process.Id
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $startupDeadline = (Get-Date).AddSeconds(20)

    while (-not (Test-Path -LiteralPath $ResultPath)) {
        Start-Sleep -Milliseconds 500
        if (-not (Get-Process -Id $RootPid -ErrorAction SilentlyContinue) -and -not (Test-Path -LiteralPath $ResultPath)) {
            Save-Diagnostics
            throw "Krita exited before producing result.json."
        }
        if ((Get-Date) -ge $startupDeadline -and @(Get-ProcessTreeIds -RootPid $RootPid).Count -eq 0) {
            Save-Diagnostics
            throw "Krita did not establish a process tree for the CI launch."
        }
        if ((Get-Date) -ge $deadline) {
            Save-Diagnostics
            Stop-ProcessTree $RootPid
            throw "Importality Krita CI smoke timed out after $TimeoutSeconds seconds."
        }
    }

    Save-Diagnostics
    $result = Get-Content -Raw -LiteralPath $ResultPath | ConvertFrom-Json
    if ($result.status -ne "passed") {
        throw "Real Krita Importality smoke failed: $($result.error)"
    }
    Write-Host "Real Krita Importality smoke passed."
    Write-Host ($result | ConvertTo-Json -Depth 10)
}
finally {
    try { Stop-ProcessTree $RootPid } catch { }
    Save-Diagnostics
    Remove-Item Env:IMPORTALITY_KRITA_CI_PROJECT_ROOT -ErrorAction SilentlyContinue
    Remove-Item Env:IMPORTALITY_KRITA_CI_RESOURCE_ROOT -ErrorAction SilentlyContinue
    Remove-Item Env:IMPORTALITY_KRITA_CI_RESULT -ErrorAction SilentlyContinue
    Remove-Item Env:IMPORTALITY_KRITA_CI_STAGE -ErrorAction SilentlyContinue
    try { Restore-State } catch { Write-Warning "Failed to restore Krita CI state: $($_.Exception.Message)" }
    if (-not $KeepArtifacts) {
        Remove-Item -Force -Recurse -LiteralPath $LogDir -ErrorAction SilentlyContinue
    }
}
