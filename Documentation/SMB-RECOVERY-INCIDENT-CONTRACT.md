# SMB Recovery and Incident Contract

Status: Binding implementation plan approved on 2026-08-14.

## Objective

WRDM shall automatically recover genuinely missing SMB mounts where macOS can
still perform the operation safely. It shall distinguish a missing mount from a
stale kernel mount and shall report conditions that require manual intervention
or a macOS restart truthfully.

## Safety Invariants

1. WRDM must never issue a mount request while the same configured share is
   still present in the macOS mount table.
2. Every mount-changing operation must hold a cross-process lock scoped to the
   SMB server.
3. An active WRDM transfer involving the affected mount blocks unmount and
   force-unmount operations.
4. Automatic recovery may perform a bounded normal unmount. A force unmount is
   permitted only through an explicit, confirmed user command.
5. Every unmount must be followed by independent mount-table verification.
   Remounting is permitted only after detach has been proven.
6. A timed-out operation whose process or descendant remains in uninterruptible
   kernel wait is terminal for the current boot. WRDM must report
   `restartRequired` and must not attempt further mount mutations until the boot
   identity changes.
7. Recovery retries are bounded. Repeated failures open a circuit breaker rather
   than causing an endless recovery loop.
8. One outage creates one incident and one bounded evidence package. Repeated
   observations update that incident instead of duplicating events and captures.
9. Sleep and wake events must originate from macOS power-event evidence. A long
   monitoring cycle alone is not a sleep/wake event.
10. Recovery must not reset shared macOS SMB helper processes automatically.

## State Contract

Observed mount availability and recovery progress are independent dimensions.

- Availability: `disabled`, `healthy`, `missing`, `staleMounted`, `unknown`.
- Recovery phase: `idle`, `waitingForNetwork`, `scheduled`, `mounting`,
  `unmounting`, `verifyingDetach`, `verifyingHealth`,
  `deferredActiveTransfer`, `manualConfirmationRequired`, `circuitOpen`,
  `restartRequired`.
- Failure causes use stable machine-readable codes and a separate human-readable
  message.

## Recovery Matrix

| Observation | Automatic action | Terminal or user action |
| --- | --- | --- |
| Healthy | Close an existing incident and clear retry state | None |
| Missing, server reachable | Bounded mount attempt, then verify health | Open circuit after the configured attempt limit |
| Missing, server unreachable | Wait with backoff | None while network remains unavailable |
| Stale mount, no active transfer | One bounded normal unmount, verify detach | Require explicit force-recovery confirmation if detach fails |
| Stale mount, active transfer | No mutation | Wait for the transfer to finish or be stopped |
| Explicit force recovery | Force unmount, verify detach, then mount and verify | Report restart required if the operation remains in kernel wait |
| Uninterruptible kernel wait | No further mutations in the current boot | Controlled macOS restart required |

## Product Surfaces

The agent, menu-bar app, CLI and MCP server must expose the same availability,
recovery phase, stable failure code, incident identifier and next possible
action. A regular health check must not mutate mounts. Automatic recovery,
normal manual recovery and confirmed force recovery are distinct operations.

## Acceptance Evidence

- Deterministic unit tests cover every recovery-matrix row, retry/circuit
  behavior, transfer deferral, mount-table verification, process timeout and
  uninterruptible-wait classification, boot reset, incident deduplication and
  power-event handling.
- Integration tests use fake adapters and cannot unmount production volumes.
- The complete Swift test suite and existing companion tests pass.
- Documentation describes the exact automatic, manual, restart-required and
  non-mutating check behavior.
