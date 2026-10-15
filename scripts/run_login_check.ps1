param(
    [switch]$SkipGit
)

$ErrorActionPreference = "Stop"
$root = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$rootPrefix = $root.TrimEnd("\") + "\"
$runId = Get-Date -Format "yyyyMMdd-HHmmss"
$runTemp = Join-Path $root "data\tmp\login-check-$runId"
$logPath = Join-Path $root "logs\login-check-run.log"
$lockStream = $null
$mcpPid = $null
$checkPid = $null
$python = $null
$gitPath = $null
$exitCode = 0
$environmentSaved = $false
$environmentNames = @(
    "COOKIES_PATH",
    "HOME",
    "USERPROFILE",
    "LOCALAPPDATA",
    "APPDATA",
    "XDG_CONFIG_HOME",
    "XDG_CACHE_HOME",
    "TEMP",
    "TMP"
)
$originalEnvironment = @{}

function Assert-UnderRoot([string]$path) {
    $full = [IO.Path]::GetFullPath($path)
    if (-not $full.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase) -and
        $full -ne $root.TrimEnd("\")) {
        throw "path is outside XHSCollector: $full"
    }
    return $full
}

function Write-LoginRunLog([string]$message) {
    Add-Content -LiteralPath $logPath -Value "$(Get-Date -Format o) $message" -Encoding UTF8
}

function Wait-ForOwnedMcpPort([int]$expectedPid, [int]$port, [int]$timeoutSeconds) {
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $process = Get-CimInstance Win32_Process -Filter "ProcessId=$expectedPid" -ErrorAction SilentlyContinue
        if (-not $process) {
            return $false
        }
        $listeners = @(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
        if ($listeners.Count -gt 0) {
            $owners = @($listeners | Select-Object -ExpandProperty OwningProcess -Unique)
            if ($owners.Count -eq 1 -and [int]$owners[0] -eq $expectedPid) {
                return $true
            }
            throw "MCP_PORT_OWNERSHIP_FAILED expected=$expectedPid actual=$($owners -join ',')"
        }
        Start-Sleep -Milliseconds 500
    }
    return $false
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
    Write-LoginRunLog "PROCESS_CLEANUP parent=$parentId scoped=$($ids.Count) remaining=$($remaining.Count)"
}

function Save-ProjectEnvironment {
    foreach ($name in $environmentNames) {
        $originalEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
    }
    $script:environmentSaved = $true
}

function Set-ProjectEnvironment {
    $env:COOKIES_PATH = Join-Path $root "data\cookies.json"
    $env:HOME = Join-Path $root "data\home"
    $env:USERPROFILE = Join-Path $root "data\home"
    $env:LOCALAPPDATA = Join-Path $root "data\localappdata"
    $env:APPDATA = Join-Path $root "data\appdata"
    $env:XDG_CONFIG_HOME = Join-Path $root "data\config"
    $env:XDG_CACHE_HOME = Join-Path $root "data\cache"
    $env:TEMP = $runTemp
    $env:TMP = $runTemp
}

function Restore-ProjectEnvironment {
    if (-not $environmentSaved) {
        return
    }
    foreach ($name in $environmentNames) {
        $value = $originalEnvironment[$name]
        if ($null -eq $value) {
            Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
        } else {
            Set-Item -LiteralPath "Env:$name" -Value $value
        }
    }
}

function Invoke-GitPull {
    & $gitPath -C $root pull --rebase --autostash 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "GIT_PULL_FAILED"
    }
}

function Sync-LoginStatus {
    & $gitPath -C $root add -- "data/login-status.json" 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "GIT_ADD_FAILED"
    }
    & $gitPath -C $root diff --cached --quiet -- "data/login-status.json" 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-LoginRunLog "GIT_NO_CHANGE"
        return
    }
    if ($LASTEXITCODE -ne 1) {
        throw "GIT_DIFF_FAILED"
    }
    & $gitPath -C $root commit --only -m "chore: update xhs login status" -- "data/login-status.json" 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "GIT_COMMIT_FAILED"
    }
    $pushOutputPath = Join-Path $runTemp "git-push-output.log"
    $savedErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & $gitPath -C $root push 2>$pushOutputPath | Out-Null
        $pushExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedErrorAction
    }
    $localHead = (& $gitPath -C $root rev-parse HEAD 2>$null).Trim()
    $remoteLine = @(& $gitPath -C $root ls-remote origin refs/heads/main 2>$null) |
        Select-Object -First 1
    $remoteHead = if ($remoteLine) {
        ([string]$remoteLine).Split("`t")[0].Trim()
    } else {
        ""
    }
    if ($remoteHead -ne $localHead) {
        throw "GIT_PUSH_FAILED"
    }
    Write-LoginRunLog "GITHUB_UPLOAD_SUCCESS push_exit=$pushExit verified=1"
}

try {
    foreach ($path in @(
        $root,
        (Join-Path $root "data"),
        (Join-Path $root "data\tmp"),
        (Join-Path $root "logs")
    )) {
        Assert-UnderRoot $path | Out-Null
        New-Item -ItemType Directory -Force -Path $path | Out-Null
    }
    New-Item -ItemType Directory -Force -Path $runTemp | Out-Null
    Write-LoginRunLog "TASK_START run=$runId"

    . (Assert-UnderRoot (Join-Path $root "scripts\project_lock.ps1"))
    $lockStream = Acquire-XHSProjectLock -Root $root
    if (-not $lockStream) {
        Write-LoginRunLog "LOCK_BUSY"
        $exitCode = 24
        return
    }
    Write-LoginRunLog "LOCK_ACQUIRED path=data\xhs.lock"

    $gitCommand = Get-Command git.exe -ErrorAction SilentlyContinue | Select-Object -First 1
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
        throw "GIT_NOT_FOUND"
    }
    $gitPath = $gitCommand.Source
    $python = Get-Command python.exe -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty Source
    if (-not $python -and (Test-Path -LiteralPath "D:\Programs\Python\Python314\python.exe")) {
        $python = "D:\Programs\Python\Python314\python.exe"
    }
    if (-not $python) {
        throw "PYTHON_NOT_FOUND"
    }

    $mcpExe = Assert-UnderRoot (Join-Path $root "bin\xiaohongshu-mcp-windows-amd64.exe")
    $checker = Assert-UnderRoot (Join-Path $root "scripts\login_check.py")
    if (-not (Test-Path -LiteralPath $mcpExe) -or -not (Test-Path -LiteralPath $checker)) {
        throw "LOGIN_CHECK_FILES_MISSING"
    }
    $env:GIT_TERMINAL_PROMPT = "0"
    if (-not $SkipGit) {
        Invoke-GitPull
    }

    $occupied = @(Get-NetTCPConnection -LocalPort 18060 -State Listen -ErrorAction SilentlyContinue)
    if ($occupied.Count -gt 0) {
        throw "MCP_PORT_BUSY"
    }

    Save-ProjectEnvironment
    Set-ProjectEnvironment
    $mcpStdout = Join-Path $root "logs\login-mcp-$runId.stdout.log"
    $mcpStderr = Join-Path $root "logs\login-mcp-$runId.stderr.log"
    $mcp = Start-Process -FilePath $mcpExe `
        -ArgumentList @("-headless=true", "-port", ":18060") `
        -WorkingDirectory $runTemp `
        -WindowStyle Hidden `
        -RedirectStandardOutput $mcpStdout `
        -RedirectStandardError $mcpStderr `
        -PassThru
    $mcpPid = $mcp.Id
    Write-LoginRunLog "MCP_START pid=$mcpPid port=18060"
    if (-not (Wait-ForOwnedMcpPort $mcpPid 18060 60)) {
        throw "MCP_START_FAILED"
    }

    $checkStdout = Join-Path $root "logs\login-check-$runId.stdout.log"
    $checkStderr = Join-Path $root "logs\login-check-$runId.stderr.log"
    $check = Start-Process -FilePath $python `
        -ArgumentList @($checker, "--root", $root, "--mcp-url", "http://127.0.0.1:18060/mcp") `
        -WorkingDirectory $root `
        -WindowStyle Hidden `
        -RedirectStandardOutput $checkStdout `
        -RedirectStandardError $checkStderr `
        -Wait `
        -PassThru
    $checkPid = $check.Id
    $exitCode = $check.ExitCode
    $checkPid = $null
    Write-LoginRunLog "LOGIN_CHECK_EXIT code=$exitCode"
} catch {
    Write-LoginRunLog "RUN_FAILED reason=$($_.Exception.Message)"
    if ($exitCode -eq 0) {
        $exitCode = 22
    }
} finally {
    if ($checkPid) {
        Stop-ScopedProcessTree $checkPid $runTemp
    }
    if ($mcpPid) {
        Stop-ScopedProcessTree $mcpPid $runTemp
        Write-LoginRunLog "MCP_STOP pid=$mcpPid"
    }
    Restore-ProjectEnvironment

    if (-not $SkipGit -and (Test-Path -LiteralPath (Join-Path $root "data\login-status.json")) -and $gitPath) {
        try {
            Sync-LoginStatus
        } catch {
            Write-LoginRunLog "GITHUB_UPLOAD_FAILED reason=$($_.Exception.Message)"
            if ($exitCode -eq 0) {
                $exitCode = 30
            }
        }
    }

    if ($lockStream) {
        $lockStream.Dispose()
        $lockStream = $null
        Write-LoginRunLog "LOCK_RELEASED"
    }
    Write-LoginRunLog "TASK_END code=$exitCode"
}

exit $exitCode
