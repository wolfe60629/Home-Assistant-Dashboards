<#
.SYNOPSIS
  Pull or push Home Assistant configuration, YAML artifacts (automations/scripts/scenes), and Lovelace storage via SSH.

.DESCRIPTION
  Reads ha-sync.config.json next to this script (or use -ConfigPath).
  End-to-end process: README.md and docs/WORKFLOW.md. Convenience launchers: scripts/*.cmd.
  Requires OpenSSH client (ssh) on PATH — built into Windows 10+.
  By default uses non-interactive SSH (BatchMode=yes): install your public key on the Pi
  and set SshIdentityFile, or place a key at .ssh\id_ed25519 or .ssh\id_rsa under your profile.
  Use -AllowPasswordPrompt for an interactive password (not suitable for Cursor automation).
  With LovelaceStorage.Enabled, syncs JSON files in /config/.storage whose names start with
  "lovelace" (UI dashboards: lovelace, lovelace_resources, lovelace.dashboard_*).
  With AssistantContextStorage.Enabled, pulls a fixed list of .storage JSON files (device/entity
  registries, config entries, areas, labels) into a separate local folder for tooling and AI
  context — pull-only; never pushed back to the server.
  YamlArtifacts lists extra /config/*.yaml files (default: automations, scripts, scenes).
  PullDev streams the entire remote DevMirror.RemoteConfigDir (default /config) from the HA
  container into DevMirror.LocalRelativeDir (default dev/ha-config) for the Docker dev instance.

.EXAMPLE
  .\Sync-HaConfig.ps1 Pull
  .\Sync-HaConfig.ps1 Push
  .\Sync-HaConfig.ps1 PullDev
  .\Sync-HaConfig.ps1 PullDev -ExcludeDatabase
  .\Sync-HaConfig.ps1 Pull -Scope Lovelace
  .\Sync-HaConfig.ps1 Pull -Scope Artifacts
  .\Sync-HaConfig.ps1 Pull -Scope Context
  .\Sync-HaConfig.ps1 Pull -ConfigPath C:\path\to\ha-sync.config.json
  .\Sync-HaConfig.ps1 Pull -AllowPasswordPrompt
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('Pull', 'Push', 'PullDev')]
    [string]$Action,

    [ValidateSet('All', 'Config', 'Lovelace', 'Artifacts', 'Context')]
    [string]$Scope = 'All',

    [string]$ConfigPath = '',

    [switch]$AllowPasswordPrompt,

    # PullDev only: omit recorder DB (smaller/faster; integrations still load from .storage)
    [switch]$ExcludeDatabase
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    $PSScriptRoot
} else {
    [System.IO.Path]::GetDirectoryName($MyInvocation.MyCommand.Path)
}
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $scriptRoot 'ha-sync.config.json'
}

function Get-OpenSshPath {
    $ssh = Get-Command ssh -ErrorAction SilentlyContinue
    if (-not $ssh) {
        throw 'OpenSSH client (ssh) not found. Install "OpenSSH Client" optional feature or add ssh to PATH.'
    }
    return $ssh.Source
}

function Read-Config([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Config file not found: $path`nCopy ha-sync.config.example.json to ha-sync.config.json and edit."
    }
    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    $c = $raw | ConvertFrom-Json
    foreach ($key in @('SshHost', 'SshUser', 'DockerContainer', 'RemoteConfigPath', 'LocalRelativePath')) {
        if ((-not ($c.PSObject.Properties.Name -contains $key)) -or [string]::IsNullOrWhiteSpace($c.$key)) {
            throw "Config missing or empty required key: $key"
        }
    }
    if (-not $c.SshPort) { $c | Add-Member -NotePropertyName SshPort -NotePropertyValue 22 -Force }
    if ($null -eq $c.BackupOnPush) { $c | Add-Member -NotePropertyName BackupOnPush -NotePropertyValue $true -Force }
    if (-not ($c.PSObject.Properties.Name -contains 'SshIdentityFile')) {
        $c | Add-Member -NotePropertyName SshIdentityFile -NotePropertyValue '' -Force
    }
    if (-not ($c.PSObject.Properties.Name -contains 'SshBatchMode')) {
        $c | Add-Member -NotePropertyName SshBatchMode -NotePropertyValue $true -Force
    }
    if (-not ($c.PSObject.Properties.Name -contains 'SshStrictHostKeyChecking')) {
        $c | Add-Member -NotePropertyName SshStrictHostKeyChecking -NotePropertyValue 'accept-new' -Force
    }
    $c.SshIdentityFile = Resolve-SshIdentityPath ([string]$c.SshIdentityFile)
    if ($c.SshIdentityFile -and -not [string]::IsNullOrWhiteSpace([string]$c.SshIdentityFile)) {
        if (-not (Test-Path -LiteralPath $c.SshIdentityFile)) {
            throw "SshIdentityFile not found: $($c.SshIdentityFile)"
        }
    }
    if (-not ($c.PSObject.Properties.Name -contains 'LovelaceStorage') -or ($null -eq $c.LovelaceStorage)) {
        $c | Add-Member -NotePropertyName LovelaceStorage -NotePropertyValue ([pscustomobject]@{
                Enabled            = $false
                RemoteStorageDir   = '/config/.storage'
                LocalRelativeDir   = '.storage'
            }) -Force
    } else {
        $ls = $c.LovelaceStorage
        if (-not ($ls.PSObject.Properties.Name -contains 'Enabled')) {
            $ls | Add-Member -NotePropertyName Enabled -NotePropertyValue $false -Force
        }
        if (-not ($ls.PSObject.Properties.Name -contains 'RemoteStorageDir') -or [string]::IsNullOrWhiteSpace([string]$ls.RemoteStorageDir)) {
            $ls | Add-Member -NotePropertyName RemoteStorageDir -NotePropertyValue '/config/.storage' -Force
        }
        if (-not ($ls.PSObject.Properties.Name -contains 'LocalRelativeDir') -or [string]::IsNullOrWhiteSpace([string]$ls.LocalRelativeDir)) {
            $ls | Add-Member -NotePropertyName LocalRelativeDir -NotePropertyValue '.storage' -Force
        }
    }
    $defaultContextFiles = @(
        'core.device_registry'
        'core.entity_registry'
        'core.config_entries'
        'core.area_registry'
        'core.label_registry'
    )
    if (-not ($c.PSObject.Properties.Name -contains 'AssistantContextStorage') -or ($null -eq $c.AssistantContextStorage)) {
        $c | Add-Member -NotePropertyName AssistantContextStorage -NotePropertyValue ([pscustomobject]@{
                Enabled          = $false
                RemoteStorageDir = '/config/.storage'
                LocalRelativeDir = '.ha-assistant-context'
                Files            = $defaultContextFiles
            }) -Force
    } else {
        $acs = $c.AssistantContextStorage
        if (-not ($acs.PSObject.Properties.Name -contains 'Enabled')) {
            $acs | Add-Member -NotePropertyName Enabled -NotePropertyValue $false -Force
        }
        if (-not ($acs.PSObject.Properties.Name -contains 'RemoteStorageDir') -or [string]::IsNullOrWhiteSpace([string]$acs.RemoteStorageDir)) {
            $acs | Add-Member -NotePropertyName RemoteStorageDir -NotePropertyValue '/config/.storage' -Force
        }
        if (-not ($acs.PSObject.Properties.Name -contains 'LocalRelativeDir') -or [string]::IsNullOrWhiteSpace([string]$acs.LocalRelativeDir)) {
            $acs | Add-Member -NotePropertyName LocalRelativeDir -NotePropertyValue '.ha-assistant-context' -Force
        }
        if (-not ($acs.PSObject.Properties.Name -contains 'Files') -or ($null -eq $acs.Files)) {
            $acs | Add-Member -NotePropertyName Files -NotePropertyValue $defaultContextFiles -Force
        }
        $fnames = @($acs.Files | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ })
        if ($fnames.Count -eq 0) {
            $acs.Files = $defaultContextFiles
        }
        foreach ($fn in @($acs.Files)) {
            $n = [string]$fn
            if ([string]::IsNullOrWhiteSpace($n)) { continue }
            if ($n -match '[/\\]' -or $n -match '\.\.') {
                throw "AssistantContextStorage.Files entry must be a plain basename (no path segments): $n"
            }
        }
    }
    if (-not ($c.PSObject.Properties.Name -contains 'DevMirror') -or ($null -eq $c.DevMirror)) {
        $c | Add-Member -NotePropertyName DevMirror -NotePropertyValue ([pscustomobject]@{
                LocalRelativeDir  = 'dev/ha-config'
                RemoteConfigDir   = '/config'
            }) -Force
    } else {
        $dm = $c.DevMirror
        if (-not ($dm.PSObject.Properties.Name -contains 'LocalRelativeDir') -or [string]::IsNullOrWhiteSpace([string]$dm.LocalRelativeDir)) {
            $dm | Add-Member -NotePropertyName LocalRelativeDir -NotePropertyValue 'dev/ha-config' -Force
        }
        if (-not ($dm.PSObject.Properties.Name -contains 'RemoteConfigDir') -or [string]::IsNullOrWhiteSpace([string]$dm.RemoteConfigDir)) {
            $dm | Add-Member -NotePropertyName RemoteConfigDir -NotePropertyValue '/config' -Force
        }
    }
    if (-not ($c.PSObject.Properties.Name -contains 'YamlArtifacts') -or ($null -eq $c.YamlArtifacts)) {
        $defaultYaml = @(
            [pscustomobject]@{ RemotePath = '/config/automations.yaml'; LocalRelativePath = 'automations.yaml' }
            [pscustomobject]@{ RemotePath = '/config/scripts.yaml'; LocalRelativePath = 'scripts.yaml' }
            [pscustomobject]@{ RemotePath = '/config/scenes.yaml'; LocalRelativePath = 'scenes.yaml' }
        )
        $c | Add-Member -NotePropertyName YamlArtifacts -NotePropertyValue $defaultYaml -Force
    } else {
        foreach ($a in @($c.YamlArtifacts)) {
            if ((-not ($a.PSObject.Properties.Name -contains 'RemotePath')) -or [string]::IsNullOrWhiteSpace([string]$a.RemotePath)) {
                throw 'Each YamlArtifacts entry must include a non-empty RemotePath.'
            }
            if ((-not ($a.PSObject.Properties.Name -contains 'LocalRelativePath')) -or [string]::IsNullOrWhiteSpace([string]$a.LocalRelativePath)) {
                throw 'Each YamlArtifacts entry must include a non-empty LocalRelativePath.'
            }
        }
    }
    return $c
}

function Resolve-SshIdentityPath([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path)) { return '' }
    $t = $path.Trim()
    if ($t.StartsWith('~/') -or $t.StartsWith('~\')) {
        return Join-Path $HOME $t.Substring(2)
    }
    return $t
}

function Discover-DefaultSshKey {
    $sshDir = Join-Path $env:USERPROFILE '.ssh'
    foreach ($name in @('id_ed25519', 'id_ecdsa', 'id_rsa')) {
        $p = Join-Path $sshDir $name
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return ''
}

function Apply-IdentityDiscovery($cfg) {
    if ($cfg.SshIdentityFile -and -not [string]::IsNullOrWhiteSpace([string]$cfg.SshIdentityFile)) { return }
    $found = Discover-DefaultSshKey
    if ($found) {
        $cfg.SshIdentityFile = $found
        Write-Host "Using discovered SSH key: $found" -ForegroundColor DarkGray
    }
}

function Build-SshTarget($cfg, [bool]$allowPasswordPrompt) {
    $port = [int]$cfg.SshPort
    if ($port -le 0 -or $port -gt 65535) { throw "Invalid SshPort: $($cfg.SshPort)" }
    $identityArg = @()
    if ($cfg.SshIdentityFile -and -not [string]::IsNullOrWhiteSpace([string]$cfg.SshIdentityFile)) {
        $identityArg = @('-i', [string]$cfg.SshIdentityFile)
    }
    $opts = @()
    if ($cfg.SshBatchMode -and -not $allowPasswordPrompt) {
        $opts += '-o', 'BatchMode=yes'
    }
    $hk = [string]$cfg.SshStrictHostKeyChecking
    if (-not [string]::IsNullOrWhiteSpace($hk)) {
        $opts += '-o', "StrictHostKeyChecking=$hk"
    }
    return @{
        Target = "$($cfg.SshUser)@$($cfg.SshHost)"
        IdentityArg = $identityArg
        SshOpts = $opts
        PortArg = @('-p', ([string]$port))
    }
}

function Invoke-SshRemote([string]$sshExe, [string[]]$sshOpts, [string[]]$identityArg, [string[]]$portArg, [string]$target, [string]$remoteCommand) {
    $allArgs = @()
    $allArgs += $sshOpts
    $allArgs += $identityArg
    $allArgs += $portArg
    $allArgs += $target
    $allArgs += $remoteCommand
    & $sshExe @allArgs
}

function Ensure-HaRemotePathHasNoSingleQuote([string]$path, [string]$label) {
    if ($path -match "'") {
        throw "$label cannot contain single quotes: $path"
    }
}

function Get-YamlArtifactBackupFlag($artifact, $cfg) {
    if ($artifact.PSObject.Properties.Name -contains 'BackupOnPush' -and ($null -ne $artifact.BackupOnPush)) {
        return [bool]$artifact.BackupOnPush
    }
    return [bool]$cfg.BackupOnPush
}

function Join-RemoteUnixPath([string]$directory, [string]$fileName) {
    $base = ([string]$directory).TrimEnd('/')
    return "$base/$fileName"
}

function Get-SshFailureMessage($exitCode, $cfg, [bool]$allowPasswordPrompt) {
    $code = if ($null -eq $exitCode) { 'unknown' } else { "$exitCode" }
    $msg = "ssh failed (exit $code). "
    if ($cfg.SshBatchMode -and -not $allowPasswordPrompt) {
        $msg += "Non-interactive mode (BatchMode=yes) cannot prompt for a password. "
        $msg += "Install your public key in ~/.ssh/authorized_keys on the Pi (same user as SshUser), "
        $msg += "or set SshIdentityFile in ha-sync.config.json to the matching private key "
        $msg += "(or leave it empty to auto-pick id_ed25519 / id_ecdsa / id_rsa under your user profile). "
        $msg += "For a one-off interactive login, run with -AllowPasswordPrompt."
    } else {
        $msg += "Check SSH connectivity, user, port, and Docker permissions on the remote host."
    }
    return $msg
}

function Get-LovelaceStorageBasenames {
    param(
        [string]$sshExe,
        [hashtable]$ssh,
        $cfg
    )
    $dir = [string]$cfg.LovelaceStorage.RemoteStorageDir
    Ensure-HaRemotePathHasNoSingleQuote $dir 'LovelaceStorage.RemoteStorageDir'
    $remoteCmd = "docker exec $($cfg.DockerContainer) ls -1 $dir"
    $out = Invoke-SshRemote $sshExe $ssh.SshOpts $ssh.IdentityArg $ssh.PortArg $ssh.Target $remoteCmd
    if ($LASTEXITCODE -ne 0) {
        throw "Could not list remote storage dir $dir (ssh exit $LASTEXITCODE)."
    }
    $lines = @()
    if ($null -ne $out) {
        if ($out -is [array]) { $lines = $out } else { $lines = @($out) }
    }
    return $lines | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ -and ($_ -match '^lovelace') }
}

function Pull-LovelaceStorageFiles {
    param(
        [string]$sshExe,
        [hashtable]$ssh,
        $cfg,
        [string]$LocalRepoRoot
    )
    $ls = $cfg.LovelaceStorage
    $localDir = Join-Path $LocalRepoRoot ([string]$ls.LocalRelativeDir)
    New-Item -ItemType Directory -Path $localDir -Force | Out-Null
    $names = @(Get-LovelaceStorageBasenames -sshExe $sshExe -ssh $ssh -cfg $cfg)
    if ($names.Count -eq 0) {
        Write-Host "No Lovelace storage files found in $($ls.RemoteStorageDir) (names starting with 'lovelace')." -ForegroundColor DarkYellow
        return
    }
    $enc = [System.Text.UTF8Encoding]::new($false)
    foreach ($name in $names) {
        if ($name -match '[/\\]') { continue }
        $remotePath = Join-RemoteUnixPath $ls.RemoteStorageDir $name
        Ensure-HaRemotePathHasNoSingleQuote $remotePath 'Lovelace remote path'
        $remoteCmd = "docker exec $($cfg.DockerContainer) cat $remotePath"
        $fileOut = Invoke-SshRemote $sshExe $ssh.SshOpts $ssh.IdentityArg $ssh.PortArg $ssh.Target $remoteCmd
        if ($LASTEXITCODE -ne 0) {
            throw (Get-SshFailureMessage $LASTEXITCODE $cfg ([bool]$AllowPasswordPrompt))
        }
        $text = if ($null -eq $fileOut) { '' } elseif ($fileOut -is [array]) { ($fileOut | ForEach-Object { $_.ToString() }) -join "`n" } else { $fileOut.ToString() }
        if (-not $text.EndsWith("`n")) { $text += "`n" }
        $localPath = Join-Path $localDir $name
        [System.IO.File]::WriteAllText($localPath, $text, $enc)
        Write-Host "  Pulled Lovelace: $name" -ForegroundColor Green
    }
    Write-Host "Lovelace storage pulled to: $localDir" -ForegroundColor Green
}

function Pull-AssistantContextStorageFiles {
    param(
        [string]$sshExe,
        [hashtable]$ssh,
        $cfg,
        [string]$LocalRepoRoot
    )
    $acs = $cfg.AssistantContextStorage
    $dir = [string]$acs.RemoteStorageDir
    Ensure-HaRemotePathHasNoSingleQuote $dir 'AssistantContextStorage.RemoteStorageDir'
    $localDir = Join-Path $LocalRepoRoot ([string]$acs.LocalRelativeDir)
    New-Item -ItemType Directory -Path $localDir -Force | Out-Null
    $names = @($acs.Files | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ })
    if ($names.Count -eq 0) {
        Write-Host 'AssistantContextStorage.Files is empty; nothing to pull.' -ForegroundColor DarkYellow
        return
    }
    $enc = [System.Text.UTF8Encoding]::new($false)
    foreach ($name in $names) {
        if ($name -match '[/\\]') { continue }
        $remotePath = Join-RemoteUnixPath $dir $name
        Ensure-HaRemotePathHasNoSingleQuote $remotePath 'Assistant context remote path'
        $remoteCmd = "docker exec $($cfg.DockerContainer) cat $remotePath"
        $fileOut = Invoke-SshRemote $sshExe $ssh.SshOpts $ssh.IdentityArg $ssh.PortArg $ssh.Target $remoteCmd
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  Skipped (missing or unreadable on server): $name" -ForegroundColor DarkYellow
            continue
        }
        $text = if ($null -eq $fileOut) { '' } elseif ($fileOut -is [array]) { ($fileOut | ForEach-Object { $_.ToString() }) -join "`n" } else { $fileOut.ToString() }
        if (-not $text.EndsWith("`n")) { $text += "`n" }
        $localPath = Join-Path $localDir $name
        [System.IO.File]::WriteAllText($localPath, $text, $enc)
        Write-Host "  Pulled assistant context: $name" -ForegroundColor Green
    }
    Write-Host "Assistant context pulled to: $localDir" -ForegroundColor Green
}

function Invoke-PullDevFullConfigFromProd {
    param(
        [string]$SshExe,
        [hashtable]$Ssh,
        $Cfg,
        [string]$RepoRoot,
        [bool]$ExcludeDatabase,
        [bool]$AllowPasswordPrompt
    )
    $dm = $Cfg.DevMirror
    $remoteRoot = [string]$dm.RemoteConfigDir
    Ensure-HaRemotePathHasNoSingleQuote $remoteRoot 'DevMirror.RemoteConfigDir'
    $devPath = [System.IO.Path]::GetFullPath((Join-Path $RepoRoot ([string]$dm.LocalRelativeDir)))

    Write-Host ''
    Write-Host 'Before unpacking: stop the local dev container (avoids locked files on Windows):' -ForegroundColor DarkYellow
    Write-Host '  cd dev' -ForegroundColor White
    Write-Host '  docker compose down' -ForegroundColor White
    Write-Host ''

    # BusyBox tar in HA containers is picky about flag order; use cd + tar instead of -C.
    if ($ExcludeDatabase) {
        Write-Host 'Excluding home-assistant_v2.db (+ wal/shm) from the archive.' -ForegroundColor DarkYellow
        $tarInner = "cd $remoteRoot && tar cf - --exclude=home-assistant_v2.db --exclude=home-assistant_v2.db-wal --exclude=home-assistant_v2.db-shm ."
    } else {
        $tarInner = "cd $remoteRoot && tar cf - ."
    }
    $remoteCmd = "docker exec $($Cfg.DockerContainer) sh -c '$tarInner'"

    New-Item -ItemType Directory -Force -Path $devPath | Out-Null
    Get-ChildItem -LiteralPath $devPath -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force

    $tempTar = Join-Path ([System.IO.Path]::GetTempPath()) ('ha-dev-full-' + [Guid]::NewGuid().ToString('n') + '.tar')
    try {
        Write-Host "Streaming tar from $($Cfg.DockerContainer):$remoteRoot (this can take several minutes) ..." -ForegroundColor Cyan
        $sshArgs = [System.Collections.ArrayList]::new()
        [void]$sshArgs.AddRange(@($Ssh.SshOpts))
        [void]$sshArgs.AddRange(@($Ssh.IdentityArg))
        [void]$sshArgs.AddRange(@($Ssh.PortArg))
        [void]$sshArgs.Add($Ssh.Target)
        [void]$sshArgs.Add($remoteCmd)

        $p = Start-Process -FilePath $SshExe -ArgumentList @($sshArgs.ToArray()) -RedirectStandardOutput $tempTar -NoNewWindow -Wait -PassThru
        if ($p.ExitCode -ne 0) {
            throw (Get-SshFailureMessage $p.ExitCode $Cfg $AllowPasswordPrompt)
        }
        if (-not (Test-Path -LiteralPath $tempTar)) {
            throw 'Temporary archive was not created.'
        }
        $len = (Get-Item -LiteralPath $tempTar).Length
        if ($len -lt 1024) {
            throw "Archive is unexpectedly small ($len bytes). Check DockerContainer and DevMirror.RemoteConfigDir."
        }

        Write-Host "Extracting into $devPath ..." -ForegroundColor Cyan
        $dockerBin = Get-Command docker -ErrorAction SilentlyContinue
        $extractOk = $false
        if ($null -ne $dockerBin) {
            Write-Host 'Using Linux tar inside Docker (Windows tar cannot unpack GNU long-path entries from the Pi).' -ForegroundColor DarkGray
            & docker run --rm -v "$($devPath):/out" -v "$($tempTar):/archive.tar:ro" alpine:3.19 tar xf /archive.tar -C /out
            if ($LASTEXITCODE -eq 0) {
                $extractOk = $true
            } else {
                Write-Warning "Docker-based extract failed (exit $LASTEXITCODE); trying Windows tar.exe."
            }
        }
        if (-not $extractOk) {
            $tarCmd = Get-Command tar -ErrorAction Stop
            & $tarCmd.Source -xf $tempTar -C $devPath
            if ($LASTEXITCODE -ne 0) {
                throw "Extract failed (exit $LASTEXITCODE). Install Docker Desktop for reliable unpack, or extract the temp .tar under WSL with GNU tar."
            }
        }
    }
    finally {
        if (Test-Path -LiteralPath $tempTar) {
            Remove-Item -LiteralPath $tempTar -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Host ''
    Write-Host "Prod mirror ready at: $devPath" -ForegroundColor Green
    Write-Host 'Next: cd dev' -ForegroundColor Green
    Write-Host '      docker compose up -d' -ForegroundColor Green
    Write-Host '      Open http://localhost:8123 (same logins and integrations as production).' -ForegroundColor DarkGray
}

function Push-LovelaceStorageFiles {
    param(
        [string]$sshExe,
        [hashtable]$ssh,
        $cfg,
        [string]$LocalRepoRoot
    )
    $ls = $cfg.LovelaceStorage
    $localDir = Join-Path $LocalRepoRoot ([string]$ls.LocalRelativeDir)
    if (-not (Test-Path -LiteralPath $localDir)) {
        throw "Local Lovelace directory not found: $localDir`nRun Pull first or create .storage files."
    }
    $files = @(Get-ChildItem -LiteralPath $localDir -File | Where-Object { $_.Name -match '^lovelace' })
    if ($files.Count -eq 0) {
        Write-Host "No local Lovelace files to push (expected files named lovelace* under $localDir)." -ForegroundColor DarkYellow
        return
    }
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    foreach ($f in $files) {
        $name = $f.Name
        if ($name -match '[/\\]') { continue }
        $remotePath = Join-RemoteUnixPath $ls.RemoteStorageDir $name
        Ensure-HaRemotePathHasNoSingleQuote $remotePath 'Lovelace remote path'
        if ($cfg.BackupOnPush) {
            $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
            $backupPath = "$remotePath.bak.$ts"
            $backupCmd = "docker exec $($cfg.DockerContainer) sh -c " +
                "'cp $remotePath $backupPath 2>/dev/null || true'"
            Invoke-SshRemote $sshExe $ssh.SshOpts $ssh.IdentityArg $ssh.PortArg $ssh.Target $backupCmd | Out-Null
        }
        $pushCmd = "docker exec -i $($cfg.DockerContainer) sh -c 'cat > $remotePath'"
        $content = [System.IO.File]::ReadAllText($f.FullName, $utf8)
        $pushArgs = @()
        $pushArgs += $ssh.SshOpts
        $pushArgs += $ssh.IdentityArg
        $pushArgs += $ssh.PortArg
        $pushArgs += $ssh.Target
        $pushArgs += $pushCmd
        $content | & $sshExe @pushArgs | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw (Get-SshFailureMessage $LASTEXITCODE $cfg ([bool]$AllowPasswordPrompt))
        }
        Write-Host "  Pushed Lovelace: $name" -ForegroundColor Green
    }
    Write-Host "Lovelace storage push complete. Restart Home Assistant if the UI does not reflect changes." -ForegroundColor DarkGray
}

$sshExe = Get-OpenSshPath
$cfg = Read-Config $ConfigPath
Apply-IdentityDiscovery $cfg
$localFile = Join-Path $scriptRoot $cfg.LocalRelativePath
$ssh = Build-SshTarget $cfg ([bool]$AllowPasswordPrompt)

if ($Action -eq 'PullDev') {
    Write-Host "Using config: $ConfigPath" -ForegroundColor DarkGray
    Write-Host "SSH: $($ssh.Target) (port $($cfg.SshPort))" -ForegroundColor Cyan
    if ($cfg.SshIdentityFile) {
        Write-Host "SSH key: $($cfg.SshIdentityFile)" -ForegroundColor DarkGray
    }
    if ($cfg.SshBatchMode -and -not $AllowPasswordPrompt) {
        Write-Host "SSH non-interactive (BatchMode=yes). Use -AllowPasswordPrompt to type a password." -ForegroundColor DarkGray
    }
    Write-Host "PullDev: mirror $($cfg.DevMirror.RemoteConfigDir) from container $($cfg.DockerContainer) -> $($cfg.DevMirror.LocalRelativeDir)" -ForegroundColor Cyan
    Write-Host 'This is a clone of production data (tokens, cloud, Z-Wave keys). Do not run two copies against the same cloud account if the integration forbids it.' -ForegroundColor DarkYellow
    Invoke-PullDevFullConfigFromProd -SshExe $sshExe -Ssh $ssh -Cfg $cfg -RepoRoot $scriptRoot `
        -ExcludeDatabase ([bool]$ExcludeDatabase) -AllowPasswordPrompt ([bool]$AllowPasswordPrompt)
    return
}

if ($Action -eq 'Push' -and $Scope -eq 'Context') {
    throw 'Push with -Scope Context is not supported. Assistant context snapshots are pull-only.'
}

Write-Host "Using config: $ConfigPath" -ForegroundColor DarkGray
Write-Host "SSH: $($ssh.Target) (port $($cfg.SshPort))" -ForegroundColor Cyan
if ($cfg.SshIdentityFile) {
    Write-Host "SSH key: $($cfg.SshIdentityFile)" -ForegroundColor DarkGray
}
if ($cfg.SshBatchMode -and -not $AllowPasswordPrompt) {
    Write-Host "SSH non-interactive (BatchMode=yes). Use -AllowPasswordPrompt to type a password." -ForegroundColor DarkGray
}
Write-Host "Container: $($cfg.DockerContainer) :: $($cfg.RemoteConfigPath)" -ForegroundColor Cyan

$doConfig = $Scope -in @('All', 'Config')
$doYaml = $Scope -in @('All', 'Artifacts')
$yamlCount = ($cfg.YamlArtifacts | Measure-Object).Count
if ($doYaml -and $yamlCount -eq 0) {
    if ($Scope -eq 'Artifacts') {
        throw 'YamlArtifacts is empty in ha-sync.config.json. Add entries or use -Scope All.'
    }
    $doYaml = $false
}
$doLovelace = $Scope -in @('All', 'Lovelace')
if ($doLovelace -and -not [bool]$cfg.LovelaceStorage.Enabled) {
    if ($Scope -eq 'Lovelace') {
        throw 'LovelaceStorage.Enabled is false in ha-sync.config.json. Enable it or use -Scope Config.'
    }
    $doLovelace = $false
}
$doContext = ($Scope -in @('All', 'Context')) -and [bool]$cfg.AssistantContextStorage.Enabled
if ($Scope -eq 'Context' -and -not [bool]$cfg.AssistantContextStorage.Enabled) {
    throw 'AssistantContextStorage.Enabled is false in ha-sync.config.json. Enable it or use -Scope All.'
}

if ($Action -eq 'Pull') {
    if ($doConfig) {
        $remoteCmd = "docker exec $($cfg.DockerContainer) cat $($cfg.RemoteConfigPath)"
        $out = Invoke-SshRemote $sshExe $ssh.SshOpts $ssh.IdentityArg $ssh.PortArg $ssh.Target $remoteCmd
        if ($LASTEXITCODE -ne 0) {
            throw (Get-SshFailureMessage $LASTEXITCODE $cfg ([bool]$AllowPasswordPrompt))
        }
        $text = if ($null -eq $out) { '' } elseif ($out -is [array]) { ($out | ForEach-Object { $_.ToString() }) -join "`n" } else { $out.ToString() }
        if (-not $text.EndsWith("`n")) { $text += "`n" }
        $enc = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($localFile, $text, $enc)
        Write-Host "Pulled to: $localFile" -ForegroundColor Green
    }
    if ($doYaml) {
        Write-Host 'Pulling YAML artifacts (automations / scripts / scenes) ...' -ForegroundColor Cyan
        $rows = @($cfg.YamlArtifacts)
        if ($null -eq $rows -or ($rows | Measure-Object).Count -eq 0) {
            Write-Host 'YamlArtifacts is empty; skipping extra YAML pull.' -ForegroundColor DarkYellow
        } else {
            $incEnc = [System.Text.UTF8Encoding]::new($false)
            for ($j = 0; $j -lt $rows.Count; $j++) {
                $incRow = $rows[$j]
                $incRp = [string]$incRow.RemotePath
                if ($incRp -match "'") { throw "YamlArtifacts RemotePath cannot contain single quotes: $incRp" }
                $incLp = Join-Path -Path $scriptRoot -ChildPath ([string]$incRow.LocalRelativePath)
                $incParent = [System.IO.Path]::GetDirectoryName($incLp)
                if (-not [string]::IsNullOrWhiteSpace($incParent)) {
                    [void][System.IO.Directory]::CreateDirectory($incParent)
                }
                $incRemoteCmd = "docker exec $($cfg.DockerContainer) cat $incRp"
                $incOut = Invoke-SshRemote $sshExe $ssh.SshOpts $ssh.IdentityArg $ssh.PortArg $ssh.Target $incRemoteCmd
                if ($LASTEXITCODE -ne 0) {
                    $incHint = ' If the file is missing on the server, remove that entry from YamlArtifacts in ha-sync.config.json.'
                    throw "Pull failed for $incRp (ssh exit $LASTEXITCODE).$incHint $(Get-SshFailureMessage $LASTEXITCODE $cfg ([bool]$AllowPasswordPrompt))"
                }
                $incText = if ($null -eq $incOut) { '' } elseif ($incOut -is [array]) { ($incOut | ForEach-Object { $_.ToString() }) -join "`n" } else { $incOut.ToString() }
                if (-not $incText.EndsWith("`n")) { $incText += "`n" }
                [System.IO.File]::WriteAllText($incLp, $incText, $incEnc)
                Write-Host "  Pulled YAML: $($incRow.LocalRelativePath)" -ForegroundColor Green
            }
            Write-Host 'YAML artifacts pull complete (automations / scripts / scenes).' -ForegroundColor Green
        }
    }
    if ($doLovelace) {
        Write-Host "Pulling Lovelace storage from $($cfg.LovelaceStorage.RemoteStorageDir) ..." -ForegroundColor Cyan
        Pull-LovelaceStorageFiles -sshExe $sshExe -ssh $ssh -cfg $cfg -LocalRepoRoot $scriptRoot
    }
    if ($doContext) {
        Write-Host "Pulling assistant context from $($cfg.AssistantContextStorage.RemoteStorageDir) ..." -ForegroundColor Cyan
        Pull-AssistantContextStorageFiles -sshExe $sshExe -ssh $ssh -cfg $cfg -LocalRepoRoot $scriptRoot
    }
    return
}

if ($Action -eq 'Push') {
    if ($doConfig) {
        if (-not (Test-Path -LiteralPath $localFile)) {
            throw "Local file not found: $localFile`nRun Pull first or create the file."
        }
        if ($cfg.BackupOnPush) {
            $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
            $backupPath = "$($cfg.RemoteConfigPath).bak.$ts"
            $backupCmd = "docker exec $($cfg.DockerContainer) sh -c " +
                "'cp $($cfg.RemoteConfigPath) $backupPath 2>/dev/null || true'"
            Write-Host "Remote backup (if file exists): $backupPath" -ForegroundColor DarkYellow
            Invoke-SshRemote $sshExe $ssh.SshOpts $ssh.IdentityArg $ssh.PortArg $ssh.Target $backupCmd | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "Backup step returned exit code $LASTEXITCODE (continuing push)."
            }
        }
        if ($cfg.RemoteConfigPath -match "'") {
            throw 'RemoteConfigPath cannot contain single quotes; adjust ha-sync.config.json.'
        }
        $pushCmd = "docker exec -i $($cfg.DockerContainer) sh -c 'cat > $($cfg.RemoteConfigPath)'"
        $utf8 = [System.Text.UTF8Encoding]::new($false)
        $content = [System.IO.File]::ReadAllText($localFile, $utf8)
        $pushArgs = @()
        $pushArgs += $ssh.SshOpts
        $pushArgs += $ssh.IdentityArg
        $pushArgs += $ssh.PortArg
        $pushArgs += $ssh.Target
        $pushArgs += $pushCmd
        $content | & $sshExe @pushArgs | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw (Get-SshFailureMessage $LASTEXITCODE $cfg ([bool]$AllowPasswordPrompt))
        }
        Write-Host "Pushed from: $localFile" -ForegroundColor Green
        Write-Host "Reload YAML in Home Assistant (Developer tools > YAML) or restart the container if needed." -ForegroundColor DarkGray
    }
    if ($doYaml) {
        Write-Host 'Pushing YAML artifacts (automations / scripts / scenes) ...' -ForegroundColor Cyan
        $rows = @($cfg.YamlArtifacts)
        if ($null -eq $rows -or ($rows | Measure-Object).Count -eq 0) {
            Write-Host 'YamlArtifacts is empty; skipping extra YAML push.' -ForegroundColor DarkYellow
        } else {
            $incUtf8 = [System.Text.UTF8Encoding]::new($false)
            for ($j = 0; $j -lt $rows.Count; $j++) {
                $incRow = $rows[$j]
                $incRp = [string]$incRow.RemotePath
                if ($incRp -match "'") { throw "YamlArtifacts RemotePath cannot contain single quotes: $incRp" }
                $incLp = Join-Path -Path $scriptRoot -ChildPath ([string]$incRow.LocalRelativePath)
                if (-not (Test-Path -LiteralPath $incLp)) {
                    throw "Local YAML artifact not found: $incLp`nRun Pull first or remove this entry from YamlArtifacts."
                }
                $incDoBackup = Get-YamlArtifactBackupFlag $incRow $cfg
                if ($incDoBackup) {
                    $incTs = Get-Date -Format 'yyyyMMdd-HHmmss'
                    $incBackupPath = "$incRp.bak.$incTs"
                    $incBackupCmd = "docker exec $($cfg.DockerContainer) sh -c " +
                        "'cp $incRp $incBackupPath 2>/dev/null || true'"
                    Invoke-SshRemote $sshExe $ssh.SshOpts $ssh.IdentityArg $ssh.PortArg $ssh.Target $incBackupCmd | Out-Null
                }
                $incPushCmd = "docker exec -i $($cfg.DockerContainer) sh -c 'cat > $incRp'"
                $incContent = [System.IO.File]::ReadAllText($incLp, $incUtf8)
                $incPushArgs = @()
                $incPushArgs += $ssh.SshOpts
                $incPushArgs += $ssh.IdentityArg
                $incPushArgs += $ssh.PortArg
                $incPushArgs += $ssh.Target
                $incPushArgs += $incPushCmd
                $incContent | & $sshExe @incPushArgs | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    throw (Get-SshFailureMessage $LASTEXITCODE $cfg ([bool]$AllowPasswordPrompt))
                }
                Write-Host "  Pushed YAML: $($incRow.LocalRelativePath)" -ForegroundColor Green
            }
            Write-Host 'YAML artifacts push complete. Reload automations in Developer tools > YAML if needed.' -ForegroundColor DarkGray
        }
    }
    if ($doLovelace) {
        Write-Host "Pushing Lovelace storage to $($cfg.LovelaceStorage.RemoteStorageDir) ..." -ForegroundColor Cyan
        Push-LovelaceStorageFiles -sshExe $sshExe -ssh $ssh -cfg $cfg -LocalRepoRoot $scriptRoot
    }
    return
}
