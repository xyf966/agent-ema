param(
    [ValidateSet('start','stop','status','probe','roundtrip')][string]$Action = 'start',
    [int]$ContextSize = 16384,
    [int]$GpuLayers = 99,
    [string]$PythonExecutable = ''
)
$ErrorActionPreference = 'Stop'
$emaRoot = Split-Path $PSScriptRoot -Parent
$emaConfigPath = Join-Path $emaRoot 'configs/llm_local_qwen35_4b.json'
$emaConfig = Get-Content -LiteralPath $emaConfigPath -Raw | ConvertFrom-Json
$emaExe = Join-Path $emaRoot $emaConfig.server_executable
$emaModel = Join-Path $emaRoot $emaConfig.model_file
$emaLogs = Join-Path $emaRoot 'work/local_llm/logs'
$emaStatePath = Join-Path $emaRoot 'work/local_llm/server.json'
if ($Action -in @('probe','roundtrip')) {
    if (!$PythonExecutable) {
        $PythonExecutable = Join-Path $env:USERPROFILE '.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe'
    }
    if (!(Test-Path -LiteralPath $PythonExecutable)) { throw 'Supply a Python interpreter with -PythonExecutable.' }
    & $PythonExecutable (Join-Path $emaRoot 'scripts/run_local_qwen.py') --mode $Action
    exit $LASTEXITCODE
}
$emaProcess = $null
if (Test-Path -LiteralPath $emaStatePath) {
    $emaState = Get-Content -LiteralPath $emaStatePath -Raw | ConvertFrom-Json
    $emaCandidate = Get-Process -Id $emaState.pid -ErrorAction SilentlyContinue
    if ($emaCandidate -and $emaCandidate.Path -eq $emaExe -and
        $emaCandidate.StartTime.ToUniversalTime().Ticks -eq ([DateTime]$emaState.started_utc).ToUniversalTime().Ticks) {
        $emaProcess = $emaCandidate
    }
}
if ($Action -eq 'stop') {
    if ($emaProcess) { Stop-Process -Id $emaProcess.Id; Write-Output 'Local Qwen stopped.' }
    else { Write-Output 'No matching local Qwen process.' }
    exit 0
}
if ($Action -eq 'status') {
    if (!$emaProcess) { Write-Output 'Local Qwen is not running.'; exit 1 }
    Invoke-RestMethod -Uri 'http://127.0.0.1:8087/health' -NoProxy -TimeoutSec 5 | ConvertTo-Json
    exit 0
}
if ($emaProcess) { Write-Output ('Local Qwen is already running, PID ' + $emaProcess.Id); exit 0 }
if (!(Test-Path -LiteralPath $emaExe)) { throw 'Runtime missing: finish the deployment downloads first.' }
if (!(Test-Path -LiteralPath $emaModel)) { throw 'Model missing: finish the deployment downloads first.' }
if ((Get-Item -LiteralPath $emaModel).Length -ne $emaConfig.model_size_bytes) { throw 'Model size mismatch.' }
if ((Get-FileHash -LiteralPath $emaModel -Algorithm SHA256).Hash.ToLowerInvariant() -ne $emaConfig.model_sha256) { throw 'Model hash mismatch.' }
if ($ContextSize -lt 2048 -or $ContextSize -gt 16384) { throw 'ContextSize must be between 2048 and 16384 on this machine.' }
New-Item -ItemType Directory -Path $emaLogs -Force | Out-Null
$emaArguments = @('-m', ('"' + $emaModel + '"'), '--alias', $emaConfig.model,
    '--host', '127.0.0.1', '--port', '8087', '--ctx-size', $ContextSize,
    '--n-gpu-layers', $GpuLayers, '--parallel', '1', '--threads', '6',
    '--batch-size', '256', '--ubatch-size', '128', '--jinja', '--no-context-shift',
    '--reasoning-format', 'deepseek')
$emaStamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$emaStarted = Start-Process -FilePath $emaExe -ArgumentList $emaArguments -WorkingDirectory $emaRoot -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput (Join-Path $emaLogs ($emaStamp + '.out.log')) `
    -RedirectStandardError (Join-Path $emaLogs ($emaStamp + '.err.log'))
Start-Sleep -Milliseconds 500
$emaStarted.Refresh()
if ($emaStarted.HasExited) { throw 'Server exited during startup; inspect work/local_llm/logs.' }
[ordered]@{ pid=$emaStarted.Id; started_utc=$emaStarted.StartTime.ToUniversalTime().ToString('o'); executable=$emaExe;
    model=$emaConfig.model; context_size=$ContextSize; gpu_layers=$GpuLayers; base_url=$emaConfig.base_url;
    stdout=(Join-Path $emaLogs ($emaStamp + '.out.log')); stderr=(Join-Path $emaLogs ($emaStamp + '.err.log'))
} | ConvertTo-Json | Set-Content -LiteralPath $emaStatePath -Encoding utf8
Write-Output ('Local Qwen starting, PID ' + $emaStarted.Id + ', endpoint ' + $emaConfig.base_url)
