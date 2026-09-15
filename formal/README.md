# Experimental decision-to-execution model

This model explores whether one request-gate ALLOW can precede two execution
occurrences. The safe configuration prevents this; the deliberately unsafe
configuration permits it. **AtMostOneExecutionPerDecision is experimental, not
an identified ACS normative requirement.** The model does not define an ACS
authorization token or change ACS semantics.

## Audit baseline

This work depends on the #113 host fixture identified in the task as
`carloshvp:agt-host-conformance-report`, inspected at
`ea1e3459c7a43d354bfd0f84391dee044b7a581f`. The pinned fixture's own documentation
references #92. This directory contains formal-model evidence only; no AGT or
OpenCode execution experiment was performed here.

The authoritative audit classifications for this experiment are:

| Property | Classification | Treatment |
| --- | --- | --- |
| P1: no execution without applicable approval | Unsupported as an unconditional ACS requirement | The scoped model allows execution only after ALLOW, but does not assert this as universal ACS behavior. |
| P2: request-gate DENY prevents invocation | Normative | `DenyPreventsInvocation`. |
| P3: executed invocation matches approved invocation | Derived | `InvocationMatchesApprovedInvocation`, using abstract identifier equality. |
| P4: at most one execution per decision | Experimental | `AtMostOneExecutionPerDecision`. |
| P5: observing execution does not imply successful effect completion | Derived | Reachability of executed state with effect `UNKNOWN`. |
| P6: envelope replay differs from invocation re-execution | Derived/event-taxonomy distinction | Envelope replay is outside this model. |

P2 maps to [Instrument §6.4](../docs/spec/instrument/specification.md#64-honoring-decisions-normative).
That section also permits audited fail-open execution, which is why unconditional
P1 is unsupported. P3 is derived from decision honoring and the
[pre-dispatch hook requirement](../docs/spec/instrument/hooks.md#toolcallrequest).
P4 adds an experimental guard; it is not a maintainer interpretation of ACS.
Envelope replay has its own [§10.3 requirement](../docs/spec/instrument/specification.md#103-replay-protection).
A real implementation that skips a required hook must be assessed against that
requirement separately from experimental P4.

## State and assumptions

Exactly one request lifecycle is modeled. Either abstract invocation `I` or `J`
can be submitted. These are distinct TLC model values, not strings or commands.
The string `"NONE"` is a separate sentinel. Equality of identifiers is the entire
invocation comparison; it does not define general ACS semantic equivalence.

| Variable | Meaning |
| --- | --- |
| `request` | Submitted invocation identifier; fixed after submission. |
| `decision` | `NONE`, `ALLOW`, or `DENY`; issued once and never reevaluated. |
| `approvedInvocation` | Copy of the request on ALLOW; `NONE` otherwise. |
| `actualInvocation` | Identifier of the most recent invocation reaching the modeled tool. |
| `executionCount` | Number of execution occurrences, independently of effect completion. |
| `decisionUsed` | Experimental Boolean bookkeeping for the execution guard; not a wire field, token, or authorization object. |
| `effect` | Observed effect of the most recent occurrence: `NONE`, `UNKNOWN`, `SUCCESS`, or `FAILURE`. |

`executionCount` has type `Nat`. The transition relation bounds it to one in the
safe configuration and two in the unsafe configuration. This provides a finite
state space sufficient to witness a second execution, not a proof about arbitrary
repetition. Updating `decisionUsed` and counting an execution are atomic in this
sequential model.

### Actions

- `SubmitRequest(i)` submits one identifier. No reset or second request is possible.
- `EvaluateAllow` copies the request to `approvedInvocation`; `EvaluateDeny`
  leaves that field empty. Both are separate from tool entry.
- `InvokeMatchingTool` requires an unused ALLOW and records the first tool entry.
  It sets the observed effect to `UNKNOWN`, without asserting completion.
- `InvokeDifferentTool(i)` represents an attempted mismatching dispatch. Both
  configurations reject it with an unchanged state. The action name denotes an
  attempt, not a tool entry. Attempt history is deliberately not stored.
- `ObserveSuccess` and `ObserveFailure` represent evidence becoming available
  after execution. Neither issues a decision or increments the count.
- `LoseEffectEvidence` returns an observed success or failure to `UNKNOWN`.
  This changes knowledge, not the underlying real-world outcome.
- `AttemptSecondExecution` is enabled only in the unsafe configuration, after
  the first execution. It reuses the same approved identifier and decision,
  increments the count to two, and resets effect knowledge to `UNKNOWN`.

In the safe configuration a second dispatch is disabled; temporal stuttering can
represent a rejected attempt. DENY allows no execution action. Terminal DENY
states are intentional, so both configurations set `CHECK_DEADLOCK FALSE`.
There is no fairness or eventual-execution guarantee. The checks establish
safety in this model, not that every ALLOW eventually executes.

P3 compares the last actual identifier to the approved identifier. Every modeled
execution uses that same identifier; no invocation history is needed in this
restricted model. This would need reconsideration before admitting arbitrary
substitutions or multiple lifecycles.

### Exclusions and evidence limits

ASK, MODIFY, DEFER, failure-posture negotiation, concurrency, crashes, retries,
distributed execution, multiple requests, and multiple decisions are excluded.
Signatures, envelope IDs, timestamps, nonce checks, envelope replay, and real
host dispatch are also excluded. `AttemptSecondExecution` does not submit an
envelope and is not a test of §10.3 replay rejection.

`NONE` means no execution effect is yet associated with this lifecycle; `UNKNOWN`
means execution is observed but completion is not established. The effect domain
is experimental observation vocabulary, not an alteration of the ACS result
schema's `exit_status` enum. Tool entry is distinct from successful completion.
In the unsafe model, effect observations concern the latest occurrence only;
there is no effect history or cross-occurrence attribution model.

The audit found `execution_id` in hook prose but optional `request_id_ref` in the
result schema. Abstract identifiers avoid choosing between these representations;
the mismatch remains unresolved for later implementation work. No maintainer
interpretation of consumable decisions is assumed.

## TLC verification

Runs completed on 2026-09-15 using:

- TLC2 **2.19**, 08 August 2024, revision **5a47802**, from
  `/home/ange/tla/tla2tools.jar`; this distribution also parsed and semantically
  checked the TLA+ module.
- Java **Ubuntu 17.0.20**, x86_64, as reported by TLC; one worker.
- Linux **6.6.87.2-microsoft-standard-WSL2**, amd64.
- Breadth-first exploration; no symmetry reduction or state constraint.

All commands below ran from `/home/ange/agent-control-standard/formal`.
Generated TLC state data and the diagnostic configuration were kept in `/tmp`.
Initial sandboxed attempts parsed successfully but failed before exploration
because Java RMI could not open its listener (`SocketException: Operation not
permitted`). The same TLC commands completed with the required execution
permission. Counts below come from those completed runs, not the failed starts.

### Safe configuration

```sh
java -cp /home/ange/tla/tla2tools.jar tlc2.TLC -workers 1 -metadir /tmp/acs-phase2-safe -config ACSAuthorizationExecution.cfg ACSAuthorizationExecution.tla
```

`PermitSecondExecution = FALSE`; `Invocations = {I, J}`.

```text
Model checking completed. No error has been found.
19 states generated, 13 distinct states found, 0 states left on queue.
The depth of the complete state graph search is 5.
```

All configured invariants passed: `TypeOK`, `DenyPreventsInvocation`,
`InvocationMatchesApprovedInvocation`, and `AtMostOneExecutionPerDecision`.
TLC exited with status 0. This is a finite model result, not an ACS conformance
assessment or an implementation verification.

### Deliberately unsafe configuration

```sh
java -cp /home/ange/tla/tla2tools.jar tlc2.TLC -workers 1 -metadir /tmp/acs-phase2-unsafe -config ACSAuthorizationExecution-unsafe.cfg ACSAuthorizationExecution.tla
```

`PermitSecondExecution = TRUE`; otherwise the same configured invariants and
invocation domain.

```text
Error: Invariant AtMostOneExecutionPerDecision is violated.
14 states generated, 12 distinct states found, 3 states left on queue.
The depth of the complete state graph search is 5.
```

The following table transcribes every variable in TLC's counterexample. `NONE`,
`ALLOW`, and `UNKNOWN` denote the corresponding string values; `I` is a model value.

| State/action | request | decision | approvedInvocation | actualInvocation | executionCount | decisionUsed | effect |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1: Init | NONE | NONE | NONE | NONE | 0 | FALSE | NONE |
| 2: SubmitRequest(I) | I | NONE | NONE | NONE | 0 | FALSE | NONE |
| 3: EvaluateAllow | I | ALLOW | I | NONE | 0 | FALSE | NONE |
| 4: InvokeMatchingTool | I | ALLOW | I | I | 1 | TRUE | UNKNOWN |
| 5: AttemptSecondExecution | I | ALLOW | I | I | 2 | TRUE | UNKNOWN |

There is one evaluation and two execution occurrences. The experimental invariant
fails at state 5; TLC exited with status 12. TLC reported no violation of the other configured invariants
before stopping, but this run did not exhaust the unsafe state space; those
invariants are not reported as exhaustively verified for that configuration.
This counterexample concerns the deliberately unsafe formal model only. It is
not evidence of an ACS or AGT vulnerability.

### UNKNOWN reachability

`NoExecutedUnknown` is a diagnostic predicate, intentionally absent from both
committed configurations. Checking the negation of the desired reachable state
as a temporary invariant makes TLC return a witness. Its expected violation is
not a failure of an intended safety property.

```sh
cp ACSAuthorizationExecution.cfg /tmp/acs-phase2-unknown.cfg
printf '\nINVARIANT NoExecutedUnknown\n' >> /tmp/acs-phase2-unknown.cfg
java -cp /home/ange/tla/tla2tools.jar tlc2.TLC -workers 1 -metadir /tmp/acs-phase2-unknown -config /tmp/acs-phase2-unknown.cfg ACSAuthorizationExecution.tla
```

```text
Error: Invariant NoExecutedUnknown is violated.
9 states generated, 8 distinct states found, 3 states left on queue.
The depth of the complete state graph search is 4.
```

TLC exited with status 12, the expected diagnostic violation.
The witness is states 1–4 of the table above, under the safe configuration.
State 4 satisfies `executionCount > 0 /\ effect = "UNKNOWN"`. Thus an execution
occurrence does not logically imply observed success in this model. This
reachability check stops at its witness and is separate from the completed safe
invariant check.
