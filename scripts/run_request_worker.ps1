param(
    [switch]$SkipGit
)

$ErrorActionPreference = "Stop"
$root = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$rootPrefix = $root.TrimEnd("\") + "\"
$runId = Get-Date -Format "yyyyMMdd-HHmmss"
$runTemp = Join-Path $root "data\tmp\request-run-$runId"
$logPath = Join-Path $root "logs\request-run.log"
$lockStream = $null
$mcpPid = $null
$workerPid = $null
$validationPid = $null
$pendingFile = $null
$python = $null
$failureWarning = $null
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

function Write-RequestRunLog([string]$message) {
    Add-Content -LiteralPath $logPath -Value "$(Get-Date -Format o) $message" -Encoding UTF8
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

    # If the MCP parent exited first, only clean helpers from this run's
    # private temp directory. Normal Chrome/Edge processes do not match it.
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
    Write-RequestRunLog "PROCESS_CLEANUP parent=$parentId scoped=$($ids.Count) remaining=$($remaining.Count)"
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
    & $gitPath -C $root pull --rebase --autostash *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "GIT_PULL_FAILED"
    }
}

function Sync-RequestChanges([string]$commitMessage) {
    & $gitPath -C $root add -- "requests" *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "GIT_ADD_FAILED"
    }

    & $gitPath -C $root diff --cached --quiet -- "requests" *> $null
    if ($LASTEXITCODE -eq 0) {
        Write-RequestRunLog "REQUEST_GIT_NO_CHANGE"
        return
    }
    if ($LASTEXITCODE -ne 1) {
        throw "GIT_DIFF_FAILED"
    }

    & $gitPath -C $root commit -m $commitMessage *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "GIT_COMMIT_FAILED"
    }
    & $gitPath -C $root push *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "GIT_PUSH_FAILED"
    }
    Write-RequestRunLog "REQUEST_GITHUB_UPLOAD_SUCCESS"
}

function Write-FailureResult([string]$warning) {
    if (-not $python -or -not $pendingFile) {
        return $false
    }
    $failureStdout = Join-Path $root "logs\request-failure-$runId.stdout.log"
    $failureStderr = Join-Path $root "logs\request-failure-$runId.stderr.log"
    $failure = Start-Process -FilePath $python `
        -ArgumentList @(
            (Assert-UnderRoot (Join-Path $root "scripts\request_worker.py")),
            "--root", $root,
            "--request", $pendingFile.FullName,
            "--write-failure",
            "--failure-status", "failed",
            "--warning", $warning
        ) `
        -WorkingDirectory $root `
        -WindowStyle Hidden `
        -RedirectStandardOutput $failureStdout `
        -RedirectStandardError $failureStderr `
        -Wait `
        -PassThru
    return ($failure.ExitCode -eq 0)
}

try {
    foreach ($path in @(
        $root,
        (Join-Path $root "data"),
        (Join-Path $root "data\tmp"),
        (Join-Path $root "logs"),
        (Join-Path $root "requests"),
        (Join-Path $root "requests\pending"),
        (Join-Path $root "requests\completed"),
        (Join-Path $root "requests\results")
    )) {
        Assert-UnderRoot $path | Out-Null
        New-Item -ItemType Directory -Force -Path $path | Out-Null
    }
    New-Item -ItemType Directory -Force -Path $runTemp | Out-Null
    Write-RequestRunLog "TASK_START run=$runId"

    $lockHelper = Assert-UnderRoot (Join-Path $root "scripts\project_lock.ps1")
    if (-not (Test-Path -LiteralPath $lockHelper)) {
        throw "project lock helper not found"
    }
    . $lockHelper
    $lockStream = Acquire-XHSProjectLock -Root $root
    if (-not $lockStream) {
        throw "LOCK_BUSY"
    }
    Write-RequestRunLog "LOCK_ACQUIRED path=data\xhs.lock"

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
    if (-not (Test-Path -LiteralPath (Join-Path $root ".git"))) {
        throw "local Git repository is not initialized"
    }

    $python = Get-Command python.exe -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty Source
    if (-not $python -and (Test-Path -LiteralPath "D:\Programs\Python\Python314\python.exe")) {
        $python = "D:\Programs\Python\Python314\python.exe"
    }
    if (-not $python) {
        throw "PYTHON_NOT_FOUND"
    }
    $workerPy = Assert-UnderRoot (Join-Path $root "scripts\request_worker.py")
    $mcpExe = Assert-UnderRoot (Join-Path $root "bin\xiaohongshu-mcp-windows-amd64.exe")
    if (-not (Test-Path -LiteralPath $workerPy)) {
        throw "request_worker.py not found"
    }
    if (-not (Test-Path -LiteralPath $mcpExe)) {
        throw "MCP executable not found"
    }

    $env:GIT_TERMINAL_PROMPT = "0"
    if (-not $SkipGit) {
        Invoke-GitPull
    }

    $pendingRoot = Assert-UnderRoot (Join-Path $root "requests\pending")
    $pendingFile = Get-ChildItem -LiteralPath $pendingRoot -Filter "*.json" -File |
        Sort-Object LastWriteTime, Name |
        Select-Object -First 1

    if (-not $pendingFile) {
        Write-RequestRunLog "NO_PENDING"
        if (-not $SkipGit) {
            Sync-RequestChanges "sync xhs request queue $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
        }
    } else {
        $resultPath = Join-Path $root "requests\results\$($pendingFile.Name)"
        $validationStdout = Join-Path $root "logs\request-validate-$runId.stdout.log"
        $validationStderr = Join-Path $root "logs\request-validate-$runId.stderr.log"
        Save-ProjectEnvironment

        $validation = Start-Process -FilePath $python `
            -ArgumentList @($workerPy, "--root", $root, "--request", $pendingFile.FullName, "--validate-only") `
            -WorkingDirectory $root `
            -WindowStyle Hidden `
            -RedirectStandardOutput $validationStdout `
            -RedirectStandardError $validationStderr `
            -Wait `
            -PassThru
        $validationPid = $validation.Id
        $validationExit = $validation.ExitCode
        $validationPid = $null

        if ($validationExit -eq 0) {
            $occupied = @(Get-NetTCPConnection -LocalAddress "127.0.0.1" -LocalPort 18060 -State Listen -ErrorAction SilentlyContinue)
            if ($occupied.Count -gt 0) {
                throw "PORT_BUSY"
            }

            Set-ProjectEnvironment
            $mcpStdout = Join-Path $root "logs\request-mcp-$runId.stdout.log"
            $mcpStderr = Join-Path $root "logs\request-mcp-$runId.stderr.log"
            $mcp = Start-Process -FilePath $mcpExe `
                -ArgumentList @("-headless=true", "-port", ":18060") `
                -WorkingDirectory $runTemp `
                -WindowStyle Hidden `
                -RedirectStandardOutput $mcpStdout `
                -RedirectStandardError $mcpStderr `
                -PassThru
            $mcpPid = $mcp.Id
            Write-RequestRunLog "MCP_START pid=$mcpPid port=18060 request=$($pendingFile.BaseName)"
            if (-not (Wait-ForTcpPort "127.0.0.1" 18060 60)) {
                $failureWarning = "MCP_START_FAILED"
                throw "MCP_START_FAILED"
            }

            $workerStdout = Join-Path $root "logs\request-worker-$runId.stdout.log"
            $workerStderr = Join-Path $root "logs\request-worker-$runId.stderr.log"
            $worker = Start-Process -FilePath $python `
                -ArgumentList @(
                    $workerPy,
                    "--root", $root,
                    "--request", $pendingFile.FullName,
                    "--mcp-url", "http://127.0.0.1:18060/mcp",
                    "--detail-timeout", "45"
                ) `
                -WorkingDirectory $root `
                -WindowStyle Hidden `
                -RedirectStandardOutput $workerStdout `
                -RedirectStandardError $workerStderr `
                -Wait `
                -PassThru
            $workerPid = $worker.Id
            $exitCode = $worker.ExitCode
            $workerPid = $null
            if ($exitCode -eq 0) {
                Write-RequestRunLog "REQUEST_WORKER_EXIT code=0 request=$($pendingFile.BaseName)"
            } else {
                Write-RequestRunLog "REQUEST_WORKER_EXIT code=$exitCode request=$($pendingFile.BaseName)"
            }
        } elseif ($validationExit -eq 10) {
            $exitCode = 10
            Write-RequestRunLog "INVALID_REQUEST request=$($pendingFile.BaseName)"
        } else {
            $failureWarning = "VALIDATION_FAILED"
            $exitCode = 22
            throw "VALIDATION_FAILED"
        }
    }
} catch {
    $message = $_.Exception.Message
    if ($message -eq "LOCK_BUSY") {
        Write-RequestRunLog "LOCK_BUSY"
        $exitCode = 24
    } elseif ($message -eq "GIT_PULL_FAILED") {
        Write-RequestRunLog "GIT_PULL_FAILED"
        $exitCode = 31
    } elseif ($message -eq "GIT_PUSH_FAILED") {
        Write-RequestRunLog "GIT_PUSH_FAILED"
        $exitCode = 30
    } elseif ($message -eq "PORT_BUSY") {
        $failureWarning = "MCP_PORT_BUSY"
        Write-RequestRunLog "MCP_PORT_BUSY"
        $exitCode = 22
    } else {
        if ($pendingFile -and -not $failureWarning) {
            $failureWarning = "WORKER_FAILED"
        }
        Write-RequestRunLog "RUN_FAILED reason=$message"
        if ($exitCode -eq 0) {
            $exitCode = 22
        }
    }
} finally {
    if ($validationPid) {
        Stop-ScopedProcessTree $validationPid $runTemp
    }
    if ($workerPid) {
        Stop-ScopedProcessTree $workerPid $runTemp
    }
    if ($mcpPid) {
        Stop-ScopedProcessTree $mcpPid $runTemp
        Write-RequestRunLog "MCP_STOP pid=$mcpPid"
    }
    Restore-ProjectEnvironment

    if ($pendingFile) {
        $resultPath = Join-Path $root "requests\results\$($pendingFile.Name)"
        if (-not (Test-Path -LiteralPath $resultPath) -and $failureWarning) {
            if (Write-FailureResult $failureWarning) {
                Write-RequestRunLog "FAILURE_RESULT_WRITTEN request=$($pendingFile.BaseName)"
            } else {
                Write-RequestRunLog "FAILURE_RESULT_WRITE_FAILED request=$($pendingFile.BaseName)"
            }
        }

        if (Test-Path -LiteralPath $resultPath) {
            $completedPath = Join-Path $root "requests\completed\$($pendingFile.Name)"
            if (Test-Path -LiteralPath $completedPath) {
                Remove-Item -LiteralPath $completedPath -Force
            }
            Move-Item -LiteralPath $pendingFile.FullName -Destination $completedPath -Force
            Write-RequestRunLog "REQUEST_MOVED pending=completed request=$($pendingFile.BaseName)"
            if (-not $SkipGit) {
                try {
                    $commitId = $pendingFile.BaseName -replace "[^A-Za-z0-9_-]", "_"
                    Sync-RequestChanges "complete xhs request $commitId $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
                } catch {
                    Write-RequestRunLog "REQUEST_GITHUB_UPLOAD_FAILED"
                    if ($exitCode -eq 0) {
                        $exitCode = 30
                    }
                }
            }
        } else {
            Write-RequestRunLog "REQUEST_NOT_MOVED result_missing request=$($pendingFile.BaseName)"
            if ($exitCode -eq 0) {
                $exitCode = 22
            }
        }
    }

    if ($lockStream) {
        $lockStream.Dispose()
        $lockStream = $null
        Write-RequestRunLog "LOCK_RELEASED"
    }
    Write-RequestRunLog "TASK_END code=$exitCode"
}

exit $exitCode
