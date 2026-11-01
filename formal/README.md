# Experimental decision-to-execution model

This model explores two related questions about the authorization-to-execution
boundary. Formal-1 asked whether one request-gate ALLOW can precede two
execution occurrences. Formal-2 adds a second, motivated by runtime evidence
gathered after Formal-1 was written: whether the model can represent the
difference between a Guardian's own decision and the decision that actually
becomes effective for dispatch, including a timeout fallback and a Guardian
response that arrives too late to matter.

**AtMostOneExecutionPerDecision is experimental, not an identified ACS
normative requirement.** **EffectiveDecisionStable is implementation-derived
and experimentally supported, also not an identified ACS normative
requirement.** The model does not define an ACS authorization token or change
ACS semantics. Unsafe-model traces in this directory are deliberately
constructed counterexamples inside this abstraction; they are not claims
about the real ACS, AGT, or OpenCode implementation, and no runtime
experiment was performed in this Formal-2 phase itself.

## Why Formal-2 exists

Formal-1's `decision` variable conflated two things the runtime investigation
later showed are genuinely distinct: what the Guardian says, and what a host
actually uses to decide whether a tool call proceeds. Two prior phases
motivated separating them:

- **Phase 4E** (read-only source analysis of `packages/host-adapter/src`)
  established that a governed request's decision wait settles as a plain
  JavaScript Promise, exactly once; that on timeout it settles with
  `decisionArrived: false`; that the failure-posture resolution which follows
  is fully synchronous, with no further `await`; and that no code path in the
  adapter re-reads a Guardian response after that Promise has already
  settled. This is implementation analysis, not a runtime observation.
- **Phase 4F-v2** (one controlled runtime trial, external real Guardian, real
  OpenCode, real host adapter, genuine policy evaluation for every request
  except one deliberately delayed target) observed, for one governed
  `bash` invocation: the client's decision wait timed out; the negotiated
  failure posture resolved to PROCEED; the command executed; and the
  Guardian later emitted DENY for the very same request, which did not
  change the outcome. That report and its capture were
  not retained. The case was re-run on 2026-11-01 with a published capture:
  https://gist.github.com/AngeYobo/fe5cd44a864b4d54809cf1ded1e6d956
  (see "Runtime re-run" below). Classification there: `EFFECTIVE DECISION VALIDATED: PROCEED`.

Formal-2 refines the model so it can represent this distinction structurally,
rather than only describe it in prose. The refinement is motivated by these
two reports; it does not re-run them, and it does not strengthen either
report's own conclusions.

## Audit baseline

This work depends on the #113 host fixture identified in the task as
`carloshvp:agt-host-conformance-report`, inspected at
`ea1e3459c7a43d354bfd0f84391dee044b7a581f`. The pinned fixture's own
documentation references #92. This directory contains formal-model evidence
only; the runtime evidence Formal-2 responds to was gathered separately, in
Phase 4A through Phase 4F-v2, and is not reproduced here.

The authoritative audit classifications for the Formal-1 scope are unchanged:

| Property | Classification | Treatment |
| --- | --- | --- |
| P1: no execution without applicable approval | Unsupported as an unconditional ACS requirement | The scoped model allows execution only after an effective permit, but does not assert this as universal ACS behavior. |
| P2: request-gate DENY prevents invocation | Normative | `DenyPreventsInvocation`. |
| P3: executed invocation matches approved invocation | Derived | `InvocationMatchesApprovedInvocation`, using abstract identifier equality. Remains `UNMEASURED / UNRESOLVED` at the runtime level; see below. |
| P4: at most one execution per decision | Experimental | `AtMostOneExecutionPerDecision`. |
| P5: observing execution does not imply successful effect completion | Derived | Reachability of executed state with effect `UNKNOWN`. |
| P6: envelope replay differs from invocation re-execution | Derived/event-taxonomy distinction | Envelope replay is outside this model. |

Formal-2 adds one further classification, described in full below:

| Property | Classification | Treatment |
| --- | --- | --- |
| P7: effective decision, once settled, is not replaced by a later Guardian response | Implementation-derived / experimentally supported | `EffectiveDecisionStable`. Motivated by Phase 4E's source analysis and Phase 4F-v2's one controlled runtime trial; not an identified ACS normative requirement. |

P2 maps to [Instrument §6.4](../docs/spec/instrument/specification.md#64-honoring-decisions-normative).
That section also permits audited fail-open execution, which is why
unconditional P1 is unsupported and why this model represents a fallback
PROCEED path at all. P3 is derived from decision honoring and the
[pre-dispatch hook requirement](../docs/spec/instrument/hooks.md#toolcallrequest);
Formal-2 does not change P3's status, and the model's own
`InvocationMatchesApprovedInvocation` invariant is scoped to genuine ALLOW
only, deliberately not extended to the PROCEED path, where no approved
invocation exists to compare against (see below). P4 adds an experimental
guard; it is not a maintainer interpretation of ACS. P7 is new in Formal-2
and is deliberately not claimed as normative: no ACS specification text
establishing a late-decision-discard requirement was consulted before
writing it; it restates, as a checkable model property, what Phase 4E found
in source and what Phase 4F-v2 observed once at runtime.

## State and assumptions

Exactly one request lifecycle is modeled. Either abstract invocation `I` or
`J` can be submitted. These are distinct TLC model values, not strings or
commands. The string `"NONE"` is a separate sentinel. Equality of identifiers
is the entire invocation comparison; it does not define general ACS semantic
equivalence.

| Variable | Meaning |
| --- | --- |
| `request` | Submitted invocation identifier; fixed after submission. |
| `guardianDecision` | `NONE`, `ALLOW`, or `DENY`; what the Guardian itself answered, whenever it answered, issued once and never reevaluated. Its arrival is decoupled from whether it affects dispatch. |
| `effectiveDecision` | `NONE`, `ALLOW`, `DENY`, or `PROCEED`; the value actually consulted to permit or block dispatch. Settles once, either from a timely `guardianDecision` or from `Timeout`'s fallback PROCEED. |
| `effectiveDecisionAtSettlement` | Frozen copy of `effectiveDecision` taken at first settlement; bookkeeping this model needs to detect a later, illegitimate change. Not a wire field, token, or authorization object. |
| `approvedInvocation` | Copy of the request on a genuine, timely ALLOW; `NONE` otherwise, including throughout the PROCEED path, where nothing was ever approved. |
| `actualInvocation` | Identifier of the most recent invocation reaching the modeled tool. |
| `executionCount` | Number of execution occurrences, independently of effect completion. |
| `decisionUsed` | Experimental Boolean bookkeeping for the execution guard; not a wire field, token, or authorization object. |
| `effect` | Observed effect of the most recent occurrence: `NONE`, `UNKNOWN`, `SUCCESS`, or `FAILURE`. |

`executionCount` has type `Nat`. The transition relation bounds it to one in
the safe and late-unsafe configurations and two in the P4 unsafe
configuration. This provides a finite state space sufficient to witness a
second execution, not a proof about arbitrary repetition. Updating
`decisionUsed` and counting an execution are atomic in this sequential model.

### Guardian decision versus effective decision

This is the central Formal-2 distinction. `guardianDecision` and
`effectiveDecision` are separate variables so the model can represent a
Guardian answer that exists (is on record) without being the value dispatch
actually consulted. A logged or recorded Guardian decision does not
unconditionally imply it was effective; this directory's earlier runtime
phases (Phase 4D, Phase 4F.3, Phase 4F-v2) each had to establish that
distinction empirically, by reading Guardian-side evidence and separately
establishing what the client actually consumed, rather than assuming the
two were the same fact. The model now makes that same discipline structural:
`ReceiveGuardianAllow` and `ReceiveGuardianDeny` always set
`guardianDecision`, but only set `effectiveDecision` when it was still
`NONE` (a timely arrival) or, for `ReceiveGuardianDeny` alone, when
`PermitLateDecisionReplacement` is deliberately enabled (the late-unsafe
configuration). `ReceiveGuardianAllow` has no such bypass at all: nothing in
the two runtime investigations behind this refinement examined a late-ALLOW
replacement scenario, and this model does not assert one exists.

### Timeout and failure posture

`Timeout` is a distinct action, not a value collapsed into `guardianDecision
= "NONE"`. It requires `guardianDecision = "NONE" /\ effectiveDecision =
"NONE"` (genuinely still pending, nothing has arrived) and sets
`effectiveDecision' = "PROCEED"`. This distinguishes "no decision has
arrived yet" (`effectiveDecision = "NONE"`, `guardianDecision = "NONE"`)
from "waiting has already settled by fallback" (`effectiveDecision =
"PROCEED"`), which a bare `GuardianDecision = NONE` encoding could not have
told apart.

The model represents exactly one failure posture, PROCEED, because that is
the posture Phase 4F-v2 actually exercised at runtime
(`ACS_ON_DECISION_FAILURE=proceed`, `posture_source: "negotiated"` in that
run's own `audit.jsonl`). A DENY failure posture is a real, documented ACS
configuration this model does not currently represent; nothing here implies
PROCEED is the only correct or universally required posture, and extending
`Timeout` to a configurable fallback value is a candidate future refinement,
not implemented in this phase to keep the state space and the runtime
correspondence narrow and exact.

### Actions

- `SubmitRequest(i)` submits one identifier. No reset or second request is
  possible.
- `Timeout` settles `effectiveDecision` to `"PROCEED"` when nothing has
  arrived yet, and freezes `effectiveDecisionAtSettlement`.
- `ReceiveGuardianAllow` and `ReceiveGuardianDeny` record the Guardian's own
  answer in `guardianDecision`, and settle `effectiveDecision` (and freeze
  `effectiveDecisionAtSettlement`) only on a timely arrival, or, for DENY
  alone, when `PermitLateDecisionReplacement` deliberately permits an
  already-settled value to be overwritten.
- `InvokeMatchingTool` requires `effectiveDecision \in {"ALLOW", "PROCEED"}`
  (an explicit permit or the fallback) and records the first tool entry. It
  sets `actualInvocation'` to the approved invocation under a genuine ALLOW,
  or to the raw request under PROCEED, where nothing was approved. It sets
  the observed effect to `UNKNOWN`, without asserting completion.
- `InvokeDifferentTool(i)` represents an attempted mismatching dispatch,
  scoped to a genuine `effectiveDecision = "ALLOW"` only, unchanged in
  spirit from Formal-1: under PROCEED there is no approved identity to
  mismatch against at all (`approvedInvocation` stays `"NONE"`), so this
  action's own semantics do not extend there. Both configurations reject a
  mismatch with an unchanged state. The action name denotes an attempt, not
  a tool entry. Attempt history is deliberately not stored.
- `ObserveSuccess` and `ObserveFailure` represent evidence becoming
  available after execution. Neither issues a decision or increments the
  count.
- `LoseEffectEvidence` returns an observed success or failure to `UNKNOWN`.
  This changes knowledge, not the underlying real-world outcome.
- `AttemptSecondExecution` is enabled only when `PermitSecondExecution` is
  set, after the first execution. It reuses the same effective decision,
  increments the count to two, and resets effect knowledge to `UNKNOWN`.

In the safe and late-unsafe configurations a second dispatch is disabled;
temporal stuttering can represent a rejected attempt. An effective DENY
allows no execution action. Terminal DENY states are intentional, so all
three configurations set `CHECK_DEADLOCK FALSE`. There is no fairness or
eventual-execution guarantee. The checks establish safety in this model, not
that every permit eventually executes.

P3 compares the last actual identifier to the approved identifier, scoped to
`effectiveDecision = "ALLOW"` only. Every modeled execution under a genuine
ALLOW uses that same identifier; no invocation history is needed in this
restricted model. Under PROCEED, the invariant is vacuously satisfied
(its antecedent does not hold), which is the correct and deliberate
reflection of P3's own runtime status: `P3 = UNMEASURED / UNRESOLVED`. This
refinement does not strengthen that status. It would need reconsideration
before admitting arbitrary substitutions or multiple lifecycles.

### Exclusions and evidence limits

ASK, MODIFY, DEFER, concurrency, crashes, retries, distributed execution,
multiple requests, and multiple decisions are excluded. A configurable
DENY failure posture is excluded (see above). Signatures, envelope IDs,
timestamps, nonce checks, envelope replay, and real host dispatch are also
excluded. `AttemptSecondExecution` does not submit an envelope and is not a
test of §10.3 replay rejection.

`NONE` means no execution effect is yet associated with this lifecycle;
`UNKNOWN` means execution is observed but completion is not established.
The effect domain is experimental observation vocabulary, not an alteration
of the ACS result schema's `exit_status` enum. Tool entry is distinct from
successful completion. In the unsafe models, effect observations concern the
latest occurrence only; there is no effect history or cross-occurrence
attribution model.

The audit found `execution_id` in hook prose but optional `request_id_ref`
in the result schema. Abstract identifiers avoid choosing between these
representations; the mismatch remains unresolved for later implementation
work. No maintainer interpretation of consumable decisions is assumed.

**Fixture evidence-lifecycle limitation, explicitly not modeled**: Phase
4F-v2's own runtime report also records that the dogfood fixture's own
post-run validation reported `Incomplete wire exchange`, because it read
external Guardian evidence before an independently, deliberately delayed
Guardian response had finished writing. This is a harness/evidence-capture
timing artifact of that specific experimental fixture, not an ACS
authorization transition, and it is deliberately not represented anywhere in
this model. The fixture itself was not modified to address it, in this
phase or any prior one.

### Stuttering

`InvokeDifferentTool` can stutter under states where no invocation other
than the approved one is available to attempt (`Invocations` has only one
member other than the approved identity, or the guard is otherwise
unsatisfiable), a characteristic already present in Formal-1 and unchanged
by this refinement beyond renaming the variable its guard reads. This
refinement does not redesign liveness or fairness; no fairness or liveness
machinery was added. This remains a safety-only model.

## Properties

| Property | Classification | Basis |
| --- | --- | --- |
| `TypeOK` | Model structural invariant | Type discipline for the abstraction's own variables. |
| `DenyPreventsInvocation` | Normative | Instrument §6.4. |
| `InvocationMatchesApprovedInvocation` | Derived | Scoped to genuine ALLOW; vacuous under PROCEED, matching P3's unresolved status. |
| `AtMostOneExecutionPerDecision` | Experimental | Not an identified ACS normative requirement. |
| `EffectiveDecisionStable` | Implementation-derived / experimentally supported | Phase 4E source analysis plus Phase 4F-v2's one controlled runtime trial. Not an identified ACS normative requirement; no normative text was consulted to establish it as one. |
| `NoExecutedUnknown` | Diagnostic | Reachability witness only, not a safety property. |
| `NoLateDenyAfterProceedSettlement` | Diagnostic | Reachability witness only, establishing `EffectiveDecisionStable`'s non-vacuity in the safe configuration. |

## TLC verification

Runs completed on 2026-09-16 using the same toolchain as Formal-1:

- TLC2 **2.19**, 08 August 2024, revision **5a47802**, from
  `/home/ange/tla/tla2tools.jar` (SHA-256
  `936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88`); this
  distribution also parsed and semantically checked the refined TLA+ module.
- Java **Ubuntu 17.0.20**, x86_64, as reported by TLC; one worker.
- Linux **6.6.87.2-microsoft-standard-WSL2**, amd64.
- Breadth-first exploration; no symmetry reduction or state constraint.

All commands below ran from `/home/ange/agent-control-standard/formal`. To reproduce, run them from `formal/` with `TLA_JAR` set to your `tla2tools.jar`.
Generated TLC state data and diagnostic configurations were kept in `/tmp`.

### Safe configuration

```sh
java -cp "$TLA_JAR" tlc2.TLC -workers 1 -metadir /tmp/acs-formal2-safe -config ACSAuthorizationExecution.cfg ACSAuthorizationExecution.tla
```

`PermitSecondExecution = FALSE`; `PermitLateDecisionReplacement = FALSE`;
`Invocations = {I, J}`.

```text
Model checking completed. No error has been found.
67 states generated, 37 distinct states found, 0 states left on queue.
The depth of the complete state graph search is 6.
```

All configured invariants passed: `TypeOK`, `DenyPreventsInvocation`,
`InvocationMatchesApprovedInvocation`, `AtMostOneExecutionPerDecision`, and
`EffectiveDecisionStable` (since Formal-3 the configuration also checks
`DispatchedDecisionStable` and `DispatchedUnderPermit`, with the same result).
TLC exited with status 0. This is a finite model
result, not an ACS conformance assessment or an implementation
verification. The larger state count relative to Formal-1 (67 vs. 19
generated, 37 vs. 13 distinct, depth 6 vs. 5) reflects the added `Timeout`,
`ReceiveGuardianAllow`, and `ReceiveGuardianDeny` branching, including the
timely-ALLOW, timely-DENY, timeout-PROCEED, and late-decision-observed
paths all being reachable within the same bounded, single-cycle abstraction.

### P4 unsafe configuration (preserved)

```sh
java -cp "$TLA_JAR" tlc2.TLC -workers 1 -metadir /tmp/acs-formal2-p4-unsafe -config ACSAuthorizationExecution-unsafe.cfg ACSAuthorizationExecution.tla
```

`PermitSecondExecution = TRUE`; `PermitLateDecisionReplacement = FALSE`;
otherwise the same configured invariants and invocation domain.

```text
Error: Invariant AtMostOneExecutionPerDecision is violated.
26 states generated, 22 distinct states found, 9 states left on queue.
The depth of the complete state graph search is 5.
```

```text
State 1: Init
State 2: SubmitRequest(I)
State 3: Timeout                      (effectiveDecision -> PROCEED)
State 4: InvokeMatchingTool           (executionCount -> 1)
State 5: AttemptSecondExecution       (executionCount -> 2)
```

This reproduces the Formal-1 counterexample's property violation
(`AtMostOneExecutionPerDecision` fails at `executionCount = 2`), but through
a different witness trace than Formal-1's own recorded one (which went
`SubmitRequest -> EvaluateAllow -> InvokeMatchingTool ->
AttemptSecondExecution`). This is an expected, disclosed consequence of
adding `Timeout` as a new, equally-shallow path to an effective permit:
breadth-first search reports the first violation it reaches, and the
`Timeout`-based trace is exactly as short as the original ALLOW-based one.
The original ALLOW-based trace remains reachable in this same configuration
(`ReceiveGuardianAllow` is unconditionally enabled at the same point
`Timeout` is); TLC simply did not report it as this run's particular
witness. The configuration, its constants, and its invariant list are
otherwise unchanged from Formal-1. TLC exited with status 0 for the
reported error path (see raw output for the tool's own exit convention);
this counterexample concerns the deliberately unsafe formal model only. It
is not evidence of an ACS or AGT vulnerability, and it is not a claim that
the real implementation permits a second execution.

### Late-decision-replacement unsafe configuration (new)

```sh
java -cp "$TLA_JAR" tlc2.TLC -workers 1 -metadir /tmp/acs-formal2-late-unsafe -config ACSAuthorizationExecution-late-unsafe.cfg ACSAuthorizationExecution.tla
```

`PermitSecondExecution = FALSE`; `PermitLateDecisionReplacement = TRUE`;
otherwise the same configured invariants and invocation domain. This
configuration is kept separate from the P4 unsafe configuration
deliberately, so the two counterexamples (execution cardinality failure and
effective-decision replacement failure) remain independently legible,
per this project's own established practice of not making one unsafe
configuration serve two unrelated counterexamples.

```text
Error: Invariant EffectiveDecisionStable is violated.
11 states generated, 11 distinct states found, 6 states left on queue.
The depth of the complete state graph search is 4.
```

```text
State 1: Init
State 2: SubmitRequest(I)
State 3: Timeout               (effectiveDecision -> PROCEED, frozen at settlement)
State 4: ReceiveGuardianDeny   (guardianDecision -> DENY; PermitLateDecisionReplacement
                                 allows effectiveDecision -> DENY too, diverging from
                                 the frozen settlement value "PROCEED")
```

This is exactly the conceptual trace this phase was designed to demonstrate:
`request -> timeout -> effective PROCEED -> late DENY -> effective
incorrectly changes to DENY`. This is a deliberately unsafe model transition
used to show `EffectiveDecisionStable` is a meaningful, non-vacuous
property, not evidence that this transition exists in the real ACS
implementation. Phase 4E and Phase 4F-v2 both found the opposite: no code
path re-reads a settled decision, and the one tested runtime trial showed
the late DENY did not become effective.

### UNKNOWN reachability (preserved)

```sh
cp ACSAuthorizationExecution.cfg /tmp/acs-formal2-unknown.cfg
printf '\nINVARIANT NoExecutedUnknown\n' >> /tmp/acs-formal2-unknown.cfg
java -cp "$TLA_JAR" tlc2.TLC -workers 1 -metadir /tmp/acs-formal2-unknown-run -config /tmp/acs-formal2-unknown.cfg ACSAuthorizationExecution.tla
```

```text
Error: Invariant NoExecutedUnknown is violated.
12 states generated, 12 distinct states found, 7 states left on queue.
The depth of the complete state graph search is 4.
```

TLC exited with the expected diagnostic violation. The witness reaches
`InvokeMatchingTool` via `Timeout` this time (rather than
`ReceiveGuardianAllow`, as in Formal-1's own recorded witness), for the same
breadth-first-search reason noted for the P4 unsafe configuration above.
`executionCount > 0 /\ effect = "UNKNOWN"` is satisfied either way. An
execution occurrence still does not logically imply observed success in
this model.

### Late-decision reachability (new)

```sh
cp ACSAuthorizationExecution.cfg /tmp/acs-formal2-latewitness.cfg
printf '\nINVARIANT NoLateDenyAfterProceedSettlement\n' >> /tmp/acs-formal2-latewitness.cfg
java -cp "$TLA_JAR" tlc2.TLC -workers 1 -metadir /tmp/acs-formal2-latewitness-run -config /tmp/acs-formal2-latewitness.cfg ACSAuthorizationExecution.tla
```

```text
Error: Invariant NoLateDenyAfterProceedSettlement is violated.
11 states generated, 11 distinct states found, 6 states left on queue.
The depth of the complete state graph search is 4.
```

```text
State 4: effectiveDecision = "PROCEED", guardianDecision = "DENY"
```

TLC exited with the expected diagnostic violation. This witness establishes
that the safe configuration can actually reach a state where the effective
decision has already settled to PROCEED via timeout while a late Guardian
DENY is simultaneously on record for the same request, and that
`effectiveDecision` correctly remains `"PROCEED"` there (unlike the
late-unsafe configuration's own counterexample). This is the non-vacuity
demonstration `EffectiveDecisionStable`'s safe-configuration pass depends
on: the property is not merely true because its interesting precondition is
unreachable.

## Runtime trace correspondence (abstraction only)

This table maps Phase 4F-v2's own runtime observation onto the refined safe
model's actions and states. It is an abstraction correspondence, not a claim
of one-to-one implementation equivalence; the model has no notion of
milliseconds, HTTP, JSON-RPC, processes, or the specific `bash` tool.

| Runtime observation (Phase 4F-v2) | Formal-2 transition/state |
| --- | --- |
| `steps/toolCallRequest` emitted for the targeted invocation | `SubmitRequest(i)` |
| Client-side decision wait, no response yet | `effectiveDecision = "NONE"`, `guardianDecision = "NONE"` |
| Client timeout at ~5.007s (`audit.jsonl` `failure.kind: "timeout"`) | `Timeout` |
| Failure posture resolves to PROCEED (`posture: "proceed"`, `outcome: "proceeded"`) | `effectiveDecision' = "PROCEED"`, frozen into `effectiveDecisionAtSettlement` |
| Dispatch released, tool runs | `InvokeMatchingTool` |
| `allowed.txt` effect observed | `effect' = "UNKNOWN"` (this model does not itself distinguish `SUCCESS`; `ObserveSuccess` would be the next step if modeled at that granularity) |
| Guardian's delayed response, `decision=deny`, same `rpc_id`, sent after settlement | `ReceiveGuardianDeny` with `PermitLateDecisionReplacement = FALSE` (the safe configuration) |
| DENY did not become effective for the already-settled invocation | `effectiveDecision` remains `"PROCEED"`; `guardianDecision = "DENY"` is recorded separately |

### Runtime re-run (2026-11-01)

Same case, re-captured: OpenCode 1.18.30, Bun 1.3.11, an unmodified Guardian
from the fixture at `ea1e345` (run in `ubuntu:24.04` for glibc 2.39), posture
`proceed`, timeout 5000 ms, one `steps/toolCallRequest` held 8 s before it
reached the Guardian. Host audit: `timeout`, `proceeded` at 12:29:59.705Z; the
command ran; the Guardian answered `deny` at 12:30:02.837Z for the same
`rpc_id`. It also received the `toolCallResult` for that call before the
request itself, with no reference linking the two. The fixture's own check
failed with `Unexpected hook coverage` for the same evidence-timing reason as
above. Capture, timeline and SHA-256:
https://gist.github.com/AngeYobo/fe5cd44a864b4d54809cf1ded1e6d956

## Limitations

This remains a bounded, single-request-lifecycle abstraction, extended but
not fundamentally restructured. It does not model concurrency, multiple
simultaneous requests, retries, a configurable DENY failure posture,
session/handshake negotiation, or the fixture-level evidence-lifecycle
artifact Phase 4F-v2 separately observed (see Exclusions, above). The P4
unsafe configuration's own witness trace changed (though not its
conclusion) as a side effect of adding `Timeout` as an equally-shallow
alternative path to an effective permit; this is disclosed rather than
silently accepted. No liveness or fairness property is checked. TLC's
breadth-first exploration in this small, finite abstraction does not
generalize to a claim about the real system's behavior under load, timing
variation, or repeated requests.

## Formal-3: settlement versus dispatch

Formal-2 settles the effective decision in `Timeout` and enters the tool later,
in `InvokeMatchingTool`. Those are separate steps, so the model contains a
window that Phase 4E did not find in the OpenCode adapter: a Guardian answer
can arrive after the fallback has settled but before any tool entry. The
`late-unsafe` counterexample lands in that window (its State 4 has
`executionCount = 0`): the late DENY replaces PROCEED before anything ran. Read
on its own, that trace shows a late DENY *blocking* an action, which is not
obviously unsafe. Formal-3 separates the two questions.

### What changed

- `effectiveDecisionAtDispatch`: frozen copy of `effectiveDecision`, taken in
  `InvokeMatchingTool`, i.e. the value actually consulted when the tool was
  entered. Bookkeeping, not a wire field.
- `CommitAtDispatch` (constant): what a DENY arriving inside the window does.
  - `FALSE`, *commit at settlement*: the settled value is final. This is the
    Formal-2 behaviour and what Phase 4E found in source, where settlement and
    dispatch release are synchronous so the window is empty.
  - `TRUE`, *commit at dispatch*: a DENY arriving after settlement and before
    tool entry replaces the fallback and blocks. A design alternative, not an
    ACS rule.
- `DispatchedDecisionStable`: once the tool has been entered, the effective
  decision is the one that dispatched. `DispatchedUnderPermit`: what
  dispatched was ALLOW or PROCEED.
- Diagnostics `NoLateDenyAfterDispatch` and `NoLateDenyBeforeDispatch`.

All Formal-2 actions, constants and invariants are unchanged apart from the
added variable; the late-DENY branch gains one disjunct,
`CommitAtDispatch /\ executionCount = 0`.

### Results

Toolchain: TLC2 2.19 of 08 August 2024 (rev 5a47802), openjdk version "17.0.11" 2024-04-16,
Linux 6.6.87.2-microsoft-standard-WSL2, one worker, breadth-first, no symmetry
or constraint, run with `./check-formal3.sh` on 2026-11-01. Cross-checked with
TLC2 2026.10.30 (rev 090e85c) on OpenJDK 21: identical verdicts and identical
state counts for all eleven checks. Formal-2's three
configurations reproduce exactly (67/37/6; AtMostOne at depth 5;
EffectiveDecisionStable at depth 4), now also checking the two new
invariants.

| Configuration | Result |
| --- | --- |
| safe (`CommitAtDispatch = FALSE`) | No error. 67 generated, 37 distinct, depth 6. |
| `-commit-at-dispatch` | No error on TypeOK, DenyPreventsInvocation, InvocationMatchesApprovedInvocation, AtMostOne, DispatchedDecisionStable, DispatchedUnderPermit. 65 / 37, depth 6. `EffectiveDecisionStable` is deliberately not listed: under this choice it is expected to fail (below). |
| `-late-after-dispatch-unsafe` (`PermitLateDecisionReplacement = TRUE`) | `DispatchedDecisionStable` violated at depth 5. |

Traces (`effective`, `count`, `atDispatch`, `guardian`):

```text
late-after-dispatch-unsafe     -- the replacement Formal-3 rules out
  3 Timeout              PROCEED  0  NONE     NONE
  4 InvokeMatchingTool   PROCEED  1  PROCEED  NONE
  5 ReceiveGuardianDeny  DENY     1  PROCEED  DENY     <- record now says DENY for a tool that ran

commit-at-dispatch, diagnostic EffectiveDecisionStable   -- by design
  3 Timeout              PROCEED  0  NONE     NONE
  4 ReceiveGuardianDeny  DENY     0  NONE     DENY     <- DENY in the window blocks; nothing ran

commit-at-dispatch, diagnostic NoLateDenyAfterDispatch   -- the Phase 4F-v2 runtime case
  3 Timeout              PROCEED  0  NONE     NONE
  4 InvokeMatchingTool   PROCEED  1  PROCEED  NONE
  5 ReceiveGuardianDeny  PROCEED  1  PROCEED  DENY     <- ran under PROCEED; DENY recorded, not effective

safe, diagnostic NoLateDenyAfterDispatch
  3 Timeout              PROCEED  0  NONE     NONE
  4 ReceiveGuardianDeny  PROCEED  0  NONE     DENY     <- DENY already known ...
  5 InvokeMatchingTool   PROCEED  1  PROCEED  DENY     <- ... and the tool still runs
```

The post-dispatch transitions are identical under both values of
`CommitAtDispatch` (the extra disjunct requires `executionCount = 0`), so the
`commit-at-dispatch` trace above is also reachable in the safe configuration;
breadth-first search simply reports the shorter window trace first there.

### What this says about #435

1. **After dispatch** a late decision cannot change what ran, under either
   choice. What remains is the record: `DispatchedDecisionStable` is the
   statement that the effective decision is the one that dispatched, and the
   Guardian's own answer is kept separately (`guardianDecision`). The
   `late-after-dispatch-unsafe` trace is what a record keyed on "last value
   received" would look like.
2. **Between settlement and dispatch** the two choices genuinely differ. Commit
   at settlement lets a tool run although its DENY is already on record (last
   trace above). Commit at dispatch blocks it. Phase 4E says the OpenCode
   adapter has no such window, so the question does not arise there; it can
   arise for any host that settles and dispatches in separate steps. That is a
   choice for the specification, not something this model decides.

### Commands

`./check-formal3.sh [path/to/tla2tools.jar]` runs all eleven checks (five
configurations, six diagnostics) and flags any result that differs from
`EXPECTED.txt`. TLC output goes to `~/acs-evidence/`. The loop below does the
same for the configurations only.

```sh
for c in ACSAuthorizationExecution.cfg ACSAuthorizationExecution-unsafe.cfg \
         ACSAuthorizationExecution-late-unsafe.cfg \
         ACSAuthorizationExecution-commit-at-dispatch.cfg \
         ACSAuthorizationExecution-late-after-dispatch-unsafe.cfg; do
  java -cp "$TLA_JAR" tlc2.TLC -workers 1 -config "$c" ACSAuthorizationExecution.tla
done
```

Diagnostics append one invariant to a copy of a configuration, as in the
Formal-2 commands above: `NoLateDenyAfterDispatch` and
`NoLateDenyBeforeDispatch` to the safe configuration, `EffectiveDecisionStable`
and `NoLateDenyAfterDispatch` to `-commit-at-dispatch`.

## P3 status

`P3 = UNMEASURED / UNRESOLVED`, unchanged by this refinement.
`InvocationMatchesApprovedInvocation` remains scoped to genuine ALLOW and is
vacuously satisfied under PROCEED, which is the correct reflection of P3's
own status: this model does not claim, and this refinement does not
introduce any claim, that an executed invocation under fallback PROCEED
matches anything that was actually approved, because nothing was approved
on that path.

## P4 status

`P4 = EXPERIMENTAL`, unchanged by this refinement.
`AtMostOneExecutionPerDecision` is still demonstrably violated in a
deliberately unsafe configuration, with `PermitSecondExecution` gating the
same experimental bypass Formal-1 defined. This is not converted into a
normative ACS requirement by this refinement, and the ability to reason
about execution cardinality is preserved (see the P4 unsafe configuration's
own results above).
