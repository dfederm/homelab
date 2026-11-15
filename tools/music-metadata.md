# Portable music metadata

This workflow uses beets to review Deezer album matches without writing to the
library, then stages FLAC copies with missing tags and existing folder artwork
embedded. It does not update the original files or Jellyfin.

Beets' Deezer importer can put Deezer IDs in MusicBrainz tag fields. Do not use
`beet write` or enable tag writing during import. The staging tool copies only
the supported descriptive fields and never writes those IDs.

## Setup on Windows

With Python 3.11 or newer installed, choose a working directory outside the
music library, with enough space for the staged copies. Run these commands from
the repository root:

```powershell
$work = 'C:\path\to\music-metadata-work'
New-Item -ItemType Directory -Force $work | Out-Null
python -m venv "$work\venv"
& "$work\venv\Scripts\python.exe" -m pip install -r tools\requirements-music-metadata.txt
$beet = "$work\venv\Scripts\beet.exe"
$python = "$work\venv\Scripts\python.exe"
```

Create `$work\beets.yaml` with:

```yaml
plugins: fromfilename deezer export
threaded: no
import:
  copy: no
  move: no
  write: no
  resume: no
  timid: yes
```

Always provide the isolated config, database, and destination to beets. Do not
point beets at an existing beets database:

```powershell
$config = "$work\beets.yaml"
$database = "$work\beets.db"
$beetsDestination = "$work\beets-library"
```

## Review matches

For each FLAC album directory, import **without writing**. Repeat this command
for additional albums to collect matches into the same database:

```powershell
$album = 'C:\path\to\music\artist\album'
& $beet -c $config -l $database -d $beetsDestination import -C -M -W -t -P $album
```

For untagged files, choose **Enter search** and provide the artist and album.
Inspect the track list and release details, especially the edition and date,
before accepting a match. Skip uncertain or missing matches. Do not select
duplicate-removal, merge, or upgrade actions. Existing single tracks and
partially tagged files may require a separate match; the staging step reports
conflicting tags rather than replacing them.

Export the reviewed matches and generate a batch preview:

```powershell
$music = 'C:\path\to\music'
& $beet -c $config -l $database -d $beetsDestination export -l -f json `
  -i 'path,artist,album,albumartist,title,track,tracktotal,disc,disctotal,year,month,day,label,isrc,data_source,deezer_album_id,deezer_track_id' `
  -o "$work\matches.json"
& $python tools\music-metadata.py preview $music "$work\matches.json" "$work\preview.json"
```

Review `preview.json`: each track shows its release ID, missing fields to add,
conflicts, and any cover to embed. Conflicting tracks are skipped in staging;
resolve them separately rather than removing the conflict from the preview.
The preview file is created only if it does not already exist. Use fresh export
and preview paths for another batch.

## Stage copies

After reviewing the preview, stage the files to a separate directory:

```powershell
& $python tools\music-metadata.py stage "$work\preview.json" "$work\staged"
```

The tool rejects source files or covers changed since preview, never overwrites
staged files, and retains existing tags and embedded art. It embeds `folder.jpg`
or `cover.jpg` when the track has no embedded image. It skips tracks with
conflicts or no changes. Staging is not transactional: an error can leave
completed or partial files in the staging directory. Review or discard that
directory and use a fresh destination before retrying. WAV files are not
supported.

Staging does **not** copy filesystem ownership, permissions, or ACLs and does
not replace the originals. Before applying anything to the real library, make
and verify a backup and agree on a replacement and rollback procedure that
preserves those properties. A Jellyfin library refresh may be needed after an
authorized replacement. Deezer matches do not supply MusicBrainz identifiers;
Jellyfin's online album metadata and artwork lookup may therefore remain
limited.

The behavioral tests require `ffmpeg` on `PATH`:

```powershell
& $python tests\music-metadata.test.py
```
