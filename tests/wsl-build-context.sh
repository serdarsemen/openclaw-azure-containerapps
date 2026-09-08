#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
prepare="$repo_root/scripts/prepare-wsl-build.sh"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
git init -q -b main "$fixture/origin"
git -C "$fixture/origin" config user.name Test
git -C "$fixture/origin" config user.email test@example.invalid
printf '# syntax=docker/dockerfile:1\nFROM scratch\n' > "$fixture/origin/Dockerfile"
printf 'first\n' > "$fixture/origin/payload"
git -C "$fixture/origin" add .
git -C "$fixture/origin" commit -qm first
git clone -q "$fixture/origin" "$fixture/source"
printf 'local work\n' > "$fixture/source/payload"
first="$(bash "$prepare" "$fixture/source" '' "$fixture/cache")"
test -f "$first/Dockerfile"
! grep -q '^# syntax=' "$first/Dockerfile"
test "$(cat "$first/payload")" = first
second="$(bash "$prepare" "$fixture/source" '' "$fixture/cache")"
test "$first" = "$second"
test "$(cat "$fixture/source/payload")" = 'local work'
git -C "$fixture/origin" rm -q payload
git -C "$fixture/origin" commit -qm second
third="$(bash "$prepare" "$fixture/source" '' "$fixture/cache")"
test "$first" != "$third"
test ! -e "$third/payload"
test -f "$first/payload"
cp "$prepare" "$fixture/prepare-v2.sh"
printf '\n' >> "$fixture/prepare-v2.sh"
fourth="$(bash "$fixture/prepare-v2.sh" "$fixture/source" '' "$fixture/cache")"
test "$third" != "$fourth"
if bash "$prepare" "$fixture/source" nonexistent-tag "$fixture/cache"; then
    echo 'Missing tag unexpectedly succeeded' >&2
    exit 1
fi
echo 'PASS: context reuse, commit and patch invalidation, deleted files, local changes, and missing tag.'