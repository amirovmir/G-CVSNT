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
# Every file under <source dir> must come back from <working copy> intact:
# .txt modulo CR, everything else byte for byte. Two checkouts agreeing does
# not prove that: an import path that stores a blob reference as file content
# hands the same wrong bytes to every checkout (ci/repro_import_kB.sh).
compare_with_source() {
  local src="$1" wc="$2" f rel
  while IFS= read -r f; do
    rel=${f#"$src"/}
    case "$rel" in
      *.txt) cmp_text "$f" "$wc/$rel" || { echo "::error::$rel: text differs from the source"; exit 1; } ;;
      *)     cmp "$f" "$wc/$rel" || { echo "::error::$rel: binary differs from the source ($(stat -c %s "$f") vs $(stat -c %s "$wc/$rel" 2>/dev/null || echo 0) bytes)"; exit 1; } ;;
    esac
  done < <(find "$src" -type f -not -path '*/CVS/*' | LC_ALL=C sort)
  echo "    working copy equals the source: $src"
}
# <path> <total bytes>: two-byte binary header, then 'x' filler. Unambiguously
# binary by content, so the client's automatic -kB on a .dat name is what gets
# exercised; no cvswrappers entry is involved.
mkbin() { { printf '\000\377'; head -c $(( $2 - 2 )) /dev/zero | tr '\0' 'x'; } > "$1"; }
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
mkbin imp/b.dat 5000
mkbin imp/sub/l.dat 200000

step "version"
"$CVS" -d "$ROOT" version

step "import"
(cd imp && "$CVS" -d "$ROOT" import -m init proj VENDOR REL0)

step "checkout, twice; the checkout must equal the import source"
"$CVS" -d "$ROOT" checkout proj
test -f proj/a.txt && test -f proj/sub/deep/d.txt
compare_with_source imp proj
"$CVS" -d "$ROOT" checkout -d wc2 proj
sync_and_compare "checkout"

step "mixed add of a text and a binary + commit (blob push through cafs_server), update"
mkdir -p added
printf 'added\n' > added/c.txt
head -c 300000 /dev/urandom > added/n.dat
cp added/c.txt added/n.dat proj/
(cd proj && "$CVS" add c.txt && "$CVS" add -kb n.dat && "$CVS" commit -m "add text and binary")
sync_and_compare "mixed add + commit"
compare_with_source added wc2

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
