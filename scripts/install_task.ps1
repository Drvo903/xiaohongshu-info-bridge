$ErrorActionPreference = "Stop"
$root = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$taskName = "XHSCollector-Workday"
$runScript = Join-Path $root "scripts\run_collector.ps1"
$powershellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"

if (-not (Test-Path -LiteralPath $runScript)) {
    throw "run_collector.ps1 not found"
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
    -Argument "-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$runScript`""

$triggers = @(
    (New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday,Tuesday,Wednesday,Thursday,Friday -At "09:30"),
    (New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday,Tuesday,Wednesday,Thursday,Friday -At "13:30"),
    (New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday,Tuesday,Wednesday,Thursday,Friday -At "16:30")
)

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Hours 2) `
    -RestartCount 1 `
    -RestartInterval (New-TimeSpan -Minutes 30)

$userId = "$env:USERDOMAIN\$env:USERNAME"
$principal = New-ScheduledTaskPrincipal `
    -UserId $userId `
    -LogonType Interactive `
    -RunLevel Limited

Register-ScheduledTask `
    -TaskName $taskName `
    -Action $action `
    -Trigger $triggers `
    -Settings $settings `
    -Principal $principal `
    -Description "Read-only Xiaohongshu public-feed collection and GitHub sync" `
    -Force | Out-Null

$task = Get-ScheduledTask -TaskName $taskName
[pscustomobject]@{
    TaskName = $task.TaskName
    State = $task.State
    Action = $task.Actions[0].Execute
    Arguments = $task.Actions[0].Arguments
    TriggerCount = @($task.Triggers).Count
    User = $userId
} | Format-List
