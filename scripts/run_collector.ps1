param(
    [switch]$SkipGit,
    [int]$PerKeywordLimit = 10,
    [int]$MaxTotal = 80,
    [int]$MaxDetails = 60,
    [int]$MaxAgeDays = 60
)

$ErrorActionPreference = "Stop"
$root = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$rootPrefix = $root.TrimEnd("\") + "\"
$runId = Get-Date -Format "yyyyMMdd-HHmmss"
$runTemp = Join-Path $root "data\tmp\run-$runId"
$logPath = Join-Path $root "logs\run.log"
$mcpPid = $null
$exitCode = 22

function Assert-UnderRoot([string]$path) {
    $full = [IO.Path]::GetFullPath($path)
    if (-not $full.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase) -and
        $full -ne $root.TrimEnd("\")) {
        throw "path is outside XHSCollector: $full"
    }
    return $full
}

function Write-RunLog([string]$message) {
    Add-Content -LiteralPath $logPath -Value "$(Get-Date -Format o) $message" -Encoding UTF8
}

function Get-DescendantIds([int]$parentId, $snapshot) {
    $ids = [Collections.Generic.List[int]]::new()
    $ids.Add($parentId)
    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($item in $snapshot) {
            $childId = [int]$item.ProcessId
            if ($ids.Contains([int]$item.ParentProcessId) -and -not $ids.Contains($childId)) {
                $ids.Add($childId)
                $changed = $true
            }
        }
    }
    return $ids.ToArray()
}

function Stop-ScopedProcessTree([int]$parentId, [string]$tempPath) {
    if (-not $parentId) {
        return
    }
    $snapshot = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    $ids = @(Get-DescendantIds $parentId $snapshot)
    $depth = @{}
    foreach ($item in $snapshot) {
        $depth[[int]$item.ProcessId] = 0
    }
    foreach ($id in $ids) {
        $cursor = $id
        $level = 0
        while ($depth.ContainsKey($cursor) -and $cursor -ne $parentId -and $level -lt 30) {
            $parent = $snapshot | Where-Object { [int]$_.ProcessId -eq $cursor } | Select-Object -First 1
            if (-not $parent) {
                break
            }
            $cursor = [int]$parent.ParentProcessId
            $level++
        }
        $depth[$id] = $level
    }

    foreach ($id in ($ids | Sort-Object { $depth[$_] } -Descending)) {
        Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Milliseconds 700

    # If the MCP parent exited first, only clean orphaned browser helpers whose
    # command line still contains this run's private temp directory.
    $orphans = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -in @("chrome.exe", "leakless.exe") -and
            $_.CommandLine -like "*$tempPath*"
        })
    foreach ($item in $orphans) {
        Stop-Process -Id ([int]$item.ProcessId) -Force -ErrorAction SilentlyContinue
    }
    $remaining = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -in @("chrome.exe", "leakless.exe", "xiaohongshu-mcp-windows-amd64.exe") -and
            $_.CommandLine -like "*$tempPath*"
        })
    Write-RunLog "PROCESS_CLEANUP parent=$parentId scoped=$($ids.Count) remaining=$($remaining.Count)"
}

function Wait-ForTcpPort([string]$hostName, [int]$port, [int]$timeoutSeconds) {
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $client = [Net.Sockets.TcpClient]::new()
        try {
            $client.Connect($hostName, $port)
            $client.Close()
            return $true
        } catch {
            $client.Dispose()
            Start-Sleep -Milliseconds 500
        }
    }
    return $false
}

try {
    foreach ($path in @(
        $root,
        (Join-Path $root "bin"),
        (Join-Path $root "data"),
        (Join-Path $root "logs"),
        (Join-Path $root "output")
    )) {
        Assert-UnderRoot $path | Out-Null
        New-Item -ItemType Directory -Force -Path $path | Out-Null
    }
    New-Item -ItemType Directory -Force -Path $runTemp | Out-Null
    New-Item -ItemType Directory -Force -Path (Split-Path $logPath) | Out-Null
    Write-RunLog "TASK_START run=$runId"

    $mcpExe = Assert-UnderRoot (Join-Path $root "bin\xiaohongshu-mcp-windows-amd64.exe")
    $collectorPy = Assert-UnderRoot (Join-Path $root "scripts\collector.py")
    if (-not (Test-Path -LiteralPath $mcpExe)) {
        throw "MCP executable not found"
    }
    if (-not (Test-Path -LiteralPath $collectorPy)) {
        throw "collector.py not found"
    }

    $occupied = @(Get-NetTCPConnection -LocalAddress "127.0.0.1" -LocalPort 18060 -State Listen -ErrorAction SilentlyContinue)
    if ($occupied.Count -gt 0) {
        throw "port 18060 is already in use; refusing to touch an unrelated process"
    }

    $python = Get-Command python.exe -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty Source
    if (-not $python -and (Test-Path -LiteralPath "D:\Programs\Python\Python314\python.exe")) {
        $python = "D:\Programs\Python\Python314\python.exe"
    }
    if (-not $python) {
        throw "Python 3 executable not found"
    }

    # These variables apply only to this wrapper and its children.
    $env:COOKIES_PATH = Join-Path $root "data\cookies.json"
    $env:HOME = Join-Path $root "data\home"
    $env:USERPROFILE = Join-Path $root "data\home"
    $env:LOCALAPPDATA = Join-Path $root "data\localappdata"
    $env:APPDATA = Join-Path $root "data\appdata"
    $env:XDG_CONFIG_HOME = Join-Path $root "data\config"
    $env:XDG_CACHE_HOME = Join-Path $root "data\cache"
    $env:TEMP = $runTemp
    $env:TMP = $runTemp

    $mcpStdout = Join-Path $root "logs\mcp-$runId.stdout.log"
    $mcpStderr = Join-Path $root "logs\mcp-$runId.stderr.log"
    $mcp = Start-Process -FilePath $mcpExe `
        -ArgumentList @("-headless=true", "-port", ":18060") `
        -WorkingDirectory $runTemp `
        -WindowStyle Hidden `
        -RedirectStandardOutput $mcpStdout `
        -RedirectStandardError $mcpStderr `
        -PassThru
    $mcpPid = $mcp.Id
    Write-RunLog "MCP_START pid=$mcpPid port=18060"
    if (-not (Wait-ForTcpPort "127.0.0.1" 18060 60)) {
        throw "MCP did not open port 18060 within 60 seconds"
    }

    $collectorStdout = Join-Path $root "logs\collector-$runId.stdout.log"
    $collectorStderr = Join-Path $root "logs\collector-$runId.stderr.log"
    $collectorArgs = @(
        $collectorPy,
        "--root", $root,
        "--mcp-url", "http://127.0.0.1:18060/mcp",
        "--per-keyword-limit", $PerKeywordLimit,
        "--max-total", $MaxTotal,
        "--max-details", $MaxDetails,
        "--max-age-days", $MaxAgeDays
    )
    $collector = Start-Process -FilePath $python `
        -ArgumentList $collectorArgs `
        -WorkingDirectory $root `
        -WindowStyle Hidden `
        -RedirectStandardOutput $collectorStdout `
        -RedirectStandardError $collectorStderr `
        -Wait `
        -PassThru
    $exitCode = $collector.ExitCode
    Write-RunLog "COLLECTOR_EXIT code=$exitCode"

    if ($exitCode -eq 0 -and -not $SkipGit) {
        $syncScript = Join-Path $root "scripts\sync_github.ps1"
        if (Test-Path -LiteralPath $syncScript) {
            & $syncScript
            if ($LASTEXITCODE -ne 0) {
                $exitCode = 30
                Write-RunLog "GITHUB_UPLOAD_FAILED"
            } else {
                Write-RunLog "GITHUB_UPLOAD_SUCCESS"
            }
        } else {
            Write-RunLog "GITHUB_UPLOAD_SKIPPED_NOT_CONFIGURED"
        }
    }
} catch {
    Write-RunLog "RUN_FAILED reason=$($_.Exception.Message)"
    $exitCode = 22
} finally {
    if ($mcpPid) {
        Stop-ScopedProcessTree $mcpPid $runTemp
        Write-RunLog "MCP_STOP pid=$mcpPid"
    }
    Write-RunLog "TASK_END code=$exitCode"
}

exit $exitCode
