$ErrorActionPreference = "Stop"
$root = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$taskName = "XHSCollector-LoginCheck"
$runScript = Join-Path $root "scripts\run_login_check.ps1"
$powershellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"

if (-not (Test-Path -LiteralPath $runScript)) {
    throw "run_login_check.ps1 not found"
}

$action = New-ScheduledTaskAction `
    -Execute $powershellExe `
    -Argument "-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$runScript`"" `
    -WorkingDirectory $root

$startAt = (Get-Date).Date.AddDays(1).AddHours(7)
$trigger = New-ScheduledTaskTrigger `
    -Once `
    -At $startAt `
    -RepetitionInterval (New-TimeSpan -Days 2) `
    -RepetitionDuration (New-TimeSpan -Days 3650)

$settings = New-ScheduledTaskSettingsSet `
    -Hidden `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 30) `
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
    -Description "Read-only Xiaohongshu login status check" `
    -Force | Out-Null

Write-Host "Enter the Windows account password for $userId. Do not use a PIN."
& schtasks.exe /Change /TN $taskName /RU $userId /RP *
if ($LASTEXITCODE -ne 0) {
    throw "could not save the task credentials"
}

$task = Get-ScheduledTask -TaskName $taskName
$info = Get-ScheduledTaskInfo -TaskName $taskName
[pscustomobject]@{
    TaskName = $task.TaskName
    State = $task.State
    LogonType = $task.Principal.LogonType
    NextRun = $info.NextRunTime
    Action = $task.Actions[0].Execute
    Arguments = $task.Actions[0].Arguments
    WakeToRun = $task.Settings.WakeToRun
    MultipleInstances = $task.Settings.MultipleInstances
} | Format-List
