$ErrorActionPreference = "Stop"
$root = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$runId = Get-Date -Format "yyyyMMdd-HHmmss"
$runTemp = Join-Path $root "data\tmp\login-$runId"
$logPath = Join-Path $root "logs\login.log"
$loginExe = Join-Path $root "bin\xiaohongshu-login-windows-amd64.exe"

New-Item -ItemType Directory -Force -Path $runTemp,(Split-Path $logPath) | Out-Null
if (-not (Test-Path -LiteralPath $loginExe)) {
    throw "login executable not found"
}

$env:COOKIES_PATH = Join-Path $root "data\cookies.json"
$env:HOME = Join-Path $root "data\home"
$env:USERPROFILE = Join-Path $root "data\home"
$env:LOCALAPPDATA = Join-Path $root "data\localappdata"
$env:APPDATA = Join-Path $root "data\appdata"
$env:XDG_CONFIG_HOME = Join-Path $root "data\config"
$env:XDG_CACHE_HOME = Join-Path $root "data\cache"
$env:TEMP = $runTemp
$env:TMP = $runTemp

$stdout = Join-Path $root "logs\login-$runId.stdout.log"
$stderr = Join-Path $root "logs\login-$runId.stderr.log"
Add-Content -LiteralPath $logPath -Value "$(Get-Date -Format o) LOGIN_START run=$runId" -Encoding UTF8
$p = Start-Process -FilePath $loginExe `
    -WorkingDirectory $runTemp `
    -WindowStyle Normal `
    -RedirectStandardOutput $stdout `
    -RedirectStandardError $stderr `
    -PassThru
Wait-Process -Id $p.Id

# The login program normally closes its browser. If a helper remains orphaned,
# only stop Chromium/leakless processes whose command line contains this run's
# private temp directory.
Start-Sleep -Milliseconds 700
$orphans = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object {
        $_.Name -in @("chrome.exe", "leakless.exe") -and
        $_.CommandLine -like "*$runTemp*"
    })
foreach ($item in $orphans) {
    Stop-Process -Id ([int]$item.ProcessId) -Force -ErrorAction SilentlyContinue
}
Add-Content -LiteralPath $logPath -Value "$(Get-Date -Format o) LOGIN_END pid=$($p.Id) remaining=$($orphans.Count)" -Encoding UTF8
Write-Output "Login window closed. Check data\cookies.json exists, without displaying its contents."
