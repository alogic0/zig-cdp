# Working on zig-cdp

Use the compiler pinned in `.zigversion`. Keep this an independent repository.
Read DESIGN.md and CURRENT_STATUS.md before changing ownership or public APIs.
Keep application workflows, authentication, and product policy in consumers.
The library must not install signal handlers, subreaper policy, or reap unrelated
children. The CLI owns its signal handling and session policy.

Format Zig files, run focused Debug and ReleaseSafe checks, and run
`git diff --check`. Review staged changes and commit each valid slice with a
complete message in a temporary file via `git commit -F`. Remove the message
file afterward with plain `rm`. Remove temporary verification files.
