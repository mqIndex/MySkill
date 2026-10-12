param(
    [ValidateSet('Pull', 'Push', 'Status')][string]$Mode = 'Pull',
    [string]$RepositoryPath = (Split-Path -Parent $PSScriptRoot),
    [string]$StateRoot = (Join-Path $env:LOCALAPPDATA 'MySkill-GPT'),
    [string]$Message = 'Update GPT skills',
    [switch]$Quiet
)
$ErrorActionPreference = 'Stop'
function Invoke-Git {
    param([string[]]$Arguments)
    $result = & git -C $RepositoryPath @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw ($result -join "`n") }
    return $result
}
New-Item -ItemType Directory -Path $StateRoot -Force | Out-Null
$lock = $null
try {
    $lock = [System.IO.File]::Open((Join-Path $StateRoot 'sync.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    if (!(Test-Path -LiteralPath (Join-Path $RepositoryPath '.git'))) { throw 'Not a Git checkout.' }
    if ($Mode -eq 'Status') {
        Invoke-Git -Arguments @('status', '--short', '--branch')
    } elseif ($Mode -eq 'Pull') {
        $dirty = Invoke-Git -Arguments @('status', '--porcelain')
        if ($dirty) { throw 'Local changes exist. Run Sync-Skills.ps1 -Mode Push after reviewing them; automatic pull was skipped.' }
        Invoke-Git -Arguments @('-c', 'credential.interactive=never', 'pull', '--ff-only')
        if (!$Quiet) { Write-Host 'GPT skills updated. Restart the client if changes are not visible.' }
    } else {
        # Refuse to accidentally include previously staged files outside GPT.
        $staged = Invoke-Git -Arguments @('diff', '--cached', '--name-only')
        foreach ($item in $staged) {
            if ($item -and $item -notlike 'GPT/*') { throw "Unrelated staged file: $item" }
        }
        Invoke-Git -Arguments @('add', '--', 'GPT') | Out-Null
        $changes = Invoke-Git -Arguments @('diff', '--cached', '--name-only', '--', 'GPT')
        if ($changes) { Invoke-Git -Arguments @('commit', '-m', $Message, '--', 'GPT') }
        # Fetch/fast-forward before push; concurrent changes stop safely.
        Invoke-Git -Arguments @('pull', '--ff-only')
        Invoke-Git -Arguments @('push')
    }
    Add-Content -LiteralPath (Join-Path $StateRoot 'sync.log') -Value "$(Get-Date -Format o) $Mode OK" -Encoding utf8
} catch {
    Add-Content -LiteralPath (Join-Path $StateRoot 'sync.log') -Value "$(Get-Date -Format o) $Mode ERROR: $($_.Exception.Message)" -Encoding utf8
    if (!$Quiet) { Write-Error $_ }
    exit 1
} finally {
    if ($lock) { $lock.Dispose() }
}
