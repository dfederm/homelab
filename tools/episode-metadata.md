# Episode metadata for Jellyfin

The workflow has two steps:

1. `New-EpisodeMapping.ps1` matches local episode titles against TMDb and writes
   an editable CSV mapping.
2. Review and complete the CSV, then `New-EpisodeMetadata.ps1` previews or
   creates Jellyfin episode NFOs and thumbnails from those explicit mappings.

The scripts keep your filenames and local season and episode numbers. TMDb
numbering is used only to look up metadata.

They run on Windows PowerShell 5.1 (built into Windows) and PowerShell 7 for
Linux and macOS.

## Setup

Get a free TMDb API key: create a TMDb account, then request one under
[Settings > API](https://www.themoviedb.org/settings/api). Set it in the
environment rather than saving it in the scripts:

```powershell
$env:TMDB_API_KEY = "your-key"
```

A v4 read access token in `TMDB_ACCESS_TOKEN` also works. Either variable only
lasts for the current PowerShell window, so set it again in a new one. On
Windows, downloaded scripts may be blocked; run `Unblock-File` on them, and if
scripts are disabled, `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`.

Filenames need `SxxEyy` followed by the title, such as
`Dragon Ball_S01E01_Secret of the Dragon Balls.mkv`, either directly in the
show folder or in `Season N` folders. Other folders, such as extras, are
ignored.

## Create and review the mapping

List every TMDb series the show's episodes come from. The output CSV is
overwritten if it already exists, so use a different path to preserve reviewed
edits.

```powershell
.\tools\New-EpisodeMapping.ps1 "\\server\media\TV\Batman" -SeriesId 2098, 4625 -OutputPath (Join-Path $env:TEMP 'Batman-mapping.csv')
```

The CSV has four columns: `FilePath` (relative to the show folder),
`TMDbSeriesId`, `TMDbSeason`, and `TMDbEpisode`. Local titles and episode
numbers come from the filenames. Titles match exactly first, then ignoring case,
punctuation, extra spaces, and the words "a", "an", and "the". As a final
fallback, titles ending in "Part 1" also match titles ending in "(1)", and so
on.

Rows with one unique match have the three TMDb ID fields filled in. For
ambiguous, unmatched, or duplicate TMDb matches, review the console warnings and
fill in `TMDbSeriesId`, `TMDbSeason`, and `TMDbEpisode` yourself. Duplicate
local episode numbers need to be fixed in the filenames before generating the
mapping again.
The mapping command warns about unresolved rows and exits with status 1, but
still writes the CSV so you can review it. It never writes media sidecars.

## Preview and create sidecars

Preview the reviewed CSV first:

```powershell
.\tools\New-EpisodeMetadata.ps1 "\\server\media\TV\Batman" -MappingPath (Join-Path $env:TEMP 'Batman-mapping.csv')
```

The preview shows the selected TMDb episode and whether its NFO and thumbnail
would be created or kept. Add `-Verbose` to see the NFO contents. Unresolved
rows, missing files, paths outside the show folder, and duplicate local episode
numbers are skipped and reported. The script reads local titles and episode
numbers directly from each mapped file's name.

After reviewing both the CSV and its preview, add `-Apply` to create missing
files:

```powershell
.\tools\New-EpisodeMetadata.ps1 "\\server\media\TV\Batman" -MappingPath (Join-Path $env:TEMP 'Batman-mapping.csv') -Apply
```

Existing NFOs and thumbnails are never overwritten. The script exits with
status 1 while anything is unresolved.

Before refreshing the library, check Jellyfin's metadata and image saver
settings: Jellyfin can change sidecars even though this script does not
overwrite them. After refreshing, verify a small sample's show, episode
numbers, metadata, and thumbnails.

This product uses the TMDB API but is not endorsed or certified by TMDB. Follow
[TMDb's API terms](https://www.themoviedb.org/api-terms-of-use).
