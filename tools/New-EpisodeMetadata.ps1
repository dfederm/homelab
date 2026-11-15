<#
.SYNOPSIS
Creates Jellyfin episode NFOs and thumbnails from an episode mapping CSV.

.PARAMETER Path
The show folder.

.PARAMETER MappingPath
CSV created by New-EpisodeMapping.ps1.

.PARAMETER Apply
Write missing NFOs and thumbnails. Without this, only shows what would happen.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string] $Path,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string] $MappingPath,

    [switch] $Apply
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$headers = @{}
$apiKeyQuery = ''
if ($env:TMDB_ACCESS_TOKEN) { $headers.Authorization = "Bearer $env:TMDB_ACCESS_TOKEN" }
elseif ($env:TMDB_API_KEY) { $apiKeyQuery = "&api_key=$env:TMDB_API_KEY" }
else { throw 'No TMDb credential found. Set TMDB_API_KEY or TMDB_ACCESS_TOKEN in the environment first.' }

function Get-Tmdb([string] $Request) {
    try { Invoke-RestMethod -Uri "https://api.themoviedb.org/3${Request}?language=en-US$apiKeyQuery" -Headers $headers }
    catch { throw "TMDb request failed for ${Request}: $($_.Exception.Message)" }
}

function Format-Element([string] $Tag, $Value, [string] $Indent = '  ') {
    if ("$Value") { "$Indent<$Tag>$([Security.SecurityElement]::Escape("$Value"))</$Tag>" }
}

function Write-NewFile([string] $FilePath, [byte[]] $Bytes) {
    $stream = [IO.File]::Open($FilePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($Bytes, 0, $Bytes.Length) }
    finally { $stream.Dispose() }
}

function New-Nfo($Local, $Episode, $Credits) {
    $people = @(
        foreach ($person in $Credits.crew) {
            if ($person.job -eq 'Director') { Format-Element director $person.name }
            elseif ($person.job -in 'Writer', 'Screenplay', 'Story') { Format-Element writer $person.name }
        }
        foreach ($person in @($Credits.cast) + @($Credits.guest_stars) | Where-Object name) {
            $fields = @(Format-Element name $person.name '    '; Format-Element role $person.character '    ')
            "  <actor>`n$($fields -join "`n")`n  </actor>"
        }
    ) | Select-Object -Unique

    $rating = if ($Episode.vote_count -gt 0) {
        "  <ratings>`n    <rating name=`"themoviedb`" max=`"10`" default=`"true`">" +
        "`n      <value>$($Episode.vote_average)</value>`n      <votes>$($Episode.vote_count)</votes>" +
        "`n    </rating>`n  </ratings>"
    }

    $lines = @(
        '<?xml version="1.0" encoding="utf-8" standalone="yes"?>'
        '<episodedetails>'
        Format-Element title $Local.Title
        Format-Element season $Local.Season
        Format-Element episode $Local.Episode
        Format-Element plot $Episode.overview
        Format-Element aired $Episode.air_date
        if ($Episode.runtime) { Format-Element runtime $Episode.runtime }
        $rating
        $people
        '</episodedetails>'
    )
    ($lines | Where-Object { $_ }) -join "`n"
}

$rows = @(Import-Csv -LiteralPath $MappingPath)
$seasonCache = @{}
$unresolved = 0
$root = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Path).ProviderPath)
$comparison = if ([IO.Path]::DirectorySeparatorChar -eq '\') { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }

$episodes = @(
    foreach ($row in $rows) {
        $filePath = [IO.Path]::GetFullPath((Join-Path $root $row.FilePath))
        if (-not $filePath.StartsWith($root + [IO.Path]::DirectorySeparatorChar, $comparison)) {
            Write-Warning "$($row.FilePath): file path is outside the show folder"
            $unresolved++
            continue
        }
        if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
            Write-Warning "$($row.FilePath): file not found"
            $unresolved++
            continue
        }

        $file = Get-Item -LiteralPath $filePath
        if ($file.BaseName -notmatch '(?:^|[ ._-])S(\d+)E(\d+)[ ._-]+(.+)$') {
            Write-Warning "$($row.FilePath): filename has no SxxEyy and title"
            $unresolved++
            continue
        }
        [pscustomobject]@{
            File = $file
            Season = [int]$Matches[1]
            Episode = [int]$Matches[2]
            Title = $Matches[3].Replace('_', ' ').Trim()
            Mapping = $row
        }
    }
)
$duplicates = @(
    $episodes | Group-Object { "$($_.Season)/$($_.Episode)" } |
        Where-Object Count -gt 1 | ForEach-Object Name
)

foreach ($local in $episodes) {
    $row = $local.Mapping
    $file = $local.File
    if ("$($local.Season)/$($local.Episode)" -in $duplicates) {
        Write-Warning "$($row.FilePath): duplicate local episode number"
        $unresolved++
        continue
    }
    if (-not $row.TMDbSeriesId -or -not $row.TMDbSeason -or -not $row.TMDbEpisode) {
        Write-Warning "$($row.FilePath): no TMDb episode selected"
        $unresolved++
        continue
    }

    $key = "$($row.TMDbSeriesId)/$($row.TMDbSeason)"
    if (-not $seasonCache.ContainsKey($key)) {
        $seasonCache[$key] = Get-Tmdb "/tv/$($row.TMDbSeriesId)/season/$($row.TMDbSeason)"
    }
    $episode = $seasonCache[$key].episodes | Where-Object episode_number -eq $row.TMDbEpisode
    if (@($episode).Count -ne 1) {
        Write-Warning "$($row.FilePath): TMDb episode $($row.TMDbSeriesId)/$($row.TMDbSeason)/$($row.TMDbEpisode) is missing or ambiguous"
        $unresolved++
        continue
    }
    $episode = @($episode)[0]

    $folder = $file.DirectoryName
    $nfoPath = Join-Path $folder "$($file.BaseName).nfo"
    $thumb = Get-ChildItem -LiteralPath $folder -Filter "$($file.BaseName)-thumb.*" | Select-Object -First 1
    $nfoStatus = if (Test-Path -LiteralPath $nfoPath) { 'exists, keeping' } else { 'create' }
    $thumbStatus = if ($thumb) { 'exists, keeping' } elseif ($episode.still_path) { 'create' } else { 'none on TMDb' }
    "$($local.Title) -> TMDb $($row.TMDbSeriesId)/$($row.TMDbSeason)/$($row.TMDbEpisode): $($episode.name)"
    "  NFO: $nfoStatus; thumbnail: $thumbStatus"

    if ($nfoStatus -eq 'create') {
        $credits = Get-Tmdb "/tv/$($row.TMDbSeriesId)/season/$($row.TMDbSeason)/episode/$($row.TMDbEpisode)/credits"
        $nfo = New-Nfo $local $episode $credits
        Write-Verbose $nfo
        if ($Apply) { Write-NewFile $nfoPath ([Text.Encoding]::UTF8.GetBytes($nfo)) }
    }

    if ($Apply -and $thumbStatus -eq 'create') {
        $tempPath = [IO.Path]::GetTempFileName()
        try {
            Invoke-WebRequest -Uri "https://image.tmdb.org/t/p/original$($episode.still_path)" -UseBasicParsing -OutFile $tempPath
            $thumbPath = Join-Path $folder ($file.BaseName + '-thumb' + [IO.Path]::GetExtension($episode.still_path))
            Write-NewFile $thumbPath ([IO.File]::ReadAllBytes($tempPath))
        }
        finally { [IO.File]::Delete($tempPath) }
    }
}

"{0} {1} mapping rows; {2} unresolved." -f $(if ($Apply) { 'Applied' } else { 'Previewed' }), $rows.Count, $unresolved
if ($unresolved) { exit 1 }
