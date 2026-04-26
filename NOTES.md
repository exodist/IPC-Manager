# Maintainer notes

Informal todo list for codebase-wide cleanups that fall outside any
single feature branch.

## Audit: count-when-bool-suffices methods

The streaming_deadlock branch grew a `have_pending_sends` boolean fast
path next to `pending_sends` because the service event loop only ever
needed "is there anything queued?" but `pending_sends` walks every
peer summing queue depths. Sweep the rest of the codebase for the same
shape:

- accessor that loops over peers / files / handles to compute a count
- callers that use the result only as truthy/falsy (`if $foo->count`,
  `while $foo->count && ...`, `... unless $foo->count`)
- consider adding `have_$thing` sibling that returns on the first hit

Hotspots to look at first:

- `IPC::Manager::Client` and its drivers: `peers`, `connections`,
  `listening_peers`, `pending_messages`, `ready_messages`, anything
  named `..._stats`, anything that scans `+CONNECTIONS` / `+PIPE_CACHE`
  / `+SOCKET_CACHE`.
- `IPC::Manager::Role::Service::Select::handles_for_select` and the
  driver overrides — consumed both as "are there any?" and as the
  full list.
- `IPC::Manager::Role::Service` and `IPC::Manager::Service::Handle`
  bookkeeping (`workers`, `pending_responses`, etc.).

Pattern is cheap when peer counts are small but pathological in
services with many peers, especially when called from a tight event
loop iteration.
