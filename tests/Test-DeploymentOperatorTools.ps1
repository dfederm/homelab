$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$pinHelper = Join-Path $repoRoot "tools\Get-ForgejoContainerPin.ps1"
$watchHelper = Join-Path $repoRoot "tools\Wait-HomelabDeployment.ps1"
$commit = "54bd56de333f961d8a6caba287c55adac394e247"
$password = "test-password-that-must-not-leak"
$basicAuthorization = "Basic " + [Convert]::ToBase64String(
    [Text.Encoding]::UTF8.GetBytes("test-user:$password")
)

function Assert-True
{
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition)
    {
        throw $Message
    }
}

function Assert-Throws
{
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][string]$MessagePattern,
        [string[]]$ForbiddenText = @()
    )

    try
    {
        & $Action
    }
    catch
    {
        $message = $_.Exception.Message
        if ($message -notmatch $MessagePattern)
        {
            throw "Unexpected error: $message"
        }
        foreach ($forbidden in $ForbiddenText)
        {
            if ($forbidden -and $message.Contains($forbidden))
            {
                throw "An operator-tool error exposed credential material."
            }
        }
        return
    }

    throw "Expected an error matching '$MessagePattern'."
}

$credentialProvider = {
    [pscustomobject]@{ Username = "test-user"; Password = $password }
}.GetNewClosure()

$requests = [System.Collections.Generic.List[string]]::new()
$successApi = {
    param($Uri, $Authorization)
    $requests.Add($Uri)
    if ($Authorization -notmatch "^Basic ")
    {
        throw "Missing Basic authorization."
    }
    if ($Uri -match "/files$")
    {
        return @(
            [pscustomobject]@{ name = "layer"; sha256 = ("a" * 64) },
            [pscustomobject]@{ name = "manifest.json"; sha256 = ("B" * 64) }
        )
    }
    return @(
        [pscustomobject]@{
            name = "widget"
            version = "1.2.9"
            type = "container"
            created_at = "2026-09-05"
            html_url = "old"
        },
        [pscustomobject]@{
            name = "widget"
            version = "1.2.10"
            type = "container"
            created_at = "2026-09-06"
            html_url = "new"
        },
        [pscustomobject]@{
            name = "widget"
            version = "latest"
            type = "container"
            created_at = "2026-09-06"
            html_url = "latest"
        }
    )
}.GetNewClosure()

$pin = & $pinHelper `
    -ForgejoHost "forgejo.example.test" `
    -Owner "team" `
    -Package "widget" `
    -CredentialRepo $repoRoot `
    -CredentialProvider $credentialProvider `
    -ApiInvoker $successApi
Assert-True ($pin.Version -eq "1.2.10") `
    "Container pin helper did not select the latest semantic version."
Assert-True ($pin.Digest -eq "sha256:$("b" * 64)") `
    "Container pin helper did not normalize the manifest digest."
Assert-True (
    $pin.ImagePin -eq "forgejo.example.test/team/widget:1.2.10@sha256:$("b" * 64)"
) "Container pin helper returned the wrong immutable image reference."
Assert-True (
    $requests[0] -eq
        "https://forgejo.example.test/api/v1/packages/team?type=container&q=widget&page=1&limit=50"
) "Container pin helper did not use the supplied Forgejo coordinates."

$explicitPin = & $pinHelper `
    -ForgejoHost "forgejo.example.test" `
    -Owner "team" `
    -Package "widget" `
    -Version "1.2.9" `
    -CredentialRepo $repoRoot `
    -CredentialProvider $credentialProvider `
    -ApiInvoker $successApi
Assert-True ($explicitPin.Version -eq "1.2.9") `
    "Container pin helper did not preserve an explicitly selected version."

$pagedRequests = [System.Collections.Generic.List[string]]::new()
$pagedApi = {
    param($Uri, $Authorization)
    $pagedRequests.Add($Uri)
    if ($Uri -match "/files$")
    {
        return @(
            [pscustomobject]@{ name = "manifest.json"; sha256 = ("c" * 64) }
        )
    }
    if ($Uri -match "[?&]page=1(?:&|$)")
    {
        return @(0..49 | ForEach-Object {
            [pscustomobject]@{
                name = "widget"
                version = "1.0.$_"
                type = "container"
                created_at = "2026-09-05"
                html_url = "page-one"
            }
        })
    }
    if ($Uri -match "[?&]page=2(?:&|$)")
    {
        return @(
            [pscustomobject]@{
                name = "widget"
                version = "2.0.0"
                type = "container"
                created_at = "2026-09-06"
                html_url = "page-two-latest"
            },
            [pscustomobject]@{
                name = "widget"
                version = "0.9.0"
                type = "container"
                created_at = "2026-09-01"
                html_url = "page-two-explicit"
            }
        )
    }
    return @()
}.GetNewClosure()

$pagedLatestPin = & $pinHelper `
    -ForgejoHost "forgejo.example.test" `
    -Owner "team" `
    -Package "widget" `
    -CredentialRepo $repoRoot `
    -CredentialProvider $credentialProvider `
    -ApiInvoker $pagedApi
Assert-True ($pagedLatestPin.Version -eq "2.0.0") `
    "Container pin helper did not consider later pages for latest-version selection."

$pagedExplicitPin = & $pinHelper `
    -ForgejoHost "forgejo.example.test" `
    -Owner "team" `
    -Package "widget" `
    -Version "0.9.0" `
    -CredentialRepo $repoRoot `
    -CredentialProvider $credentialProvider `
    -ApiInvoker $pagedApi
Assert-True ($pagedExplicitPin.Version -eq "0.9.0") `
    "Container pin helper did not find an explicit version on a later page."
Assert-True (
    @($pagedRequests | Where-Object { $_ -match "[?&]page=2(?:&|$)" }).Count -ge 2
) "Container pin helper did not request later package pages."

$retryState = @{ ApiAttempts = 0; Refreshes = 0 }
$retryApi = {
    param($Uri, $Authorization)
    $retryState.ApiAttempts++
    if ($retryState.ApiAttempts -eq 1)
    {
        $exception = [Exception]::new("unauthorized $password $Authorization")
        $exception.Data["StatusCode"] = 401
        throw $exception
    }
    & $successApi $Uri $Authorization
}.GetNewClosure()
$refresh = {
    $retryState.Refreshes++
    return $true
}.GetNewClosure()
$null = & $pinHelper `
    -ForgejoHost "forgejo.example.test" `
    -Owner "team" `
    -Package "widget" `
    -CredentialRepo $repoRoot `
    -CredentialProvider $credentialProvider `
    -ApiInvoker $retryApi `
    -CredentialRefresher $refresh
Assert-True (
    $retryState.ApiAttempts -ge 2 -and $retryState.Refreshes -eq 1
) "Container pin helper did not retry once after credential refresh."

$forbiddenApi = {
    param($Uri, $Authorization)
    $exception = [Exception]::new("forbidden $password $Authorization")
    $exception.Data["StatusCode"] = 403
    throw $exception
}.GetNewClosure()
Assert-Throws -MessagePattern "HTTP 403" `
    -ForbiddenText @($password, $basicAuthorization) `
    -Action {
        & $pinHelper `
            -ForgejoHost "forgejo.example.test" `
            -Owner "team" `
            -Package "widget" `
            -CredentialRepo $repoRoot `
            -CredentialProvider $credentialProvider `
            -ApiInvoker $forbiddenApi `
            -CredentialRefresher { $false }
    }

Assert-Throws -MessagePattern "Could not obtain a credential" `
    -ForbiddenText @($password) `
    -Action {
        & $pinHelper `
            -ForgejoHost "forgejo.example.test" `
            -Owner "team" `
            -Package "widget" `
            -CredentialRepo $repoRoot `
            -CredentialProvider { throw "credential failure $password" } `
            -ApiInvoker $successApi
    }

$missingManifestApi = {
    param($Uri, $Authorization)
    if ($Uri -match "/files$")
    {
        return @([pscustomobject]@{ name = "layer"; sha256 = ("a" * 64) })
    }
    return @(
        [pscustomobject]@{
            name = "widget"
            version = "1.2.10"
            type = "container"
            created_at = "2026-09-06"
            html_url = "new"
        }
    )
}
Assert-Throws -MessagePattern "no valid manifest.json" -Action {
    & $pinHelper `
        -ForgejoHost "forgejo.example.test" `
        -Owner "team" `
        -Package "widget" `
        -Version "1.2.10" `
        -CredentialRepo $repoRoot `
        -CredentialProvider $credentialProvider `
        -ApiInvoker $missingManifestApi
}

$targets = [ordered]@{
    alpha = "192.0.2.10"
    beta = "node.example.test"
}
$seenAddresses = [System.Collections.Generic.List[string]]::new()
$successSsh = {
    param($Address, $RemoteCommand)
    $seenAddresses.Add($Address)
    if ($RemoteCommand -notmatch 'events\.log\.1')
    {
        throw "Deployment watcher did not inspect the rotated event segment."
    }
    return @"
last_success=$commit
worker=inactive
latest_event=run-success applied=$commit
commit_event=
"@
}.GetNewClosure()
$deployment = & $watchHelper `
    -Commit $commit `
    -Targets $targets `
    -TimeoutSeconds 2 `
    -PollSeconds 1 `
    -SshInvoker $successSsh
Assert-True ($deployment.Targets.Count -eq 2) `
    "Deployment watcher did not return every target."
Assert-True (
    $seenAddresses.Contains("192.0.2.10") -and
    $seenAddresses.Contains("node.example.test")
) "Deployment watcher did not query the explicit target mappings."

Assert-Throws -MessagePattern "pattern|argument" -Action {
    & $watchHelper `
        -Commit $commit.Substring(0, 7) `
        -Targets $targets `
        -TimeoutSeconds 1 `
        -PollSeconds 1 `
        -SshInvoker $successSsh
}

$failureSsh = {
    param($Address, $RemoteCommand)
    if ($Address -eq "192.0.2.10")
    {
        return @"
last_success=$commit
worker=inactive
latest_event=run-success applied=$commit
commit_event=run-failure commit=$commit
"@
    }
    return @"
last_success=0000000000000000000000000000000000000000
worker=inactive
latest_event=run-failure commit=$commit
commit_event=run-failure commit=$commit
"@
}.GetNewClosure()
Assert-Throws -MessagePattern "deployment failure" -Action {
    & $watchHelper `
        -Commit $commit `
        -Targets $targets `
        -TimeoutSeconds 1 `
        -PollSeconds 1 `
        -SshInvoker $failureSsh
}

$uppercaseCommit = $commit.ToUpperInvariant()
$uppercaseFailureSsh = {
    param($Address, $RemoteCommand)
    if ($RemoteCommand.Contains($uppercaseCommit))
    {
        throw "Deployment watcher did not normalize the requested commit."
    }
    if (-not $RemoteCommand.Contains("commit=$commit"))
    {
        throw "Deployment watcher did not query the normalized commit."
    }
    return @"
last_success=0000000000000000000000000000000000000000
worker=inactive
latest_event=run-failure commit=$commit
commit_event=run-failure commit=$commit
"@
}.GetNewClosure()
Assert-Throws -MessagePattern "deployment failure" -Action {
    & $watchHelper `
        -Commit $uppercaseCommit `
        -Targets ([ordered]@{ alpha = "192.0.2.10" }) `
        -TimeoutSeconds 1 `
        -PollSeconds 1 `
        -SshInvoker $uppercaseFailureSsh
}

$pendingSsh = {
    param($Address, $RemoteCommand)
    return @"
last_success=0000000000000000000000000000000000000000
worker=active
latest_event=run-failure commit=0000000000000000000000000000000000000000
commit_event=
"@
}
Assert-Throws -MessagePattern "Timed out" -Action {
    & $watchHelper `
        -Commit $commit `
        -Targets $targets `
        -TimeoutSeconds 1 `
        -PollSeconds 1 `
        -SshInvoker $pendingSsh
}

$customStateSsh = {
    param($Address, $RemoteCommand)
    if ($RemoteCommand -notmatch "state='/srv/homelab-state'")
    {
        throw "Deployment watcher did not use the configured state directory."
    }
    return @"
last_success=$commit
worker=inactive
latest_event=run-success applied=$commit
commit_event=
"@
}.GetNewClosure()
$null = & $watchHelper `
    -Commit $commit `
    -Targets ([ordered]@{ alpha = "192.0.2.10" }) `
    -StateDirectory "/srv/homelab-state" `
    -TimeoutSeconds 1 `
    -PollSeconds 1 `
    -SshInvoker $customStateSsh

Assert-Throws -MessagePattern "safe absolute path" -Action {
    & $watchHelper `
        -Commit $commit `
        -Targets $targets `
        -StateDirectory "/var/lib/../unsafe" `
        -TimeoutSeconds 1 `
        -PollSeconds 1 `
        -SshInvoker $successSsh
}

Write-Host "Deployment operator tool tests passed."
