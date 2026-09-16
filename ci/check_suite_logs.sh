#!/usr/bin/env bash
# Assert that the suites ran to completion and that the cases behind the
# open PRs actually executed instead of being skipped.
#
#   check_suite_logs.sh <regress.log> <testcvs.log>
#
# ALLOW_EXT_SIGSEGV=1 (the Linux job sets it) downgrades exactly one failure
# to a warning: the -ku case crashing with SIGSEGV over :ext:. That crash
# predates the PR stack (it reproduces on master, see
# Docs/cvsnt-linux-server-build-pserver-deadlock.md section 7 and
# plans/its-1098-harness/repro_ext_segfault.sh); the same case passes on
# Windows. Any other failure, or a different failure of that case, still fails.
#
# regress.py prints "ok <name>" per passing test and a "<n> passed, <m> failed"
# summary; the -ku case prints a "(skipped: ...)" note and still counts as ok
# when the ext protocol plugin is missing, which is exactly the silent
# failure this guards against. testcvs.py exits 0 even on failure (it raises
# a bare SystemExit), so its result has to be read from the log: a failure
# prints "Test '...' failed (" or "Terminating", success reaches the last
# scenario, "*info".
set -u
regress="$1"
testcvs="$2"
rc=0

fail() { echo "::error::$*"; rc=1; }

ku="a -ku text file checks out with every line ending encoded"

echo "--- regress.py"
if [ "${ALLOW_EXT_SIGSEGV:-}" = 1 ] && grep -qF "  FAIL  $ku" "$regress"; then
  [ "$(grep -cE '^\s+FAIL\s' "$regress")" -eq 1 ] || fail "regress.py has FAIL lines besides the known :ext: SIGSEGV"
  grep -E '^[0-9]+ passed, 1 failed' "$regress" >/dev/null || fail "regress.py summary is not '<n> passed, 1 failed'"
  grep -A3 -F "  FAIL  $ku" "$regress" | grep -q 'expected 0, got -11' \
    || fail "regress.py: '$ku' failed, but not with the known SIGSEGV (rc -11)"
  echo "::warning title=known :ext: SIGSEGV on Linux::regress.py '$ku' crashed over :ext: (rc -11), a pre-existing bug that reproduces on master; verified on Windows instead. See Docs/cvsnt-linux-server-build-pserver-deadlock.md section 7"
  ku_required=0
else
  grep -E '^[0-9]+ passed, 0 failed' "$regress" >/dev/null || fail "regress.py did not report zero failures"
  grep -E '^\s+FAIL\s' "$regress" && fail "regress.py has FAIL lines"
  ku_required=1
fi
# regress.py has exactly two skip notes (grep -n skipped regress.py):
#   "(skipped: the :ext: protocol plugin is not available here)"  - the -ku
#       case could not open a client/server session; this is the silent
#       failure CI exists to catch, so it fails the job
#   "(symlink case skipped: not permitted here)"  - a sub-case of the
#       binary-by-content test that needs SeCreateSymbolicLinkPrivilege; a
#       windows-2022 runner does not grant it, the rest of the test still
#       runs, and the Linux job covers the symlink path. Allowed.
# Anything else mentioning a skipped protocol, plugin or fork is new and
# fails until it is reviewed.
if grep -v 'symlink case skipped' "$regress" | grep -Ei 'skipped.*(protocol|plugin|fork)|(protocol|plugin|fork).*skipped' ; then
  fail "regress.py skipped a protocol case; every client/server case must execute in CI"
fi
for t in "binary content is detected on add and import by content, not by name" \
         "binary file survives a commit/checkout round trip byte for byte"; do
  grep -F "  ok    $t" "$regress" >/dev/null || fail "regress.py: '$t' did not pass"
done
if [ "$ku_required" -eq 1 ]; then
  grep -F "  ok    $ku" "$regress" >/dev/null || fail "regress.py: '$ku' did not pass"
fi

echo "--- testcvs.py"
grep -E "failed \(|Terminating" "$testcvs" && fail "testcvs.py reported a failure"
grep -Fx '*info' "$testcvs" >/dev/null || fail "testcvs.py did not reach its last scenario (*info)"
for t in "Basic Add, Remove, Resurrect, Commit" "Basic binary Add/Checkout" "Binary remove and revert"; do
  grep -Fx "$t" "$testcvs" >/dev/null || fail "testcvs.py: scenario '$t' did not run"
done

[ $rc -eq 0 ] && echo "suite logs OK"
exit $rc
