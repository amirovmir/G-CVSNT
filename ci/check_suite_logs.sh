#!/usr/bin/env bash
# Assert that the suites ran to completion and that the cases behind the
# open PRs actually executed instead of being skipped.
#
#   check_suite_logs.sh <regress.log> <testcvs.log>
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

echo "--- regress.py"
grep -E '^[0-9]+ passed, 0 failed' "$regress" >/dev/null || fail "regress.py did not report zero failures"
grep -E '^\s+FAIL\s' "$regress" && fail "regress.py has FAIL lines"
if grep -q 'skipped' "$regress"; then
  grep 'skipped' "$regress"
  fail "regress.py skipped a case; every case must execute in CI"
fi
for t in "a -ku text file checks out with every line ending encoded" \
         "binary content is detected on add and import by content, not by name" \
         "binary file survives a commit/checkout round trip byte for byte"; do
  grep -F "  ok    $t" "$regress" >/dev/null || fail "regress.py: '$t' did not pass"
done

echo "--- testcvs.py"
grep -E "failed \(|Terminating" "$testcvs" && fail "testcvs.py reported a failure"
grep -Fx '*info' "$testcvs" >/dev/null || fail "testcvs.py did not reach its last scenario (*info)"
for t in "Basic Add, Remove, Resurrect, Commit" "Basic binary Add/Checkout" "Binary remove and revert"; do
  grep -Fx "$t" "$testcvs" >/dev/null || fail "testcvs.py: scenario '$t' did not run"
done

[ $rc -eq 0 ] && echo "suite logs OK"
exit $rc
