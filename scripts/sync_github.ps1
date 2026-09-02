$ErrorActionPreference = "Stop"
$root = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$outputPath = Join-Path $root "output\xhs-feed.json"
$publicPath = Join-Path $root "data\xhs-feed.json"

if (-not (Test-Path -LiteralPath (Join-Path $root ".git"))) {
    throw "local Git repository is not initialized"
}
if (-not (Test-Path -LiteralPath $outputPath)) {
    throw "local collector output is missing"
}

$document = Get-Content -LiteralPath $outputPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($document.source -ne "xiaohongshu" -or $null -eq $document.results) {
    throw "output JSON failed the public-data validation"
}

New-Item -ItemType Directory -Force -Path (Split-Path $publicPath) | Out-Null
$tempPath = "$publicPath.tmp"
Copy-Item -LiteralPath $outputPath -Destination $tempPath -Force
Move-Item -LiteralPath $tempPath -Destination $publicPath -Force

$remote = git -C $root remote get-url origin 2>$null
if (-not $remote) {
    throw "GitHub remote origin is not configured"
}

git -C $root pull --rebase --autostash
git -C $root add -- "data/xhs-feed.json"
git -C $root diff --cached --quiet -- "data/xhs-feed.json"
if ($LASTEXITCODE -eq 0) {
    Write-Output "NO_CHANGE"
    exit 0
}

$message = "update xhs feed $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
git -C $root commit -m $message
if ($LASTEXITCODE -ne 0) {
    throw "git commit failed"
}
git -C $root push
if ($LASTEXITCODE -ne 0) {
    throw "git push failed; local JSON and commit were preserved"
}
Write-Output "PUSH_SUCCESS"
