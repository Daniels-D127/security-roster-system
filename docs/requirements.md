# Requirements

## Functional
- FR1: Administrators manage users, guards, sites and checkpoints.
- FR2: Supervisors create shifts and assign guards
- FR3: The system rejects assigning an inactive guard.
- FR4: The system rejects overlapping assignment for the same guard.
- FR5: Shifts with no assigned guard are shown as unfilled.
- FR6: Guards check in and out against their own assignment.
- FR7: Guards scan a checkpoint QR code to record a visit with a server timestamp.
- FR8: A scan is rejected if the token is invalid, the checkpoint is inactive or it belongs to another site.
- FR9: Duplicate scans of a checkpoint in the same round do not count twice.
- FR10: A patrol round is complete only when all required checkpoints are visited.
- FR11: Supervisors can manually  confirm a visit with their identity and a reason.
- FR12: Authorized users  report incidents and update their status to resolved.
- FR13: Supervisors view a dashboard and print reports.

## Non-functional
- NFR1 Security: roles enforced by Row-level security, not just hidden buttons.
- NFR2 Integrity: foreign keys, unique constraints, UTC timestamps.
- NFR3 Usability: guard pages work on a smartphone.
- NFR4 Auditability: manual confirmations and assignments changes are logged.
- NFR5 Maintainability: shared CSS and JS, schema kept in version control.