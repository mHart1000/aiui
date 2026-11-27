# Multi-User Hardening (Draft)

aiui is currently a **single-user, local-only** application. Some features
grant capabilities that are acceptable only because the operator is trusted
and already has equivalent access to the machine. Multi-user hardening is
**not a priority** at this stage; this document tracks what would need work
if the app is ever deployed for multiple users.

## Features requiring hardening

| Feature | Current assumption | Needed for multi-user |
|---|---|---|
| Pi shell access | Operator is trusted and could launch Pi directly; running commands is an intended capability. | Per-user authorization, sandboxing/containerization, command auditing. |
| `repo_path` | A working directory, not a sandbox boundary. | Enforce path confinement per user; prevent traversal and symlink escapes. |

## Notes

- Authenticated operators executing commands on their own machine are not
  considered a vulnerability in the current scope.
- Add new entries here when introducing features that rely on operator trust.
