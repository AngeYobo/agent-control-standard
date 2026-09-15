--------------------- MODULE ACSAuthorizationExecution ---------------------
EXTENDS Naturals

CONSTANTS Invocations, PermitSecondExecution
ASSUME /\ Invocations # {} /\ "NONE" \notin Invocations
       /\ PermitSecondExecution \in BOOLEAN
\* decisionUsed is experimental bookkeeping, not an ACS authorization artifact.
VARIABLES request, decision, approvedInvocation, actualInvocation,
          executionCount, decisionUsed, effect
vars == <<request, decision, approvedInvocation, actualInvocation,
          executionCount, decisionUsed, effect>>

Init ==
    /\ request = "NONE"
    /\ decision = "NONE"
    /\ approvedInvocation = "NONE"
    /\ actualInvocation = "NONE"
    /\ executionCount = 0
    /\ decisionUsed = FALSE
    /\ effect = "NONE"

SubmitRequest(i) ==
    /\ request = "NONE" /\ i \in Invocations
    /\ request' = i
    /\ UNCHANGED <<decision, approvedInvocation, actualInvocation,
                    executionCount, decisionUsed, effect>>

EvaluateAllow ==
    /\ request \in Invocations /\ decision = "NONE"
    /\ decision' = "ALLOW" /\ approvedInvocation' = request
    /\ UNCHANGED <<request, actualInvocation, executionCount, decisionUsed, effect>>

EvaluateDeny ==
    /\ request \in Invocations /\ decision = "NONE"
    /\ decision' = "DENY"
    /\ UNCHANGED <<request, approvedInvocation, actualInvocation,
                    executionCount, decisionUsed, effect>>

InvokeMatchingTool ==
    /\ decision = "ALLOW" /\ executionCount = 0 /\ ~decisionUsed
    /\ actualInvocation' = approvedInvocation /\ executionCount' = 1
    /\ decisionUsed' = TRUE /\ effect' = "UNKNOWN"
    /\ UNCHANGED <<request, decision, approvedInvocation>>

\* A different invocation is attempted but rejected; no tool entry occurs.
InvokeDifferentTool(i) ==
    /\ decision = "ALLOW" /\ executionCount = 0
    /\ i \in Invocations /\ i # approvedInvocation
    /\ UNCHANGED vars

ObserveSuccess ==
    /\ executionCount > 0 /\ effect = "UNKNOWN"
    /\ effect' = "SUCCESS"
    /\ UNCHANGED <<request, decision, approvedInvocation, actualInvocation,
                    executionCount, decisionUsed>>

ObserveFailure ==
    /\ executionCount > 0 /\ effect = "UNKNOWN"
    /\ effect' = "FAILURE"
    /\ UNCHANGED <<request, decision, approvedInvocation, actualInvocation,
                    executionCount, decisionUsed>>

LoseEffectEvidence ==
    /\ executionCount > 0 /\ effect \in {"SUCCESS", "FAILURE"}
    /\ effect' = "UNKNOWN"
    /\ UNCHANGED <<request, decision, approvedInvocation, actualInvocation,
                    executionCount, decisionUsed>>

\* Experimental bypass of the decisionUsed guard, bounded to two occurrences.
AttemptSecondExecution ==
    /\ PermitSecondExecution /\ decision = "ALLOW"
    /\ decisionUsed /\ executionCount = 1
    /\ actualInvocation' = approvedInvocation /\ executionCount' = 2
    /\ effect' = "UNKNOWN"
    /\ UNCHANGED <<request, decision, approvedInvocation, decisionUsed>>

Next == (\E i \in Invocations : SubmitRequest(i) \/ InvokeDifferentTool(i))
        \/ EvaluateAllow \/ EvaluateDeny \/ InvokeMatchingTool
        \/ ObserveSuccess \/ ObserveFailure \/ LoseEffectEvidence
        \/ AttemptSecondExecution
Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ request \in Invocations \cup {"NONE"}
    /\ decision \in {"NONE", "ALLOW", "DENY"}
    /\ approvedInvocation \in Invocations \cup {"NONE"}
    /\ actualInvocation \in Invocations \cup {"NONE"}
    /\ executionCount \in Nat /\ decisionUsed \in BOOLEAN
    /\ effect \in {"NONE", "SUCCESS", "FAILURE", "UNKNOWN"}
DenyPreventsInvocation == decision = "DENY" => executionCount = 0
InvocationMatchesApprovedInvocation ==
    (decision = "ALLOW" /\ executionCount > 0) =>
        actualInvocation = approvedInvocation
\* P4 is experimental, NOT an identified ACS normative requirement.
AtMostOneExecutionPerDecision == executionCount <= 1
\* Diagnostic only: violating this predicate witnesses UNKNOWN reachability.
NoExecutedUnknown == ~(executionCount > 0 /\ effect = "UNKNOWN")
=============================================================================
