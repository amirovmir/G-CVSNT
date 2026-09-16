#!/usr/bin/env bash
# Functional scenario through :pserver: against a freshly initialised
# repository (ci/contour). Adapted from plans/its-1098-harness/smoke_pserver.sh.
#
#   smoke_pserver.sh <cvs binary> <work dir>
#   ROOT   CVS root, default :pserver:cvs:cvs@127.0.0.1:2401/cvs
#
# Every mutation (add, commit, remove, commit, modify) is followed by
# "update -dP" in a second working copy and a full tree compare against the
# first one. That is the list from Pararam post 28705 plus what the open PRs
# need: a binary commit (blob push through cafs_server), a 400-file commit
# (crosses the >= 8 KiB output batching of PR #29), tag, branch switch.
#
# Not idempotent: the repository must be fresh (the contour recreates it
# with "docker compose down -v").
set -euo pipefail
CVS="$1"
W="$2"
ROOT=${ROOT:-":pserver:cvs:cvs@127.0.0.1:2401/cvs"}

rm -rf "$W"; mkdir -p "$W/imp/sub/deep"
cd "$W"

step() { echo; echo "### $*"; }

# Text files land in a working copy with the platform line ending, so compare
# text modulo CR; binaries byte for byte.
cmp_text() { diff <(tr -d '\r' < "$1") <(tr -d '\r' < "$2") > /dev/null; }
hash_tree() { (cd "$1" && find . -type f -not -path '*/CVS/*' | LC_ALL=C sort | xargs -r sha256sum); }
# After "update -dP" in wc2, both working copies must hold the same files with
# the same content.
sync_and_compare() {
  (cd wc2 && "$CVS" -Q update -dP)
  if ! diff <(hash_tree proj) <(hash_tree wc2); then
    echo "::error::working copies differ after: $*"; exit 1
  fi
  echo "    trees identical after: $*"
}

printf 'one\ntwo\n'            > imp/a.txt
printf 'deep\n'                > imp/sub/deep/d.txt
printf '\x00\x01\x02\xffbin\n' > imp/b.dat

step "version"
"$CVS" -d "$ROOT" version

step "import"
(cd imp && "$CVS" -d "$ROOT" import -m init proj VENDOR REL0)

step "checkout, twice"
"$CVS" -d "$ROOT" checkout proj
test -f proj/a.txt && test -f proj/sub/deep/d.txt
"$CVS" -d "$ROOT" checkout -d wc2 proj
sync_and_compare "checkout"

step "add + commit, update"
printf 'added\n' > proj/c.txt
(cd proj && "$CVS" add c.txt && "$CVS" commit -m "add one")
sync_and_compare "add + commit"
test -f wc2/c.txt

step "add + commit of a binary (blob push through cafs_server), update"
head -c 300000 /dev/urandom > proj/n.dat
(cd proj && "$CVS" add -kb n.dat && "$CVS" commit -m "add binary")
sync_and_compare "binary add + commit"
cmp proj/n.dat wc2/n.dat
cmp proj/b.dat wc2/b.dat

step "modify + commit, update"
printf 'one\ntwo\nthree\n' > proj/a.txt
(cd proj && "$CVS" commit -m "modify a")
sync_and_compare "modify + commit"
cmp_text proj/a.txt wc2/a.txt

step "second revision of the binary, update"
head -c 200000 /dev/urandom > proj/n.dat
(cd proj && "$CVS" commit -m "modify binary")
sync_and_compare "binary modify + commit"
cmp proj/n.dat wc2/n.dat

step "remove + commit, update"
(cd proj && "$CVS" remove -f c.txt && "$CVS" commit -m "remove c")
sync_and_compare "remove + commit"
test ! -f wc2/c.txt

step "remove of the binary + commit, update"
(cd proj && "$CVS" remove -f n.dat && "$CVS" commit -m "remove binary")
sync_and_compare "binary remove + commit"
test ! -f wc2/n.dat

step "tag / log / status / history"
(cd proj && "$CVS" tag SMOKE_TAG)
(cd proj && "$CVS" log a.txt | head -3)
(cd proj && "$CVS" status a.txt | head -3)
"$CVS" -d "$ROOT" history -a -x MAR 2>&1 | head -3 || true

step "checkout by tag"
"$CVS" -d "$ROOT" checkout -d wc3 -r SMOKE_TAG proj
cmp_text proj/a.txt wc3/a.txt

step "bulk add + commit of 400 files (>= 8 KiB output batching), update"
for i in $(seq 1 400); do printf 'line %d\n' "$i" > "proj/f$i.txt"; done
(cd proj && "$CVS" -Q add $(seq -f 'f%g.txt' 1 400) && "$CVS" -Q commit -m "bulk 400")
sync_and_compare "bulk add + commit"
test "$(ls wc2/f*.txt | wc -l)" = "400"

step "branch switch back and forth"
"$CVS" -d "$ROOT" checkout -d wc4 proj
(cd wc4 && "$CVS" update -dP -r SMOKE_TAG)
test ! -f wc4/f1.txt
(cd wc4 && "$CVS" update -dP -A)
test -f wc4/f1.txt

step "an independent checkout equals the updated working copy"
diff <(hash_tree wc2) <(hash_tree wc4)

echo
echo "### SMOKE OK"
