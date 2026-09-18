#!/bin/bash
# Two-clone conflict scenario driving the real GitSync code via `GitPad --sync`.
set -euo pipefail
cd "$(dirname "$0")"
BIN=.build/release/GitPad
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

git init --bare -q -b main "$TMP/remote.git"
A="$TMP/a"; B="$TMP/b"
mkdir "$A" "$B"

# machine A creates a note and syncs
echo "# Groceries
- milk" > "$A/list.md"
git -C "$A" init -q -b main
git -C "$A" -c user.name=A -c user.email=a@x config user.name A
git -C "$A" config user.email a@x
git -C "$A" remote add origin "$TMP/remote.git"
"$BIN" --sync "$A"

# machine B clones, both edit the SAME line of the same file
git clone -q "$TMP/remote.git" "$B"
git -C "$B" config user.name B; git -C "$B" config user.email b@x
echo "# Groceries
- milk
- eggs" > "$A/list.md"
echo "# Groceries
- milk
- bread" > "$B/list.md"
"$BIN" --sync "$A"
"$BIN" --sync "$B"   # must resolve the conflict silently

# assertions
[ -z "$(git -C "$B" status --porcelain)" ] || { echo "FAIL: B repo dirty"; exit 1; }
[ ! -d "$B/.git/rebase-merge" ] && [ ! -f "$B/.git/MERGE_HEAD" ] || { echo "FAIL: merge in progress"; exit 1; }
grep -q bread "$B/list.md" || { echo "FAIL: B's edit lost"; exit 1; }
ls "$B"/*conflict*.md >/dev/null 2>&1 || { echo "FAIL: no conflict copy for A's edit"; exit 1; }
grep -q eggs "$B"/*conflict*.md || { echo "FAIL: A's edit not preserved in copy"; exit 1; }

# A syncs again and sees both files, no conflict left
"$BIN" --sync "$A"
grep -q eggs "$A"/*conflict*.md || { echo "FAIL: conflict copy not propagated to A"; exit 1; }
echo "PASS: conflict resolved silently, both edits preserved"

# Scenario 2: remote already has a README (unrelated history) — a fresh local
# repo must merge it in, not fail forever on "unrelated histories".
R2="$TMP/remote2.git"; C="$TMP/c"; SEED="$TMP/seed"
git init --bare -q -b main "$R2"
git clone -q "$R2" "$SEED"
echo "# Notes repo" > "$SEED/README.md"
git -C "$SEED" -c user.name=S -c user.email=s@x add -A
git -C "$SEED" -c user.name=S -c user.email=s@x commit -qm readme
git -C "$SEED" push -q origin main

mkdir "$C"
echo "# Ideas
- ship it" > "$C/ideas.md"
git -C "$C" init -q -b main
git -C "$C" config user.name C; git -C "$C" config user.email c@x
git -C "$C" remote add origin "$R2"
"$BIN" --sync "$C"

[ -z "$(git -C "$C" status --porcelain)" ] || { echo "FAIL: C repo dirty after unrelated-histories sync"; exit 1; }
[ -f "$C/README.md" ] || { echo "FAIL: remote README not merged in"; exit 1; }
[ -f "$C/ideas.md" ] || { echo "FAIL: local note lost"; exit 1; }
echo "PASS: unrelated-histories remote merged cleanly"

# Scenario 3+5: only genuinely-conflicted files get a copy, named after the other device.
R3="$TMP/remote3.git"; D="$TMP/d"; E="$TMP/e"
git init --bare -q -b main "$R3"
mkdir "$D"
printf '# List\n- milk\n' > "$D/list.md"
git -C "$D" init -q -b main
git -C "$D" remote add origin "$R3"
GITPAD_DEVICE_NAME=A "$BIN" --sync "$D"
git clone -q "$R3" "$E"

printf '# List\n- milk\n- eggs\n' > "$D/list.md"
printf '# Plan\n- ship it\n' > "$D/plan.md"
GITPAD_DEVICE_NAME=A "$BIN" --sync "$D"
printf '# List\n- milk\n- bread\n' > "$E/list.md"
GITPAD_DEVICE_NAME=B "$BIN" --sync "$E"

n=$(ls "$E" | grep -c conflict || true)
[ "$n" = 1 ] || { echo "FAIL: expected 1 conflict copy, got $n"; ls "$E"; exit 1; }
[ -f "$E/plan.md" ] || { echo "FAIL: cleanly-merged file missing"; exit 1; }
ls "$E"/*"(conflict from A "*.md >/dev/null 2>&1 || { echo "FAIL: copy not named after device A"; ls "$E"; exit 1; }
echo "PASS: copies only for true conflicts, named after the other device"

# Scenario 4: modify/delete in both directions must never wedge the repo.
md_case() {  # $1=repo that deletes, $2=repo that edits, $3=marker only the edit adds
    del="$1"; edit="$2"; mark="$3"
    rm "$del/doc.md"; GITPAD_DEVICE_NAME=A "$BIN" --sync "$del"
    printf '# Doc\n- one\n- %s\n' "$mark" > "$edit/doc.md"
    GITPAD_DEVICE_NAME=B "$BIN" --sync "$edit" || { echo "FAIL: modify/delete sync exited nonzero"; exit 1; }
    [ -z "$(git -C "$edit" status --porcelain)" ] || { echo "FAIL: dirty after modify/delete"; exit 1; }
    [ ! -f "$edit/.git/MERGE_HEAD" ] || { echo "FAIL: merge left in progress"; exit 1; }
    grep -rq "$mark" "$edit" --include='*.md' || { echo "FAIL: edited content lost ($mark)"; exit 1; }
}
R4="$TMP/remote4.git"; F="$TMP/f"; G="$TMP/g"
git init --bare -q -b main "$R4"
mkdir "$F"; printf '# Doc\n- one\n' > "$F/doc.md"
git -C "$F" init -q -b main; git -C "$F" remote add origin "$R4"
GITPAD_DEVICE_NAME=A "$BIN" --sync "$F"
git clone -q "$R4" "$G"
md_case "$F" "$G" two      # remote deleted, local edited
GITPAD_DEVICE_NAME=A "$BIN" --sync "$F"
md_case "$G" "$F" three    # local deleted, remote edited
echo "PASS: modify/delete completes the merge both ways"

# Scenario 6: a push that fails once still lands (one blind retry).
R6="$TMP/remote6.git"; H="$TMP/h"
git init --bare -q -b main "$R6"
cat > "$R6/hooks/pre-receive" <<'HOOK'
#!/bin/sh
if [ ! -f ./failed-once ]; then touch ./failed-once; echo "transient" >&2; exit 1; fi
exit 0
HOOK
chmod +x "$R6/hooks/pre-receive"
mkdir "$H"; printf '# Retry\n- once\n' > "$H/retry.md"
git -C "$H" init -q -b main; git -C "$H" remote add origin "$R6"
"$BIN" --sync "$H" || { echo "FAIL: push retry did not recover"; exit 1; }
git -C "$R6" show main:retry.md 2>/dev/null | grep -q once || { echo "FAIL: commit never reached remote"; exit 1; }
echo "PASS: push retried once and landed"

# Scenario 7: a fresh device adopts an existing remote instead of conflicting with it.
TODAY=$(date +%Y-%m-%d)
R7="$TMP/remote7.git"; SEED7="$TMP/seed7"; I="$TMP/i"
git init --bare -q -b main "$R7"
git clone -q "$R7" "$SEED7"
mkdir -p "$SEED7/Daily"
echo "# Notes repo" > "$SEED7/README.md"
printf '# Monday\n- real note\n' > "$SEED7/Daily/2026-01-01.md"
git -C "$SEED7" -c user.name=S -c user.email=s@x add -A
git -C "$SEED7" -c user.name=S -c user.email=s@x commit -qm seed
git -C "$SEED7" push -q origin main

new_device() {  # $1=dir, $2=extra line for today's daily note
    mkdir -p "$1/Daily"
    printf '# Wednesday, 1 January\n\n%s' "$2" > "$1/Daily/$TODAY.md"
    printf '# ' > "$1/note-scratch.md"
    git -C "$1" init -q -b main
    git -C "$1" remote add origin "$3"
}
new_device "$I" "" "$R7"
"$BIN" --sync "$I" || { echo "FAIL: adoption sync failed"; exit 1; }
[ -f "$I/README.md" ] && [ -f "$I/Daily/2026-01-01.md" ] || { echo "FAIL: remote notes not adopted"; exit 1; }
ls "$I"/*conflict*.md >/dev/null 2>&1 && { echo "FAIL: adoption made conflict copies"; exit 1; }
[ -z "$(git -C "$I" status --porcelain)" ] || { echo "FAIL: dirty after adoption"; exit 1; }
echo "PASS: pristine device adopts an existing remote"

# Scenario 8 (negative): one typed character must block the reset --hard path.
R8="$TMP/remote8.git"; SEED8="$TMP/seed8"; J="$TMP/j"
git init --bare -q -b main "$R8"
git clone -q "$R8" "$SEED8"
echo "# Notes repo" > "$SEED8/README.md"
git -C "$SEED8" -c user.name=S -c user.email=s@x add -A
git -C "$SEED8" -c user.name=S -c user.email=s@x commit -qm seed
git -C "$SEED8" push -q origin main
new_device "$J" "- do not lose me" "$R8"
"$BIN" --sync "$J" || { echo "FAIL: non-pristine sync failed"; exit 1; }
grep -rq "do not lose me" "$J" --include='*.md' || { echo "FAIL: reset --hard ate a real note"; exit 1; }
[ -f "$J/README.md" ] || { echo "FAIL: remote README not merged in"; exit 1; }
echo "PASS: user content blocks adoption"

# Scenario 9: only Markdown is ever committed — a stray secret or binary never reaches the remote.
R9="$TMP/remote9.git"; K="$TMP/k"
git init --bare -q -b main "$R9"
mkdir -p "$K/Work"
printf '# Real\n- note\n' > "$K/Work/real.md"
printf 'TOKEN=hunter2\n' > "$K/.env"
printf 'binary' > "$K/Work/shot.png"
mkdir -p "$K/Clipboard"; printf '# Clipboard\nhunter2\n' > "$K/Clipboard/2026-01-01.md"
: > "$K/.DS_Store"
git -C "$K" init -q -b main; git -C "$K" remote add origin "$R9"
"$BIN" --sync "$K" || { echo "FAIL: sync with stray files failed"; exit 1; }
[ "$(git -C "$K" ls-files)" = "Work/real.md" ] || { echo "FAIL: non-markdown got committed: $(git -C "$K" ls-files)"; exit 1; }
git -C "$R9" show main:.env >/dev/null 2>&1 && { echo "FAIL: .env reached the remote"; exit 1; }
git -C "$R9" show main:Clipboard/2026-01-01.md >/dev/null 2>&1 && { echo "FAIL: Clipboard/ reached the remote"; exit 1; }
[ -f "$K/.env" ] || { echo "FAIL: stray file was deleted, not just ignored"; exit 1; }
echo "PASS: only markdown reaches the remote"

"$BIN" --selftest >/dev/null || { echo "FAIL: note-meta parser selftest"; exit 1; }
echo "PASS: note-meta parser (snippet + checklist tally)"

"$BIN" --uitest >/dev/null || { echo "FAIL: editor list-interaction uitest"; exit 1; }
echo "PASS: editor list interactions (tab/enter/backspace/renumber)"
