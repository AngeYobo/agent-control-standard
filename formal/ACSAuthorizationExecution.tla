--------------------- MODULE ACSAuthorizationExecution ---------------------
EXTENDS Naturals

CONSTANTS Invocations, PermitSecondExecution, PermitLateDecisionReplacement, CommitAtDispatch
ASSUME /\ Invocations # {} /\ "NONE" \notin Invocations
       /\ PermitSecondExecution \in BOOLEAN
       /\ PermitLateDecisionReplacement \in BOOLEAN
       /\ CommitAtDispatch \in BOOLEAN
\* decisionUsed is experimental bookkeeping, not an ACS authorization artifact.
\* guardianDecision is what the Guardian said, whenever it said it -- arrival
\* is decoupled from effect on dispatch. effectiveDecision is the value
\* actually consulted to permit or block dispatch; it settles once, either
\* from a timely guardianDecision (arriving while effectiveDecision is still
\* NONE) or from Timeout's fallback PROCEED, and in the safe configuration
\* never changes again once settled. effectiveDecisionAtSettlement freezes
\* the settlement value so EffectiveDecisionStable can detect a later change;
\* it is bookkeeping for this model, not an ACS wire field or token.
\*
\* Formal-3: settlement and dispatch are distinct steps here. Timeout settles
\* the effective decision; InvokeMatchingTool dispatches later. Between the two
\* there is a window in which a Guardian answer can arrive after settlement but
\* before any tool entry. effectiveDecisionAtDispatch freezes the value that
\* was actually consulted when the tool was entered. CommitAtDispatch chooses
\* what a late DENY does inside that window:
\*   FALSE  the decision commits at settlement; a late answer never replaces it
\*          (what Phase 4E found in source: settlement and dispatch release are
\*          synchronous in the OpenCode adapter, so the window is empty there);
\*   TRUE   the decision commits at dispatch; a DENY that arrives after
\*          settlement but before tool entry replaces the fallback and blocks.
\* After dispatch, neither choice lets a late answer change what dispatched.
\* CommitAtDispatch is a design alternative under study, not an ACS rule.
VARIABLES request, guardianDecision, effectiveDecision, effectiveDecisionAtSettlement,
          effectiveDecisionAtDispatch,
          approvedInvocation, actualInvocation, executionCount, decisionUsed, effect
vars == <<request, guardianDecision, effectiveDecision, effectiveDecisionAtSettlement,
          effectiveDecisionAtDispatch,
          approvedInvocation, actualInvocation, executionCount, decisionUsed, effect>>

\* Effective values under which InvokeMatchingTool may dispatch: an explicit
\* Guardian ALLOW, or the timeout fallback PROCEED. DENY is never a member;
\* NONE (still pending) is never a member either.
EffectivePermit == {"ALLOW", "PROCEED"}

Init ==
    /\ request = "NONE"
    /\ guardianDecision = "NONE"
    /\ effectiveDecision = "NONE"
    /\ effectiveDecisionAtSettlement = "NONE"
    /\ effectiveDecisionAtDispatch = "NONE"
    /\ approvedInvocation = "NONE"
    /\ actualInvocation = "NONE"
    /\ executionCount = 0
    /\ decisionUsed = FALSE
    /\ effect = "NONE"

SubmitRequest(i) ==
    /\ request = "NONE" /\ i \in Invocations
    /\ request' = i
    /\ UNCHANGED <<effectiveDecisionAtDispatch, guardianDecision, effectiveDecision, effectiveDecisionAtSettlement,
                    approvedInvocation, actualInvocation, executionCount, decisionUsed, effect>>

\* The client's own decision wait settles with no usable Guardian response yet.
\* Reachable only while genuinely pending: no Guardian answer has arrived at
\* all. This models one negotiated failure posture, PROCEED -- the path
\* Phase 4F-v2 actually exercised at runtime. A DENY failure posture is a
\* distinct, not-currently-modeled configuration; see formal/README.md.
Timeout ==
    /\ request \in Invocations /\ guardianDecision = "NONE" /\ effectiveDecision = "NONE"
    /\ effectiveDecision' = "PROCEED"
    /\ effectiveDecisionAtSettlement' =
         IF effectiveDecisionAtSettlement = "NONE" THEN "PROCEED" ELSE effectiveDecisionAtSettlement
    /\ UNCHANGED <<effectiveDecisionAtDispatch, request, guardianDecision, approvedInvocation, actualInvocation,
                    executionCount, decisionUsed, effect>>

\* The Guardian's own ALLOW, whenever it arrives: timely, while
\* effectiveDecision is still NONE, in which case it becomes effective
\* immediately; or late, after Timeout has already settled effectiveDecision,
\* in which case guardianDecision still records the arrival but the already
\* settled effective value is never replaced. Unlike ReceiveGuardianDeny
\* below, this path carries no experimental bypass: no code path this
\* investigation examined re-reads a settled decision for any value, and nothing
\* here proposes that a late ALLOW would behave differently from a late DENY.
ReceiveGuardianAllow ==
    /\ request \in Invocations /\ guardianDecision = "NONE"
    /\ guardianDecision' = "ALLOW"
    /\ effectiveDecision' = IF effectiveDecision = "NONE" THEN "ALLOW" ELSE effectiveDecision
    /\ effectiveDecisionAtSettlement' =
         IF effectiveDecisionAtSettlement = "NONE" THEN "ALLOW" ELSE effectiveDecisionAtSettlement
    /\ approvedInvocation' = IF effectiveDecision = "NONE" THEN request ELSE approvedInvocation
    /\ UNCHANGED <<effectiveDecisionAtDispatch, request, actualInvocation, executionCount, decisionUsed, effect>>

\* The Guardian's own DENY, whenever it arrives, with the same timely/late
\* split as ReceiveGuardianAllow. PermitLateDecisionReplacement gates ONLY
\* this action's late branch: the safe configuration (FALSE) preserves the
\* already-settled effective value exactly as Phase 4F-v2 observed; the
\* deliberately unsafe configuration (TRUE) lets a late DENY overwrite an
\* already-settled effective value, so EffectiveDecisionStable can be shown
\* non-vacuous. Scoped to DENY specifically because that is the one
\* experimentally tested replacement scenario; see formal/README.md.
ReceiveGuardianDeny ==
    /\ request \in Invocations /\ guardianDecision = "NONE"
    /\ guardianDecision' = "DENY"
    /\ effectiveDecision' =
         IF \/ effectiveDecision = "NONE"
            \/ PermitLateDecisionReplacement
            \/ (CommitAtDispatch /\ executionCount = 0)
         THEN "DENY" ELSE effectiveDecision
    /\ effectiveDecisionAtSettlement' =
         IF effectiveDecisionAtSettlement = "NONE" THEN "DENY" ELSE effectiveDecisionAtSettlement
    /\ UNCHANGED <<effectiveDecisionAtDispatch, request, approvedInvocation, actualInvocation, executionCount, decisionUsed, effect>>

InvokeMatchingTool ==
    /\ effectiveDecision \in EffectivePermit /\ executionCount = 0 /\ ~decisionUsed
    /\ actualInvocation' = IF effectiveDecision = "ALLOW" THEN approvedInvocation ELSE request
    /\ executionCount' = 1
    /\ decisionUsed' = TRUE /\ effect' = "UNKNOWN"
    /\ effectiveDecisionAtDispatch' = effectiveDecision
    /\ UNCHANGED <<request, guardianDecision, effectiveDecision, effectiveDecisionAtSettlement,
                    approvedInvocation>>

\* A different invocation is attempted but rejected; no tool entry occurs.
\* Scoped to a genuine explicit ALLOW, unchanged in spirit from Formal-1:
\* under PROCEED there is no approved identity to mismatch against
\* (approvedInvocation stays NONE under fallback continuation), so this
\* action's mismatch semantics do not extend there.
InvokeDifferentTool(i) ==
    /\ effectiveDecision = "ALLOW" /\ executionCount = 0
    /\ i \in Invocations /\ i # approvedInvocation
    /\ UNCHANGED vars

ObserveSuccess ==
    /\ executionCount > 0 /\ effect = "UNKNOWN"
    /\ effect' = "SUCCESS"
    /\ UNCHANGED <<effectiveDecisionAtDispatch, request, guardianDecision, effectiveDecision, effectiveDecisionAtSettlement,
                    approvedInvocation, actualInvocation, executionCount, decisionUsed>>

ObserveFailure ==
    /\ executionCount > 0 /\ effect = "UNKNOWN"
    /\ effect' = "FAILURE"
    /\ UNCHANGED <<effectiveDecisionAtDispatch, request, guardianDecision, effectiveDecision, effectiveDecisionAtSettlement,
                    approvedInvocation, actualInvocation, executionCount, decisionUsed>>

LoseEffectEvidence ==
    /\ executionCount > 0 /\ effect \in {"SUCCESS", "FAILURE"}
    /\ effect' = "UNKNOWN"
    /\ UNCHANGED <<effectiveDecisionAtDispatch, request, guardianDecision, effectiveDecision, effectiveDecisionAtSettlement,
                    approvedInvocation, actualInvocation, executionCount, decisionUsed>>

\* Experimental bypass of the decisionUsed guard, bounded to two occurrences.
AttemptSecondExecution ==
    /\ PermitSecondExecution /\ effectiveDecision \in EffectivePermit
    /\ decisionUsed /\ executionCount = 1
    /\ actualInvocation' = IF effectiveDecision = "ALLOW" THEN approvedInvocation ELSE request
    /\ executionCount' = 2
    /\ effect' = "UNKNOWN"
    /\ UNCHANGED <<effectiveDecisionAtDispatch, request, guardianDecision, effectiveDecision, effectiveDecisionAtSettlement,
                    approvedInvocation, decisionUsed>>

Next == (\E i \in Invocations : SubmitRequest(i) \/ InvokeDifferentTool(i))
        \/ Timeout \/ ReceiveGuardianAllow \/ ReceiveGuardianDeny \/ InvokeMatchingTool
        \/ ObserveSuccess \/ ObserveFailure \/ LoseEffectEvidence
        \/ AttemptSecondExecution
Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ request \in Invocations \cup {"NONE"}
    /\ guardianDecision \in {"NONE", "ALLOW", "DENY"}
    /\ effectiveDecision \in {"NONE", "ALLOW", "DENY", "PROCEED"}
    /\ effectiveDecisionAtSettlement \in {"NONE", "ALLOW", "DENY", "PROCEED"}
    /\ effectiveDecisionAtDispatch \in {"NONE", "ALLOW", "PROCEED"}
    /\ approvedInvocation \in Invocations \cup {"NONE"}
    /\ actualInvocation \in Invocations \cup {"NONE"}
    /\ executionCount \in Nat /\ decisionUsed \in BOOLEAN
    /\ effect \in {"NONE", "SUCCESS", "FAILURE", "UNKNOWN"}

DenyPreventsInvocation == effectiveDecision = "DENY" => executionCount = 0

InvocationMatchesApprovedInvocation ==
    (effectiveDecision = "ALLOW" /\ executionCount > 0) =>
        actualInvocation = approvedInvocation

\* P4 is experimental, NOT an identified ACS normative requirement.
AtMostOneExecutionPerDecision == executionCount <= 1

\* Implementation-derived / experimentally supported, per Phase 4E's source
\* analysis and Phase 4F-v2's one controlled runtime trial. NOT an identified
\* ACS normative requirement -- no normative text establishing it was
\* consulted. Once effectiveDecision has settled away from NONE, a later
\* Guardian response must not replace it.
EffectiveDecisionStable ==
    effectiveDecisionAtSettlement # "NONE" => effectiveDecision = effectiveDecisionAtSettlement

\* Formal-3. Once a tool has been entered, the effective decision is the one
\* that dispatched, whatever the Guardian says afterwards. Holds under both
\* values of CommitAtDispatch; violated only by PermitLateDecisionReplacement.
DispatchedDecisionStable ==
    executionCount > 0 => effectiveDecision = effectiveDecisionAtDispatch

\* Formal-3. What dispatched was always a permit.
DispatchedUnderPermit ==
    executionCount > 0 => effectiveDecisionAtDispatch \in EffectivePermit

\* Diagnostic only: violating this predicate witnesses UNKNOWN reachability.
NoExecutedUnknown == ~(executionCount > 0 /\ effect = "UNKNOWN")

\* Diagnostic only: violating this predicate witnesses that the safe
\* configuration can reach a state where the effective decision has already
\* settled to PROCEED via timeout while a late Guardian DENY is also on
\* record for the same request -- the state EffectiveDecisionStable's own
\* non-vacuity in the safe configuration depends on being reachable at all.
NoLateDenyAfterProceedSettlement ==
    ~(effectiveDecision = "PROCEED" /\ guardianDecision = "DENY")

\* Formal-3 diagnostic: the runtime case Phase 4F-v2 observed. The tool ran
\* under the fallback PROCEED and a Guardian DENY is on record afterwards.
NoLateDenyAfterDispatch ==
    ~(executionCount > 0 /\ effectiveDecisionAtDispatch = "PROCEED" /\ guardianDecision = "DENY")

\* Formal-3 diagnostic: the window between settlement and dispatch is
\* reachable in this model -- a DENY arrives after PROCEED settled and before
\* any tool entry. This is the case the late-unsafe counterexample lands in.
NoLateDenyBeforeDispatch ==
    ~(executionCount = 0 /\ effectiveDecisionAtSettlement = "PROCEED" /\ guardianDecision = "DENY")
=============================================================================
