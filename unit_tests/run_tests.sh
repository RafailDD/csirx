#!/usr/bin/env bash
# Build and run the self-checking testbenches, keep going past failures, and
# collect the results:
#
#   build/logs/<test>.log   full compile + simulation output of each testbench
#   build/test_summary.txt  the summary table printed at the end
#   build/test-results.xml  JUnit XML (for CI test reporting)
#
# Usage: unit_tests/run_tests.sh [test ...]   (default: every test in TESTS)
# Normally invoked through `make test`. Exits non-zero if any test fails.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILDDIR="${BUILDDIR:-build}"
MAKE="${MAKE:-make}"
cd "$ROOT"

if [ $# -gt 0 ]; then
	tests=("$@")
else
	read -r -a tests <<< "${TESTS:-ecc_block ph_finder raw10_decoder pckthandler_fsm pckthandler wordalign axi_csi}"
fi

logdir="$BUILDDIR/logs"
rm -rf "$logdir"   # results always describe this run only
mkdir -p "$logdir"
build_abs="$(cd "$BUILDDIR" && pwd)"
summary="$BUILDDIR/test_summary.txt"
junit="$BUILDDIR/test-results.xml"

xml_escape() {
	sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

n_pass=0
n_fail=0
total_time=0
rows=()
cases=()

for t in "${tests[@]}"; do
	log="$logdir/$t.log"
	start=$(date +%s.%N)

	# Compile, then simulate; both go to the log
	if ! "$MAKE" -s --no-print-directory "$BUILDDIR/${t}_tb" > "$log" 2>&1; then
		result="ERROR"
		detail="compile failed (see $log)"
	else
		(cd unit_tests && vvp -n "$build_abs/${t}_tb" ${VVP_ARGS:-}) >> "$log" 2>&1
		status=$?
		if [ $status -eq 0 ] && grep -q '^PASS:' "$log"; then
			result="PASS"
			detail="$(sed -n 's/^PASS: .*(\([0-9]*\) checks).*/\1 checks/p' "$log" | head -1)"
		else
			result="FAIL"
			detail="$(grep -m1 '^FAIL @' "$log" || grep -m1 -E 'FATAL|FAIL|rror' "$log" || echo "exit status $status")"
		fi
	fi

	end=$(date +%s.%N)
	secs=$(awk -v a="$start" -v b="$end" 'BEGIN { printf "%.2f", b - a }')
	total_time=$(awk -v a="$total_time" -v b="$secs" 'BEGIN { printf "%.2f", a + b }')

	if [ "$result" = "PASS" ]; then
		n_pass=$((n_pass + 1))
		cases+=("  <testcase classname=\"csirx\" name=\"$t\" time=\"$secs\"/>")
	else
		n_fail=$((n_fail + 1))
		msg="$(printf '%s' "$detail" | xml_escape)"
		body="$(tail -n 40 "$log" | xml_escape)"
		cases+=("  <testcase classname=\"csirx\" name=\"$t\" time=\"$secs\"><failure message=\"$msg\">$body</failure></testcase>")
	fi

	line=$(printf '%-16s %-6s %7ss  %s' "$t" "$result" "$secs" "$detail")
	rows+=("$line")
	echo "$line"
done

{
	echo
	printf '%-16s %-6s %8s  %s\n' "TEST" "RESULT" "TIME" "DETAIL"
	printf '%s\n' "${rows[@]}"
	echo
	echo "$n_pass passed, $n_fail failed (${total_time}s). Logs: $logdir/"
} > "$summary"

{
	echo '<?xml version="1.0" encoding="UTF-8"?>'
	echo "<testsuite name=\"csirx\" tests=\"${#tests[@]}\" failures=\"$n_fail\" time=\"$total_time\">"
	printf '%s\n' "${cases[@]}"
	echo '</testsuite>'
} > "$junit"

tail -n 2 "$summary"
[ $n_fail -eq 0 ]
