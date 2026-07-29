#!/bin/bash
# Post-deploy hook for the ai stack: check what each configured Ollama model tag actually
# resolved to, and keep a durable record of it.
#
# Ollama cannot pin a model to a digest the way the compose files pin container images:
# `name@sha256:...` is rejected by its name parser, and registry.ollama.ai will not serve a
# manifest by digest either. Meanwhile `ollama pull` re-fetches the manifest on every deploy and
# prints the same "pulling manifest / verifying sha256 digest / writing manifest / success"
# whether or not anything changed. So an upstream tag re-point would land with no diff, no log
# difference, and no trace — the model changes under us and nothing records it.
#
# This hook closes that gap with two artifacts that have deliberately different jobs:
#
#   ollama-models.lock  in-repo, human-updated  -> the EXPECTED digest. Answers "did it change?"
#                                                  and gives the change a reviewable git diff.
#   the history log     on-disk, appended here  -> the OBSERVED digest. Answers "what actually
#                                                  ran on <date>?" even if nobody ever reacts to
#                                                  a warning. The lockfile alone cannot answer
#                                                  that, because it is only as current as the
#                                                  last person who noticed one.
#
# Best-effort: never breaks the deploy, same rule as services/forgejo/post-up.sh. Drift is
# information, and by the time this runs the stack is already up and serving; failing the deploy
# would just mark it red on every run until someone commits, without protecting anything.
#
# Env vars:
#   OLLAMA_PULL_MODELS   models to check (same list the ollama-pull container pulls)
#   OLLAMA_HTTP_PORT     host port the Ollama API is published on
#   DOCKER_APPDATA_ROOT  persistent store; the history log lives under it

set -euo pipefail

CONFIG_DIR="${CONFIG_DIR:?CONFIG_DIR not set}"
ENV_FILE="${ENV_FILE:?ENV_FILE not set}"

# source_env exports only CONFIG_DIR/ENV_FILE, and hooks run as a child process, so the env
# files have to be re-sourced here (same pattern as services/ai/pre-up.sh).
set -a
# shellcheck disable=SC1090,SC1091
[ -f "$CONFIG_DIR/common.env" ] && . "$CONFIG_DIR/common.env"
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

if [ -z "${OLLAMA_PULL_MODELS:-}" ]; then
    # Not an exit: with no models configured there is nothing to check against the lockfile, but
    # models pulled by hand may still be present, and recording those is the other half of the job.
    echo "  post-up: OLLAMA_PULL_MODELS is empty — nothing to check against the lockfile."
fi

# curl and jq come from the install-tools module, which is per-machine. Warn and skip rather than
# apt-installing mid-deploy.
for cmd in curl jq docker; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "  WARNING: $cmd not found — skipping Ollama model digest check." >&2
        echo "           Add 'install-tools' to HOMELAB_SETUP_MODULES to install curl and jq." >&2
        exit 0
    fi
done

if [ -z "${OLLAMA_HTTP_PORT:-}" ]; then
    echo "  WARNING: OLLAMA_HTTP_PORT not set — cannot reach the Ollama API to check models." >&2
    exit 0
fi

# `depends_on: service_healthy` only gates when ollama-pull STARTS, and `compose up -d` returns as
# soon as containers are started — so without this wait the digests below get sampled mid-pull.
# That is not a cosmetic race: Ollama writes the new manifest only after the blobs land, so while
# a re-pointed model downloads the API still reports the OLD digest. Sampling then would match the
# lockfile, print a reassuring OK, and hide the exact event this hook exists to catch.
echo "  post-up: waiting for ollama-pull to finish ..."
deadline=$(( $(date +%s) + 180 ))
while true; do
    pull_state=$(docker inspect -f '{{.State.Status}}' ollama-pull 2>/dev/null || echo missing)

    case "$pull_state" in
        exited)
            pull_exit=$(docker inspect -f '{{.State.ExitCode}}' ollama-pull 2>/dev/null || echo unknown)
            pull_exit="${pull_exit:-unknown}"
            if [ "$pull_exit" != "0" ]; then
                # Nothing else in the deploy notices this: `compose up -d` does not surface a
                # one-shot's exit code. Without the warning the checks below would report a
                # reassuring match against whatever weights happen to be left over.
                echo "  WARNING: ollama-pull exited with status $pull_exit — at least one pull failed," >&2
                echo "           so the digests below may not reflect what was asked for." >&2
                echo "           Check: docker logs ollama-pull" >&2
            fi
            break
            ;;
        running|created|restarting)
            : # still working — fall through to the deadline check
            ;;
        missing)
            echo "  WARNING: the ollama-pull container is not present — skipping model digest check." >&2
            exit 0
            ;;
        *)
            # dead, paused, ... — none of these reach "exited" on their own, so waiting out the
            # full deadline would just add three minutes to every deploy and then misreport why.
            echo "  WARNING: ollama-pull is in state '$pull_state' and will not finish — skipping" >&2
            echo "           model digest check. Check: docker logs ollama-pull" >&2
            exit 0
            ;;
    esac

    if [ "$(date +%s)" -ge "$deadline" ]; then
        echo "  post-up: ollama-pull is still running (a first pull downloads many GB) — digest"
        echo "           check deferred to the next deploy. Follow it with:"
        echo "               docker logs -f ollama-pull"
        exit 0
    fi

    sleep 3
done

if ! tags_json=$(curl -fsS --max-time 30 "http://localhost:${OLLAMA_HTTP_PORT}/api/tags"); then
    echo "  WARNING: could not reach the Ollama API — skipping model digest check." >&2
    exit 0
fi

# curl -f only promises a 2xx, nothing about the body: any other listener on that port answers with
# something unparseable, and letting jq choke on it below would abort the deploy — the one thing
# this hook must never do.
if ! printf '%s' "$tags_json" | jq -e '.models | type == "array"' > /dev/null 2>&1; then
    echo "  WARNING: the Ollama API did not return the expected response — skipping model digest" >&2
    echo "           check. Is OLLAMA_HTTP_PORT ($OLLAMA_HTTP_PORT) really Ollama?" >&2
    exit 0
fi

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCK_FILE="$HOOK_DIR/ollama-models.lock"

# The history must outlive a re-pave, so it cannot sit next to the models: OLLAMA_MODELS_ROOT may
# point at a scratch volume that is wiped and simply re-pulled. DOCKER_APPDATA_ROOT is the
# persistent store. Deliberately not ${DOCKER_APPDATA_ROOT}/ollama — that is the documented
# fallback for the model dir itself.
HISTORY_LOG=""
if [ -n "${DOCKER_APPDATA_ROOT:-}" ]; then
    HISTORY_LOG="${DOCKER_APPDATA_ROOT}/ollama-model-history/digests.log"
    if ! mkdir -p "$(dirname "$HISTORY_LOG")" 2> /dev/null; then
        echo "  WARNING: could not create $(dirname "$HISTORY_LOG") — model history will not be recorded." >&2
        HISTORY_LOG=""
    fi
else
    echo "  WARNING: DOCKER_APPDATA_ROOT not set — model history will not be recorded." >&2
fi

drifted=0
unpinned=0
matched=0
missing=0

# Unquoted on purpose: OLLAMA_PULL_MODELS is a space-separated list.
# shellcheck disable=SC2086
for model in ${OLLAMA_PULL_MODELS:-}; do
    # /api/tags always reports an explicit tag, so a bare name means :latest.
    case "$model" in
        *:*) ref="$model" ;;
        *)   ref="$model:latest" ;;
    esac

    resolved=$(printf '%s' "$tags_json" \
        | jq -r --arg m "$ref" 'first(.models[]? | select(.name == $m) | .digest) // empty' 2>/dev/null) \
        || resolved=""
    # A CR is never part of a model name or digest, so strip it rather than let a CRLF-saved
    # lockfile or history log turn into a phantom mismatch.
    resolved="${resolved//$'\r'/}"

    if [ -z "$resolved" ]; then
        missing=$(( missing + 1 ))
        echo "  WARNING: $ref is in OLLAMA_PULL_MODELS but Ollama does not have it — not checked." >&2
        continue
    fi

    # /api/tags reports a bare hex digest; store it self-describing, like the image pins.
    resolved="sha256:$resolved"

    expected=""
    if [ -f "$LOCK_FILE" ]; then
        # Accept the lockfile key with or without an explicit :latest.
        expected=$(awk -v m="$ref" '
            /^[[:space:]]*#/ { next }
            ($1 == m) || ($1 ":latest" == m) { print $2; exit }
        ' "$LOCK_FILE" 2>/dev/null) || expected=""
        expected="${expected//$'\r'/}"
    fi

    if [ -z "$expected" ]; then
        unpinned=$(( unpinned + 1 ))
        echo "  WARNING: $ref is not recorded in services/ai/ollama-models.lock — it is unchecked," >&2
        echo "           so a change to it would go unnoticed. Add this line to track it:" >&2
        echo "               $ref  $resolved" >&2
    elif [ "$expected" = "$resolved" ]; then
        matched=$(( matched + 1 ))
        echo "  post-up: $ref matches its recorded digest."
    else
        drifted=$(( drifted + 1 ))
        echo "" >&2
        echo "  ============================ OLLAMA MODEL DRIFT ============================" >&2
        echo "  $ref no longer resolves to the digest recorded in the repo." >&2
        echo "      recorded: $expected" >&2
        echo "      resolved: $resolved" >&2
        echo "  The tag was re-pointed upstream: the model name is unchanged but the weights" >&2
        echo "  are not. Anything measured against this model before and after this deploy is" >&2
        echo "  not comparable." >&2
        echo "  If the new model is wanted, record it in services/ai/ollama-models.lock as:" >&2
        echo "      $ref  $resolved" >&2
        echo "  ===========================================================================" >&2
        echo "" >&2
    fi
done

if [ -n "${OLLAMA_PULL_MODELS:-}" ]; then
    echo "  post-up: models checked — $matched matching, $drifted drifted, $unpinned unrecorded, $missing absent."
    if [ "$drifted" -gt 0 ]; then
        echo "  post-up: see the drift report above; the deploy itself succeeded." >&2
    fi
fi

# Record every model present locally, not just the ones this machine is configured to pull. A model
# pulled by hand to compare against another (`docker exec ollama ollama pull <model>`) does not
# belong in OLLAMA_PULL_MODELS or the lockfile, but it is exactly the kind of thing whose identity
# has to be on record when someone later asks what a measurement was taken against.
#
# Appends only when the digest differs from the last one recorded, so this is a history of model
# changes rather than a line per model per deploy.
if [ -n "$HISTORY_LOG" ]; then
    while IFS="$(printf '\t')" read -r logged_ref logged_digest; do
        logged_ref="${logged_ref//$'\r'/}"
        logged_digest="${logged_digest//$'\r'/}"
        [ -n "$logged_ref" ] && [ -n "$logged_digest" ] || continue
        logged_digest="sha256:$logged_digest"

        previous=""
        if [ -f "$HISTORY_LOG" ]; then
            previous=$(awk -v m="$logged_ref" '$2 == m { d = $3 } END { if (d != "") print d }' "$HISTORY_LOG" 2>/dev/null) || previous=""
            previous="${previous//$'\r'/}"
        fi

        if [ "$previous" != "$logged_digest" ]; then
            # A previous partial write (full disk) can leave the log without its final newline;
            # appending onto that would glue two records together and make both unreadable —
            # a corrupt record is worse than a missing one for something whose whole job is
            # answering "what ran when".
            terminator=""
            if [ -s "$HISTORY_LOG" ] && [ -n "$(tail -c 1 "$HISTORY_LOG" 2>/dev/null || true)" ]; then
                terminator=$'\n'
            fi

            # The history is the best-effort half of this hook; it must never be the thing that
            # takes a deploy down. Blank the path so this warns once, not once per model. The
            # subshell suppresses the shell's own redirect error, not just the command's —
            # otherwise a raw "Is a directory" leaks out ahead of the warning.
            if ! ( printf '%s%s\t%s\t%s\n' "$terminator" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$logged_ref" "$logged_digest" >> "$HISTORY_LOG" ) 2>/dev/null; then
                echo "  WARNING: could not append to $HISTORY_LOG — model history will not be recorded." >&2
                HISTORY_LOG=""
                break
            fi
        fi
    done < <(printf '%s' "$tags_json" | jq -r '.models[]? | [.name, .digest] | @tsv' 2>/dev/null || true)
fi
