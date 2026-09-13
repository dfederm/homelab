[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9.-]+(?::[0-9]{1,5})?$')]
    [string]$ForgejoHost,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Owner,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Package,

    [string]$Version,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$CredentialRepo,

    [scriptblock]$CredentialProvider,
    [scriptblock]$ApiInvoker,
    [scriptblock]$CredentialRefresher
)

$ErrorActionPreference = "Stop"

$resolvedCredentialRepo = Resolve-Path -LiteralPath $CredentialRepo
if (-not (Test-Path -LiteralPath $resolvedCredentialRepo.Path -PathType Container))
{
    throw "CredentialRepo must identify an existing directory."
}
$CredentialRepo = $resolvedCredentialRepo.Path

function Test-GitAuthenticationFailure
{
    param([object[]]$Output)

    $text = $Output -join "`n"
    return $text -match '(?i)(Authentication failed|Credentials are incorrect or have expired|Cannot prompt because user interactivity has been disabled|unable to get password)'
}

function Invoke-GitWithStaleTokenRetry
{
    $output = @(git -C $CredentialRepo ls-remote origin HEAD 2>&1)
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0 -and (Test-GitAuthenticationFailure -Output $output))
    {
        $output = @(git -C $CredentialRepo ls-remote origin HEAD 2>&1)
        $exitCode = $LASTEXITCODE
    }

    return $exitCode -eq 0
}

function Get-ForgejoCredential
{
    if ($CredentialProvider)
    {
        $credential = & $CredentialProvider
    }
    else
    {
        $inputText = "protocol=https`nhost=$ForgejoHost`n`n"
        $lines = @($inputText | git credential fill)
        if ($LASTEXITCODE -ne 0)
        {
            throw "Git Credential Manager could not provide a credential for $ForgejoHost."
        }

        $values = @{}
        foreach ($line in $lines)
        {
            if ($line -match "=")
            {
                $parts = $line.Split("=", 2)
                $values[$parts[0]] = $parts[1]
            }
        }

        $credential = [pscustomobject]@{
            Username = $values.username
            Password = $values.password
        }
    }

    if (-not $credential.Username -or -not $credential.Password)
    {
        throw "The stored credential for $ForgejoHost is incomplete."
    }

    return $credential
}

function Invoke-ForgejoApi
{
    param([Parameter(Mandatory)][string]$Uri)

    for ($attempt = 0; $attempt -lt 2; $attempt++)
    {
        try
        {
            $credential = Get-ForgejoCredential
        }
        catch
        {
            throw "Could not obtain a credential for $ForgejoHost."
        }

        $token = [Convert]::ToBase64String(
            [Text.Encoding]::UTF8.GetBytes("$($credential.Username):$($credential.Password)")
        )

        try
        {
            if ($ApiInvoker)
            {
                return & $ApiInvoker $Uri "Basic $token"
            }
            return Invoke-RestMethod -Headers @{ Authorization = "Basic $token" } -Uri $Uri
        }
        catch
        {
            $statusCode = $_.Exception.Data["StatusCode"]
            if (-not $statusCode -and $_.Exception.Response)
            {
                $statusCode = $_.Exception.Response.StatusCode.value__
            }

            if ($attempt -eq 0 -and $statusCode -in @(401, 403))
            {
                try
                {
                    $refreshed = if ($CredentialRefresher)
                    {
                        [bool](& $CredentialRefresher)
                    }
                    else
                    {
                        Invoke-GitWithStaleTokenRetry
                    }
                }
                catch
                {
                    $refreshed = $false
                }

                if ($refreshed)
                {
                    continue
                }
            }

            $suffix = if ($statusCode) { " (HTTP $statusCode)" } else { "" }
            throw "Forgejo API request failed for $Uri$suffix."
        }
    }
}

$encodedOwner = [Uri]::EscapeDataString($Owner)
$encodedPackage = [Uri]::EscapeDataString($Package)
$page = 1
$pageSize = 50
$packages = @()
do
{
    $packagesUri = "https://${ForgejoHost}/api/v1/packages/${encodedOwner}" +
        "?type=container&q=$encodedPackage&page=$page&limit=$pageSize"
    $pagePackages = @(Invoke-ForgejoApi -Uri $packagesUri | ForEach-Object { $_ })
    $packages += $pagePackages
    $page++
}
while ($pagePackages.Count -eq $pageSize)

if (-not $Version)
{
    $versionedPackages = foreach ($item in $packages)
    {
        $parsedVersion = $null
        if ($item.name -eq $Package -and
            $item.type -eq "container" -and
            [Version]::TryParse($item.version, [ref]$parsedVersion))
        {
            [pscustomobject]@{
                Package = $item
                ParsedVersion = $parsedVersion
            }
        }
    }

    $selected = @(
        $versionedPackages |
            Sort-Object ParsedVersion -Descending |
            Select-Object -First 1
    )[0]
    if (-not $selected)
    {
        throw "No semantic container version was found for $Owner/$Package."
    }

    $Version = $selected.Package.version
}

$packageMetadata = @(
    $packages | Where-Object {
        $_.name -eq $Package -and
        $_.type -eq "container" -and
        $_.version -eq $Version
    }
)[0]
if (-not $packageMetadata)
{
    throw "Container package $Owner/$Package version $Version was not found."
}

$encodedVersion = [Uri]::EscapeDataString($Version)
$filesUri = "https://${ForgejoHost}/api/v1/packages/${encodedOwner}/container/" +
    "${encodedPackage}/${encodedVersion}/files"
$files = @(Invoke-ForgejoApi -Uri $filesUri | ForEach-Object { $_ })
$manifest = @($files | Where-Object { $_.name -eq "manifest.json" })[0]

if (-not $manifest -or $manifest.sha256 -notmatch "^[0-9a-fA-F]{64}$")
{
    throw "Package $Owner/$Package version $Version has no valid manifest.json SHA-256."
}

$digest = "sha256:$($manifest.sha256.ToLowerInvariant())"
[pscustomobject]@{
    Host = $ForgejoHost
    Owner = $Owner
    Package = $Package
    Version = $Version
    Digest = $digest
    ImagePin = "$ForgejoHost/$Owner/${Package}:$Version@$digest"
    CreatedAt = $packageMetadata.created_at
    PackageUrl = $packageMetadata.html_url
}
