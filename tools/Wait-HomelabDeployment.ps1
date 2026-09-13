[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern("^[0-9a-fA-F]{40}$")]
    [string]$Commit,

    [Parameter(Mandatory)]
    [System.Collections.IDictionary]$Targets,

    [ValidatePattern('^[A-Za-z_][A-Za-z0-9._-]*$')]
    [string]$SshUser = "root",

    [string]$StateDirectory = "/var/lib/homelab-deploy",

    [ValidateRange(1, 120)]
    [int]$TimeoutMinutes = 20,

    [ValidateRange(1, 300)]
    [int]$PollSeconds = 10,

    [ValidateRange(0, 7200)]
    [int]$TimeoutSeconds = 0,

    [scriptblock]$SshInvoker
)

$ErrorActionPreference = "Stop"
$Commit = $Commit.ToLowerInvariant()

function Test-SafeRemotePath
{
    param([Parameter(Mandatory)][string]$Path)

    return $Path -ne "/" -and
        $Path -match '^/[A-Za-z0-9._/-]+$' -and
        @(($Path -split '/') | Where-Object { $_ -eq ".." }).Count -eq 0
}

if ($Targets.Count -eq 0)
{
    throw "Targets must contain at least one name/address mapping."
}
if (-not (Test-SafeRemotePath -Path $StateDirectory))
{
    throw "StateDirectory must be a safe absolute path."
}
$StateDirectory = $StateDirectory.TrimEnd("/")

$targetList = @(
    foreach ($entry in $Targets.GetEnumerator())
    {
        $name = [string]$entry.Key
        $address = [string]$entry.Value
        if ([string]::IsNullOrWhiteSpace($name) -or
            [string]::IsNullOrWhiteSpace($address) -or
            $address -match '\s')
        {
            throw "Each target must have a non-empty name and whitespace-free SSH address."
        }

        [pscustomobject]@{
            Name = $name
            Address = $address
        }
    }
)

function Invoke-SshText
{
    param(
        [Parameter(Mandatory)][string]$TargetAddress,
        [Parameter(Mandatory)][string]$RemoteCommand
    )

    $normalizedCommand = $RemoteCommand -replace "`r", ""
    if ($SshInvoker)
    {
        return [string](& $SshInvoker $TargetAddress $normalizedCommand)
    }

    $destination = "${SshUser}@${TargetAddress}"
    $output = @(
        $normalizedCommand |
            & ssh -o BatchMode=yes -o ConnectTimeout=10 $destination bash -s 2>&1
    )
    if ($LASTEXITCODE -ne 0)
    {
        throw "SSH query failed for $TargetAddress`: $($output -join "`n")"
    }
    return ($output -join "`n").Trim()
}

function Get-TargetState
{
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Address
    )

    $remote = @'
state='__STATE_DIRECTORY__'
printf 'last_success=%s\n' "$(cat "$state/last-success" 2>/dev/null)"
printf 'worker=%s\n' "$(systemctl is-active homelab-deploy-worker.service 2>/dev/null || true)"
printf 'latest_event=%s\n' "$(cat "$state/events.log.1" "$state/events.log" 2>/dev/null | tail -n 1 || true)"
printf 'commit_event=%s\n' "$(cat "$state/events.log.1" "$state/events.log" 2>/dev/null | grep -F 'commit=__COMMIT__' | tail -n 1 || true)"
'@ -replace "__STATE_DIRECTORY__", $StateDirectory -replace "__COMMIT__", $Commit
    $text = Invoke-SshText -TargetAddress $Address -RemoteCommand $remote
    Write-Verbose "$Name raw state: $text"

    function Get-RemoteValue
    {
        param([Parameter(Mandatory)][string]$Key)

        $match = [regex]::Match($text, "(?m)^$([regex]::Escape($Key))=(.*)$")
        if ($match.Success)
        {
            return $match.Groups[1].Value.Trim()
        }
        return ""
    }

    [pscustomobject]@{
        Name = $Name
        Address = $Address
        LastSuccess = Get-RemoteValue -Key "last_success"
        Worker = Get-RemoteValue -Key "worker"
        LatestEvent = Get-RemoteValue -Key "latest_event"
        CommitEvent = Get-RemoteValue -Key "commit_event"
    }
}

$deadline = if ($TimeoutSeconds -gt 0)
{
    (Get-Date).AddSeconds($TimeoutSeconds)
}
else
{
    (Get-Date).AddMinutes($TimeoutMinutes)
}
$lastDisplay = @{}
$states = @()

while ($true)
{
    $states = @(
        foreach ($target in $targetList)
        {
            Get-TargetState -Name $target.Name -Address $target.Address
        }
    )

    foreach ($state in $states)
    {
        $display = "$($state.LastSuccess)|$($state.Worker)|$($state.LatestEvent)"
        if ($lastDisplay[$state.Name] -ne $display)
        {
            Write-Host "$($state.Name): $display"
            $lastDisplay[$state.Name] = $display
        }
    }

    $pendingStates = @($states | Where-Object {
        -not [string]::Equals(
            $_.LastSuccess,
            $Commit,
            [StringComparison]::OrdinalIgnoreCase
        )
    })
    if ($pendingStates.Count -eq 0)
    {
        break
    }

    foreach ($state in $pendingStates)
    {
        if ($state.CommitEvent -match '(^|\s)run-failure(\s|$)')
        {
            throw "$($state.Name) recorded a deployment failure for commit $Commit."
        }
    }

    if ((Get-Date) -ge $deadline)
    {
        throw "Timed out waiting for Homelab deployment commit $Commit."
    }

    Start-Sleep -Seconds $PollSeconds
}

[pscustomobject]@{
    Commit = $Commit
    Targets = $states
}
