# interview-piston

Self-hosted [Piston](https://github.com/engineer-man/piston) code-execution
service, internal-only (no public domain). Runs privileged so it can sandbox
user code with `isolate`.

Python 3.12 is installed once after first deploy by POSTing to
`/api/v2/packages` — see `/deploy/DEPLOY.md` for the exact command.
The Python runtime is persisted via a Dokku storage mount at
`/piston/packages`, so it survives container restarts and rebuilds.
