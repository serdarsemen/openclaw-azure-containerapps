#!/usr/bin/env bash
set -euo pipefail
umask 077
source_path="${1:-}"
tag="${2:-}"
cache_root="${3:-$HOME/.cache/openclaw-build}"
if [ -z "$cache_root" ]; then cache_root="$HOME/.cache/openclaw-build"; fi
if [ -z "$source_path" ]; then source_path="$cache_root/source"; fi
case "$cache_root" in /*) ;; *) echo 'Build cache path must be an absolute Linux path.' >&2; exit 1 ;; esac
mkdir -p "$cache_root/contexts"
exec 9>"$cache_root/.prepare.lock"
flock 9
started=$SECONDS
if [ ! -e "$source_path" ]; then
    mkdir -p "$(dirname "$source_path")"
    git clone --single-branch --branch main https://github.com/openclaw/openclaw.git "$source_path" >&2
fi
if [ -n "$tag" ]; then
    git check-ref-format "refs/tags/$tag"
    git -C "$source_path" fetch origin "refs/tags/$tag" >&2
else
    git -C "$source_path" fetch origin refs/heads/main >&2
fi
commit="$(git -C "$source_path" rev-parse --verify 'FETCH_HEAD^{commit}')"
patch_hash="$(sha256sum "$0" | cut -d ' ' -f1)"
entry="$cache_root/contexts/$commit-$patch_hash"
printf '  Source: %s\n  Build commit: %s\n  Source fetch: %ss\n' "$source_path" "$commit" "$((SECONDS-started))" >&2
if [ -f "$entry/.ready" ] && [ -f "$entry/context/Dockerfile" ]; then
    printf '  Steps 2a-2c: reusing prepared WSL context\n' >&2
    printf '%s\n' "$entry/context"
    exit 0
fi
staging="$(mktemp -d "$cache_root/contexts/.prepare-XXXXXXXX")"
trap 'rm -rf "$staging"' EXIT
started=$SECONDS
git -C "$source_path" archive --format=tar --output "$staging/source.tar" "$commit"
printf '  Step 2a: archive completed in %ss\n' "$((SECONDS-started))" >&2
started=$SECONDS
mkdir "$staging/context"
tar -xf "$staging/source.tar" -C "$staging/context"
rm "$staging/source.tar"
printf '  Step 2b: extraction completed in %ss\n' "$((SECONDS-started))" >&2
started=$SECONDS
sed -i '1s|^# syntax=docker/dockerfile:.*||' "$staging/context/Dockerfile"
printf '  Step 2c: Dockerfile prepared in %ss (cache mounts retained)\n' "$((SECONDS-started))" >&2
touch "$staging/.ready"
if [ -e "$entry" ]; then
    echo "Incomplete cache entry: $entry. Remove this entry manually and retry." >&2
    exit 1
fi
mv "$staging" "$entry"
trap - EXIT
printf '%s\n' "$entry/context"