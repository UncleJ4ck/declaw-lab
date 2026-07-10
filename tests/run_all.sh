#!/usr/bin/env bash
# Run the whole declaw-lab test suite: unit + parser fuzz, shell helpers + arg-fuzz,
# network fuzz, stress/leak regression, and the android monkey.
set -u
cd "$(dirname "$0")"
rc=0
run(){ local name="$1"; shift; echo; echo "### $name"; if "$@"; then :; else rc=1; fi; }

run "test_logic.py   (unit + parser fuzz)"        python3 test_logic.py
run "test_shell.sh   (helpers + arg-fuzz)"        bash    test_shell.sh
run "fuzz_mitm.py     (network fuzz)"             python3 fuzz_mitm.py
run "stress_mitm.py   (concurrency + fd/thread)"  python3 stress_mitm.py
run "monkey_app.sh    (android monkey)"           bash    monkey_app.sh

echo
echo "### RESULT: $([ $rc = 0 ] && echo 'ALL PASS' || echo 'SOME FAILED')"
exit $rc
