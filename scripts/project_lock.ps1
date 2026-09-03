function Acquire-XHSProjectLock {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $rootPath = [IO.Path]::GetFullPath($Root)
    $dataPath = Join-Path $rootPath "data"
    New-Item -ItemType Directory -Force -Path $dataPath | Out-Null
    $lockPath = Join-Path $dataPath "xhs.lock"

    try {
        return [IO.File]::Open(
            $lockPath,
            [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None
        )
    } catch [IO.IOException] {
        return $null
    }
}
