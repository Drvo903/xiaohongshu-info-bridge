$ErrorActionPreference = "Stop"
$root = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$outputPath = Join-Path $root "output\xhs-feed.json"
$publicFeedPath = Join-Path $root "data\xhs-feed.json"
$publicLatestPath = Join-Path $root "data\latest.json"
$publicStatusPath = Join-Path $root "data\status.json"

$gitCommand = Get-Command git.exe -ErrorAction SilentlyContinue |
    Select-Object -First 1
if (-not $gitCommand) {
    foreach ($candidate in @(
        "C:\Program Files\Git\cmd\git.exe",
        "C:\Users\87134\.cache\codex-runtimes\codex-primary-runtime\dependencies\native\git\cmd\git.exe"
    )) {
        if (Test-Path -LiteralPath $candidate) {
            $gitCommand = Get-Command $candidate
            break
        }
    }
}
if (-not $gitCommand) {
    throw "git.exe was not found"
}
$env:Path = "$(Split-Path $gitCommand.Source);$env:Path"

if (-not (Test-Path -LiteralPath (Join-Path $root ".git"))) {
    throw "local Git repository is not initialized"
}
foreach ($path in @($outputPath, $publicFeedPath, $publicLatestPath, $publicStatusPath)) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "required JSON is missing: $path"
    }
}

try {
    $document = Get-Content -LiteralPath $outputPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $latest = Get-Content -LiteralPath $publicLatestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $status = Get-Content -LiteralPath $publicStatusPath -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    throw "one of the public JSON files is invalid"
}

if ($document.source -ne "xiaohongshu" -or $null -eq $document.results) {
    throw "xhs-feed.json failed the public-data validation"
}
if ($latest.source -ne "xiaohongshu" -or
    $null -eq $latest.results -or
    [int]$latest.result_count -ne @($latest.results).Count -or
    [int]$latest.result_count -gt [int]$latest.max_results -or
    [int]$latest.max_results -gt 200) {
    throw "latest.json failed the public-data validation"
}
if ($status.full_result_count -ne @($document.results).Count -or
    $status.latest_result_count -ne @($latest.results).Count -or
    (-not $status.last_github_upload_status -and -not $status.github_upload_status)) {
    throw "status.json failed the consistency validation"
}

New-Item -ItemType Directory -Force -Path (Split-Path $publicFeedPath) | Out-Null
$tempPath = "$publicFeedPath.tmp"
Copy-Item -LiteralPath $outputPath -Destination $tempPath -Force
try {
    Get-Content -LiteralPath $tempPath -Raw -Encoding UTF8 | ConvertFrom-Json | Out-Null
    Move-Item -LiteralPath $tempPath -Destination $publicFeedPath -Force
} finally {
    if (Test-Path -LiteralPath $tempPath) {
        [IO.File]::Delete($tempPath)
    }
}

$remote = git -C $root remote get-url origin 2>$null
if (-not $remote) {
    throw "GitHub remote origin is not configured"
}

git -C $root pull --rebase --autostash
git -C $root add -- "data/xhs-feed.json" "data/latest.json" "data/status.json"
git -C $root diff --cached --quiet -- "data/xhs-feed.json" "data/latest.json" "data/status.json"
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
