param(
    [string]$RepositoryUrl = 'https://github.com/mqIndex/MySkill.git',
    [string]$RepositoryPath = (Join-Path $env:USERPROFILE 'MySkill'),
    [string]$SkillsRoot = (Join-Path $env:USERPROFILE '.agents\skills'),
    [string]$LegacySkillsRoot = (Join-Path $env:USERPROFILE '.codex\skills'),
    [string]$StateRoot = (Join-Path $env:LOCALAPPDATA 'MySkill-GPT'),
    [switch]$Publish,
    [switch]$NoScheduledTask
)
$ErrorActionPreference = 'Stop'
function Invoke-Git {
    param([string[]]$Arguments)
    $result = & git -C $RepositoryPath @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw ($result -join "`n") }
    return $result
}
function Get-TreeDigest {
    param([string]$Directory)
    $base = (Get-Item -LiteralPath $Directory).FullName
    $entries = @(Get-ChildItem -LiteralPath $base -File -Recurse -Force | Sort-Object FullName | ForEach-Object {
        $relative = $_.FullName.Substring($base.Length)
        $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
        # Permit migration of the old memory skill when its only difference is
        # our stricter explicit-invocation policy; keep every other byte checked.
        if ((Split-Path -Leaf $base) -eq 'sync-claude-memory' -and $relative.Replace('\', '/') -eq '/agents/openai.yaml') {
            $text = [System.IO.File]::ReadAllText($_.FullName).Replace('allow_implicit_invocation: true', 'allow_implicit_invocation: false')
            $digest = [System.Security.Cryptography.SHA256]::Create()
            try { $hash = [System.BitConverter]::ToString($digest.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text))).Replace('-', '') } finally { $digest.Dispose() }
        }
        $relative + ':' + $hash
    })
    return ($entries -join "`n")
}
function Is-LinkedTo {
    param([string]$Path, [string]$Target)
    if (!(Test-Path -LiteralPath $Path)) { return $false }
    $item = Get-Item -LiteralPath $Path -Force
    return (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -and
        (@($item.Target) -contains $Target))
}
try {
    Get-Command git -ErrorAction Stop | Out-Null
    $RepositoryPath = [System.IO.Path]::GetFullPath($RepositoryPath)
    if (!(Test-Path -LiteralPath (Join-Path $RepositoryPath '.git'))) {
        if (Test-Path -LiteralPath $RepositoryPath) { throw "Destination already exists without a Git checkout: $RepositoryPath" }
        & git clone $RepositoryUrl $RepositoryPath
        if ($LASTEXITCODE -ne 0) { throw 'Clone failed. Check GitHub access and Git credentials.' }
    }
    $actualRemote = [string](Invoke-Git -Arguments @('remote', 'get-url', 'origin'))
    if ($actualRemote.TrimEnd('/') -ne $RepositoryUrl.TrimEnd('/')) { throw "Unexpected origin: $actualRemote" }
    if (Invoke-Git -Arguments @('status', '--porcelain')) { throw 'Checkout contains local changes. Review them first.' }
    Invoke-Git -Arguments @('pull', '--ff-only')
    $source = if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'GPT')) { Join-Path $PSScriptRoot 'GPT' } else { $PSScriptRoot }
    $destination = Join-Path $RepositoryPath 'GPT'
    if ([System.IO.Path]::GetFullPath($source) -ne [System.IO.Path]::GetFullPath($destination)) {
        # Preflight the whole payload before copying any file.
        foreach ($file in Get-ChildItem -LiteralPath $source -File -Recurse -Force) {
            $relative = $file.FullName.Substring($source.Length).TrimStart('\', '/')
            $target = Join-Path $destination $relative
            if (Test-Path -LiteralPath $target) {
                if ((Get-FileHash -LiteralPath $target).Hash -ne (Get-FileHash -LiteralPath $file.FullName).Hash) {
                    throw "Repository already has a different version of GPT/$relative. Compare the versions before retrying."
                }
            }
        }
        New-Item -ItemType Directory -Path $destination -Force | Out-Null
        foreach ($file in Get-ChildItem -LiteralPath $source -File -Recurse -Force) {
            $relative = $file.FullName.Substring($source.Length).TrimStart('\', '/')
            $target = Join-Path $destination $relative
            New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
            Copy-Item -LiteralPath $file.FullName -Destination $target -Force
        }
    }
    $syncScript = Join-Path $destination 'Sync-Skills.ps1'
    if ($Publish) {
        & $syncScript -Mode Push -RepositoryPath $RepositoryPath -StateRoot $StateRoot -Message 'Add GPT skills and Windows sync configuration'
        if (!$?) { throw 'Publish failed; installation stopped.' }
    } elseif (Invoke-Git -Arguments @('status', '--porcelain')) {
        throw 'GPT payload is uncommitted. Run Setup-GPT-Skills.ps1 -Publish to upload it first.'
    }
    $skillDirs = @(Get-ChildItem -LiteralPath $destination -Directory | Where-Object {
        Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md')
    })
    if (!$skillDirs.Count) { throw 'No GPT skills found.' }
    $backupRoot = Join-Path $StateRoot ('backups\' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
    # Validate all existing installations before moving anything.
    foreach ($skill in $skillDirs) {
        foreach ($root in @($SkillsRoot, $LegacySkillsRoot) | Select-Object -Unique) {
            $installed = Join-Path $root $skill.Name
            if ((Test-Path -LiteralPath $installed) -and !(Is-LinkedTo -Path $installed -Target $skill.FullName)) {
                $item = Get-Item -LiteralPath $installed -Force
                if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { throw "Existing link points elsewhere: $installed" }
                if ((Get-TreeDigest $installed) -ne (Get-TreeDigest $skill.FullName)) {
                    throw "Local skill differs from repository: $installed. Preserve and compare local changes before installing."
                }
            }
        }
    }
    New-Item -ItemType Directory -Path $SkillsRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $StateRoot -Force | Out-Null
    foreach ($skill in $skillDirs) {
        foreach ($root in @($SkillsRoot, $LegacySkillsRoot) | Select-Object -Unique) {
            $installed = Join-Path $root $skill.Name
            if ((Test-Path -LiteralPath $installed) -and !(Is-LinkedTo -Path $installed -Target $skill.FullName)) {
                # Both absolute move paths are checked to stay under their named roots.
                $rootFull = [System.IO.Path]::GetFullPath($root).TrimEnd('\') + '\'
                $installedFull = [System.IO.Path]::GetFullPath($installed)
                if (!$installedFull.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid installed path.' }
                $label = if ($root -eq $SkillsRoot) { 'agents' } else { 'codex' }
                $backup = Join-Path (Join-Path $backupRoot $label) $skill.Name
                $backupFull = [System.IO.Path]::GetFullPath($backup)
                if (!$backupFull.StartsWith([System.IO.Path]::GetFullPath($backupRoot).TrimEnd('\') + '\', [System.StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid backup path.' }
                New-Item -ItemType Directory -Path (Split-Path -Parent $backup) -Force | Out-Null
                Move-Item -LiteralPath $installedFull -Destination $backupFull
                @{original=$installedFull;backup=$backupFull} | ConvertTo-Json -Compress | Add-Content -LiteralPath (Join-Path $StateRoot 'backups.jsonl') -Encoding utf8
            }
        }
        $link = Join-Path $SkillsRoot $skill.Name
        if (!(Is-LinkedTo -Path $link -Target $skill.FullName)) {
            New-Item -ItemType Junction -Path $link -Target $skill.FullName | Out-Null
        }
    }
    if (!$NoScheduledTask) {
        $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $taskArguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $syncScript + '" -Mode Pull -StateRoot "' + $StateRoot + '" -Quiet'
        $action = New-ScheduledTaskAction -Execute $windowsPowerShell -Argument $taskArguments
        $logon = New-ScheduledTaskTrigger -AtLogOn -User ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)
        $repeat = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) -RepetitionInterval (New-TimeSpan -Minutes 30)
        $principal = New-ScheduledTaskPrincipal -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Register-ScheduledTask -TaskName 'MySkill-GPT-Sync' -Action $action -Trigger @($logon, $repeat) -Principal $principal -Settings $settings -Description 'Pull clean MySkill checkout and share GPT skills with local Codex clients.' -Force | Out-Null
    }
    Write-Host "Installed $($skillDirs.Count) skills from $destination"
    Write-Host "Skills root: $SkillsRoot"
    Write-Host "Backups and logs: $StateRoot"
    if (!$NoScheduledTask) { Write-Host 'Automatic pull: on logon and every 30 minutes while logged in.' }
    Write-Host 'Restart ChatGPT/Codex. Upload local edits explicitly with GPT\Sync-Skills.ps1 -Mode Push.'
} catch {
    Write-Error $_
    exit 1
}
