#!/usr/bin/env bash
# Run every Formal-3 configuration and diagnostic with TLC; print one line each.
# Usage (from formal/): ./check-formal3.sh [path/to/tla2tools.jar]
set -uo pipefail
cd "$(dirname "$0")"
JAR="${1:-$HOME/tla/tla2tools.jar}"
M=ACSAuthorizationExecution
OUT="$HOME/acs-evidence/tlc-formal3-$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$OUT/cfg" "$OUT/meta"
[[ -f "$JAR" ]] || { echo "TLC jar not found at $JAR"; exit 1; }

diag() { # base cfg, extra invariant, name
  cp "$1" "$OUT/cfg/$3.cfg"; printf '    %s\n' "$2" >> "$OUT/cfg/$3.cfg"; echo "$OUT/cfg/$3.cfg"; }

run() { # cfg, expectation
  local name; name=$(basename "$1" .cfg)
  java -cp "$JAR" tlc2.TLC -workers 1 -metadir "$OUT/meta/$name" -config "$1" $M.tla > "$OUT/$name.out" 2>&1
  local res stats
  res=$(grep -oE "No error has been found|Invariant [A-Za-z]+ is violated" "$OUT/$name.out" | head -1)
  stats=$(grep -oE "[0-9]+ states generated, [0-9]+ distinct" "$OUT/$name.out" | head -1)
  printf '%-48s %-50s %s\n' "$name" "${res:-ERROR, see $OUT/$name.out}" "$stats"
  [[ "$res" == *"$2"* ]] || echo "   !! expected: $2"
}

echo "TLC: $(java -cp "$JAR" tlc2.TLC -workers 1 -config $M.cfg $M.tla 2>&1 | grep -m1 'TLC2 Version')"
run $M.cfg                                  "No error"
run $M-unsafe.cfg                           "AtMostOneExecutionPerDecision"
run $M-late-unsafe.cfg                      "EffectiveDecisionStable"
run $M-commit-at-dispatch.cfg               "No error"
run $M-late-after-dispatch-unsafe.cfg       "DispatchedDecisionStable"
run "$(diag $M.cfg NoExecutedUnknown diag-safe-unknown)"                         "NoExecutedUnknown"
run "$(diag $M.cfg NoLateDenyAfterProceedSettlement diag-safe-late)"            "NoLateDenyAfterProceedSettlement"
run "$(diag $M.cfg NoLateDenyAfterDispatch diag-safe-after-dispatch)"           "NoLateDenyAfterDispatch"
run "$(diag $M.cfg NoLateDenyBeforeDispatch diag-safe-before-dispatch)"         "NoLateDenyBeforeDispatch"
run "$(diag $M-commit-at-dispatch.cfg EffectiveDecisionStable diag-cad-stable)" "EffectiveDecisionStable"
run "$(diag $M-commit-at-dispatch.cfg NoLateDenyAfterDispatch diag-cad-after)"  "NoLateDenyAfterDispatch"
echo "full TLC output: $OUT"
