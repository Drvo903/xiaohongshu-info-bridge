$ErrorActionPreference = "Stop"
$root = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$taskName = "XHSCollector-RequestWorker"
$runScript = Join-Path $root "scripts\run_request_worker.ps1"
$powershellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"

if (-not (Test-Path -LiteralPath $runScript)) {
    throw "run_request_worker.ps1 not found"
}
if (-not (Test-Path -LiteralPath $powershellExe)) {
    throw "Windows PowerShell executable not found"
}

$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existing) {
    $existingAction = @($existing.Actions | Select-Object -First 1)
    if (-not $existingAction -or
        $existingAction.Execute -ne $powershellExe -or
        $existingAction.Arguments -notlike "*$runScript*") {
        throw "a different scheduled task already uses the name $taskName"
    }
}

$action = New-ScheduledTaskAction `
    -Execute $powershellExe `
    -Argument "-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$runScript`"" `
    -WorkingDirectory $root

$now = Get-Date
$candidate = $now.AddMinutes(1)
$nextQuarter = [int]([Math]::Ceiling($candidate.Minute / 15.0) * 15)
if ($nextQuarter -ge 60) {
    $startAt = Get-Date -Year $candidate.Year -Month $candidate.Month -Day $candidate.Day `
        -Hour $candidate.Hour -Minute 0 -Second 0
    $startAt = $startAt.AddHours(1)
} else {
    $startAt = Get-Date -Year $candidate.Year -Month $candidate.Month -Day $candidate.Day `
        -Hour $candidate.Hour -Minute $nextQuarter -Second 0
}

$trigger = New-ScheduledTaskTrigger `
    -Once `
    -At $startAt `
    -RepetitionInterval (New-TimeSpan -Minutes 15) `
    -RepetitionDuration (New-TimeSpan -Days 3650)

$settings = New-ScheduledTaskSettingsSet `
    -Hidden `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Hours 1) `
    -RestartCount 0

$userId = "$env:USERDOMAIN\$env:USERNAME"
$principal = New-ScheduledTaskPrincipal `
    -UserId $userId `
    -LogonType Interactive `
    -RunLevel Limited

Register-ScheduledTask `
    -TaskName $taskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $principal `
    -Description "Process at most one read-only Xiaohongshu search request from GitHub" `
    -Force | Out-Null

$task = Get-ScheduledTask -TaskName $taskName
$info = Get-ScheduledTaskInfo -TaskName $taskName
[pscustomobject]@{
    TaskName = $task.TaskName
    State = $task.State
    FirstRun = $startAt
    NextRun = $info.NextRunTime
    Action = $task.Actions[0].Execute
    Arguments = $task.Actions[0].Arguments
    User = $userId
} | Format-List
