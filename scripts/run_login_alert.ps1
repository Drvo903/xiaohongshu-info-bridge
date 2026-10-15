$ErrorActionPreference = "Stop"
$root = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$alertPath = Join-Path $root "data\login-alert.pending.json"
$logPath = Join-Path $root "logs\login-alert.log"

function Write-AlertLog([string]$message) {
    Add-Content -LiteralPath $logPath -Value "$(Get-Date -Format o) $message" -Encoding UTF8
}

if (-not (Test-Path -LiteralPath $alertPath)) {
    exit 0
}

$message = "XHSCollector: Xiaohongshu login expired. Run D:\XHSCollector\scripts\login.ps1 and scan the QR code."
& "$env:SystemRoot\System32\msg.exe" $env:USERNAME /TIME:60 $message 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) {
    Remove-Item -LiteralPath $alertPath -Force
    Write-AlertLog "LOGIN_ALERT_SHOWN"
    exit 0
}

Write-AlertLog "LOGIN_ALERT_PENDING_NO_SESSION"
exit 1
