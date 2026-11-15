<#
.SYNOPSIS
Creates an editable CSV mapping local episodes to TMDb episodes by title.

.PARAMETER Path
The show folder.

.PARAMETER SeriesId
TMDb series IDs to search.

.PARAMETER OutputPath
CSV mapping file. Existing files are overwritten.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string] $Path,

    [Parameter(Mandatory)]
    [int[]] $SeriesId,

    [Parameter(Mandatory)]
    [string] $OutputPath
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$outputFullPath = [IO.Path]::GetFullPath($OutputPath)

$headers = @{}
$apiKeyQuery = ''
if ($env:TMDB_ACCESS_TOKEN) { $headers.Authorization = "Bearer $env:TMDB_ACCESS_TOKEN" }
elseif ($env:TMDB_API_KEY) { $apiKeyQuery = "&api_key=$env:TMDB_API_KEY" }
else { throw 'No TMDb credential found. Set TMDB_API_KEY or TMDB_ACCESS_TOKEN in the environment first.' }

function Get-Tmdb([string] $Request) {
    try { Invoke-RestMethod -Uri "https://api.themoviedb.org/3${Request}?language=en-US$apiKeyQuery" -Headers $headers }
    catch { throw "TMDb request failed for ${Request}: $($_.Exception.Message)" }
}

function Get-NormalizedTitle([string] $Title) {
    $words = ($Title.ToLowerInvariant() -replace '[^\p{L}\p{N}]+', ' ') -split ' '
    ($words | Where-Object { $_ -and $_ -notin 'a', 'an', 'the' }) -join ' '
}

function Get-MultipartTitle([string] $Title) {
    if ($Title -match '^(.*?)\s+(?:part\s+(\d+)|\((\d+)\))$') {
        '{0}|{1}' -f (Get-NormalizedTitle $Matches[1]), $(if ($Matches[2]) { $Matches[2] } else { $Matches[3] })
    }
}

$root = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Path).ProviderPath)
$folders = @(Get-Item -LiteralPath $root) + @(Get-ChildItem -LiteralPath $root -Directory | Where-Object Name -Match '^Season \d+$')
$episodes = @(
    foreach ($file in $folders | Get-ChildItem -File | Where-Object Extension -In '.avi', '.m4v', '.mkv', '.mov', '.mp4', '.mpg', '.ts', '.webm') {
        if ($file.BaseName -match '(?:^|[ ._-])S(\d+)E(\d+)[ ._-]+(.+)$') {
            [pscustomobject]@{
                FilePath = $file.FullName.Substring($root.Length).TrimStart([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
                Id       = 'S{0:D2}E{1:D2}' -f [int]$Matches[1], [int]$Matches[2]
                Title    = $Matches[3].Replace('_', ' ').Trim()
            }
        }
        else { Write-Warning "Skipping $($file.Name): no SxxEyy and title in the filename" }
    }
)
if (-not $episodes.Count) { throw 'No episode files with SxxEyy and a title were found.' }

$catalog = @(
    foreach ($id in $SeriesId | Select-Object -Unique) {
        $show = Get-Tmdb "/tv/$id"
        foreach ($seasonNumber in $show.seasons.season_number) {
            foreach ($episode in (Get-Tmdb "/tv/$id/season/$seasonNumber").episodes) {
                [pscustomobject]@{
                    Description     = '{0} ({1}) S{2:D2}E{3:D2}: {4}' -f $show.name, $id, $seasonNumber, $episode.episode_number, $episode.name
                    SeriesId        = $id
                    Season          = $seasonNumber
                    Episode         = $episode.episode_number
                    Title           = $episode.name
                    NormalizedTitle = Get-NormalizedTitle $episode.name
                }
            }
        }
    }
)

$duplicates = @($episodes | Group-Object Id | Where-Object Count -gt 1 | ForEach-Object Name)
$rows = @(
    foreach ($local in $episodes) {
        $candidates = @()
        $status = 'matched'
        if ($local.Id -in $duplicates) {
            $status = 'duplicate local episode number'
        }
        else {
            $candidates = @($catalog | Where-Object Title -ceq $local.Title)
            if (-not $candidates.Count) {
                $normalized = Get-NormalizedTitle $local.Title
                $candidates = @($catalog | Where-Object NormalizedTitle -eq $normalized)
            }
            if (-not $candidates.Count) {
                $multipart = Get-MultipartTitle $local.Title
                if ($multipart) { $candidates = @($catalog | Where-Object { (Get-MultipartTitle $_.Title) -eq $multipart }) }
            }
            if ($candidates.Count -ne 1) { $status = if ($candidates.Count) { 'ambiguous title' } else { 'no matching title' } }
        }

        if ($status -ne 'matched') {
            Write-Warning "$($local.Id) $($local.Title): $status$(if ($candidates.Count) { ': ' + ($candidates.Description -join '; ') })"
        }
        $match = if ($status -eq 'matched') { $candidates[0] }
        [pscustomobject]@{
            FilePath      = $local.FilePath
            TMDbSeriesId  = if ($match) { $match.SeriesId } else { '' }
            TMDbSeason    = if ($match) { $match.Season } else { '' }
            TMDbEpisode   = if ($match) { $match.Episode } else { '' }
        }
    }
)

$duplicateMatches = @(
    $rows | Where-Object TMDbSeriesId |
        Group-Object { "$($_.TMDbSeriesId)/$($_.TMDbSeason)/$($_.TMDbEpisode)" } |
        Where-Object Count -gt 1 | ForEach-Object Name
)
foreach ($row in $rows) {
    if ("$($row.TMDbSeriesId)/$($row.TMDbSeason)/$($row.TMDbEpisode)" -in $duplicateMatches) {
        $row.TMDbSeriesId = ''
        $row.TMDbSeason = ''
        $row.TMDbEpisode = ''
        Write-Warning "$($row.FilePath): duplicate TMDb match"
    }
}

$csvOptions = @{ LiteralPath = $outputFullPath; Encoding = 'UTF8' }
if ($PSVersionTable.PSVersion.Major -lt 6) { $csvOptions.NoTypeInformation = $true }
else { $csvOptions.UseQuotes = 'AsNeeded' }
$rows | Export-Csv @csvOptions
$unresolved = @($rows | Where-Object { -not $_.TMDbSeriesId }).Count
"Created mapping: $outputFullPath"
"Mapped {0} of {1} episodes; {2} need review." -f ($rows.Count - $unresolved), $rows.Count, $unresolved
if ($unresolved) { exit 1 }
