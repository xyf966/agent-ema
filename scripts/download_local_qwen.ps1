param(
    [ValidateSet('model','runtime','cuda')][string]$Artifact = 'model',
    [ValidateRange(1,16)][int]$Concurrency = 4
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$emaRoot = Split-Path $PSScriptRoot -Parent
$emaDownloads = Join-Path $emaRoot 'work/local_llm/downloads'
$emaSpecs = @{
    model = @{
        url='https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/e87f176479d0855a907a41277aca2f8ee7a09523/Qwen3.5-4B-Q4_K_M.gguf?download=true'
        name='Qwen3.5-4B-Q4_K_M.gguf'; size=2740937888L
        sha256='00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4'
        target=(Join-Path $emaRoot 'work/local_llm/models/Qwen3.5-4B-Q4_K_M.gguf')
    }
    runtime = @{
        url='https://github.com/ggml-org/llama.cpp/releases/download/b11752/llama-b11752-bin-win-cuda-12.4-x64.zip'
        name='llama-b11752-bin-win-cuda-12.4-x64.zip'; size=271945089L
        target=(Join-Path $emaDownloads 'llama-b11752-bin-win-cuda-12.4-x64.zip')
    }
    cuda = @{
        url='https://github.com/ggml-org/llama.cpp/releases/download/b11752/cudart-llama-bin-win-cuda-12.4-x64.zip'
        name='cudart-llama-bin-win-cuda-12.4-x64.zip'; size=391443627L
        target=(Join-Path $emaDownloads 'cudart-llama-bin-win-cuda-12.4-x64.zip')
    }
}
$emaSpec = $emaSpecs[$Artifact]
$emaChunks = Join-Path $emaDownloads ($emaSpec.name + '.chunks')
New-Item -ItemType Directory -Path $emaChunks -Force | Out-Null
$emaChunkSize = 8MB
$emaCount = [int][math]::Ceiling($emaSpec.size / $emaChunkSize)
0..($emaCount - 1) | ForEach-Object -Parallel {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    $spec = $using:emaSpec
    $chunkFolder = $using:emaChunks
    $chunkSize = $using:emaChunkSize
    $index = $_
    $start = [long]$index * $chunkSize
    $end = [math]::Min($spec.size - 1, $start + $chunkSize - 1)
    $length = $end - $start + 1
    $part = Join-Path $chunkFolder ('{0:D5}.part' -f $index)
    if ((Test-Path -LiteralPath $part) -and (Get-Item -LiteralPath $part).Length -eq $length) {
        Write-Output ('cached ' + $spec.name + ' chunk ' + $index)
        return
    }
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        try {
            $response = Invoke-WebRequest -Uri $spec.url -Headers @{Range="bytes=$start-$end"} -OutFile $part -PassThru -TimeoutSec 180
            if ($response.StatusCode -ne 206 -or $response.Headers['Content-Range'] -ne "bytes $start-$end/$($spec.size)" -or
                (Get-Item -LiteralPath $part).Length -ne $length) { throw 'Invalid range response.' }
            Write-Output ('downloaded ' + $spec.name + ' chunk ' + $index)
            return
        } catch {
            if ($attempt -eq 2) { throw }
            Start-Sleep -Seconds 3
        }
    }
} -ThrottleLimit $Concurrency
$emaTemp = $emaSpec.target + '.assembling'
$emaDestination = [System.IO.File]::Create($emaTemp)
try {
    for ($emaIndex = 0; $emaIndex -lt $emaCount; $emaIndex++) {
        $emaPart = Join-Path $emaChunks ('{0:D5}.part' -f $emaIndex)
        $emaExpected = [math]::Min([long]$emaChunkSize, [long]$emaSpec.size - [long]$emaIndex * $emaChunkSize)
        if (!(Test-Path -LiteralPath $emaPart) -or (Get-Item -LiteralPath $emaPart).Length -ne $emaExpected) { throw 'Incomplete chunks.' }
        $emaSource = [System.IO.File]::OpenRead($emaPart)
        try { $emaSource.CopyTo($emaDestination) } finally { $emaSource.Dispose() }
    }
} finally { $emaDestination.Dispose() }
$emaHash = (Get-FileHash -LiteralPath $emaTemp -Algorithm SHA256).Hash.ToLowerInvariant()
if ($emaSpec.sha256 -and $emaHash -ne $emaSpec.sha256) { throw 'Downloaded model SHA256 mismatch.' }
Move-Item -LiteralPath $emaTemp -Destination $emaSpec.target -Force
[ordered]@{ artifact=$Artifact; url=$emaSpec.url; size=$emaSpec.size; sha256=$emaHash;
    expected_sha256=$emaSpec.sha256; path=$emaSpec.target; completed_utc=[DateTime]::UtcNow.ToString('o')
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $emaDownloads ($Artifact + '.receipt.json')) -Encoding utf8
Write-Output ('COMPLETE ' + $Artifact + ' sha256=' + $emaHash)
