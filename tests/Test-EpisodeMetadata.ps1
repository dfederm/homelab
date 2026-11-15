$ErrorActionPreference = 'Stop'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString())
$previousKey = $env:TMDB_API_KEY
$previousToken = $env:TMDB_ACCESS_TOKEN
$requestsAllowed = $true

function Invoke-RestMethod {
    param([string] $Uri, [hashtable] $Headers)

    if (-not $requestsAllowed) { throw 'Unexpected provider request for an unresolved mapping.' }
    if ($Uri -match '/tv/42\?') {
        return [pscustomobject]@{ name = 'Example'; seasons = @([pscustomobject]@{ season_number = 1 }) }
    }
    if ($Uri -match '/tv/42/season/1\?') {
        return [pscustomobject]@{ episodes = @([pscustomobject]@{
            episode_number = 1
            name = 'Example Episode'
            overview = 'Example plot'
            still_path = $null
        }) }
    }
    if ($Uri -match '/tv/42/season/1/episode/1/credits\?') {
        return [pscustomobject]@{ crew = @(); cast = @(); guest_stars = @() }
    }
    throw "Unexpected TMDb request: $Uri"
}

try {
    $show = Join-Path $fixture 'show'
    New-Item -ItemType Directory -Path $show -Force | Out-Null
    $video = Join-Path $show 'Example_S02E03_The Example Episode.mkv'
    [IO.File]::WriteAllBytes($video, [byte[]]@(1))
    $mapping = Join-Path $fixture 'mapping.csv'
    [IO.File]::WriteAllText($mapping, 'old mapping')
    $providerPath = "Microsoft.PowerShell.Core\FileSystem::$show"
    $env:TMDB_API_KEY = 'test'
    $env:TMDB_ACCESS_TOKEN = ''

    & (Join-Path $PSScriptRoot '..\tools\New-EpisodeMapping.ps1') -Path $providerPath -SeriesId 42 -OutputPath $mapping -WarningVariable mappingWarnings
    if ($mappingWarnings.Count -gt 0) {
        throw "Unexpected mapping warnings: $mappingWarnings"
    }
    if ((Get-Content -LiteralPath $mapping -TotalCount 1) -like '#TYPE*') {
        throw 'Mapping unexpectedly includes CSV type information.'
    }
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        $mappingLines = @(Get-Content -LiteralPath $mapping)
        if ($mappingLines[0] -ne 'FilePath,TMDbSeriesId,TMDbSeason,TMDbEpisode' -or
            $mappingLines[1] -ne 'Example_S02E03_The Example Episode.mkv,42,1,1') {
            throw 'CSV fields are not quoted only as needed.'
        }
    }
    $rows = @(Import-Csv -LiteralPath $mapping)
    if ($rows.Count -ne 1 -or @($rows[0].PSObject.Properties).Count -ne 4 -or
        $rows[0].FilePath -ne [IO.Path]::GetFileName($video) -or $rows[0].TMDbEpisode -ne '1') {
        throw 'Provider-qualified show path did not produce the expected episode mapping.'
    }

    $preview = & (Join-Path $PSScriptRoot '..\tools\New-EpisodeMetadata.ps1') -Path $providerPath -MappingPath $mapping
    if (($preview -join "`n") -notmatch 'Previewed 1 mapping rows; 0 unresolved\.') {
        throw 'Provider-qualified show path did not produce a successful metadata preview.'
    }
    $nfoPath = [IO.Path]::ChangeExtension($video, '.nfo')
    if (Test-Path -LiteralPath $nfoPath) {
        throw 'Preview unexpectedly created an NFO.'
    }
    & (Join-Path $PSScriptRoot '..\tools\New-EpisodeMetadata.ps1') -Path $providerPath -MappingPath $mapping -Apply
    $nfo = [xml][IO.File]::ReadAllText($nfoPath)
    if ($nfo.episodedetails.title -ne 'The Example Episode' -or
        $nfo.episodedetails.season -ne '2' -or $nfo.episodedetails.episode -ne '3') {
        throw 'Four-column mapping did not preserve the title and numbering from the filename.'
    }

    $duplicateVideo = Join-Path $show 'Example_S02E03_Another Title.mkv'
    [IO.File]::WriteAllBytes($duplicateVideo, [byte[]]@(1))
    Add-Content -LiteralPath $mapping -Value ('"{0}","42","1","1"' -f [IO.Path]::GetFileName($duplicateVideo))
    $requestsAllowed = $false
    $duplicateResult = & (Join-Path $PSScriptRoot '..\tools\New-EpisodeMetadata.ps1') -Path $providerPath -MappingPath $mapping -Apply -WarningAction SilentlyContinue
    if (($duplicateResult -join "`n") -notmatch 'Applied 2 mapping rows; 2 unresolved\.' -or
        (Test-Path -LiteralPath ([IO.Path]::ChangeExtension($duplicateVideo, '.nfo')))) {
        throw 'Duplicate local episode numbers were not blocked without a status column.'
    }

    $manualShow = Join-Path $fixture 'manual'
    New-Item -ItemType Directory -Path $manualShow | Out-Null
    foreach ($name in 'Example_S01E01_Example Episode.mkv', 'Example_S01E02_The Example Episode.mkv') {
        [IO.File]::WriteAllBytes((Join-Path $manualShow $name), [byte[]]@(1))
    }
    $manualMapping = Join-Path $fixture 'manual.csv'
    $requestsAllowed = $true
    & (Join-Path $PSScriptRoot '..\tools\New-EpisodeMapping.ps1') -Path $manualShow -SeriesId 42 -OutputPath $manualMapping -WarningAction SilentlyContinue -WarningVariable duplicateWarnings
    $manualRows = @(Import-Csv -LiteralPath $manualMapping)
    if ($duplicateWarnings.Count -ne 2 -or @($manualRows | Where-Object TMDbSeriesId).Count) {
        throw 'Duplicate TMDb matches were not left unresolved with console warnings.'
    }
    $requestsAllowed = $false
    $unresolvedResult = & (Join-Path $PSScriptRoot '..\tools\New-EpisodeMetadata.ps1') -Path $manualShow -MappingPath $manualMapping -WarningAction SilentlyContinue
    if (($unresolvedResult -join "`n") -notmatch 'Previewed 2 mapping rows; 2 unresolved\.') {
        throw 'Unselected TMDb episodes were not skipped.'
    }
    foreach ($row in $manualRows) {
        $row.TMDbSeriesId = 42
        $row.TMDbSeason = 1
        $row.TMDbEpisode = 1
    }
    $csvOptions = @{ LiteralPath = $manualMapping; Encoding = 'UTF8' }
    if ($PSVersionTable.PSVersion.Major -lt 6) { $csvOptions.NoTypeInformation = $true }
    $manualRows | Export-Csv @csvOptions
    $requestsAllowed = $true
    $manualResult = & (Join-Path $PSScriptRoot '..\tools\New-EpisodeMetadata.ps1') -Path $manualShow -MappingPath $manualMapping
    if (($manualResult -join "`n") -notmatch 'Previewed 2 mapping rows; 0 unresolved\.') {
        throw 'Manually completed TMDb selections were not accepted.'
    }
    'PASS four-column mappings, filename metadata, duplicate handling, provider paths, and CSV overwrite'
}
finally {
    $env:TMDB_API_KEY = $previousKey
    $env:TMDB_ACCESS_TOKEN = $previousToken
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
