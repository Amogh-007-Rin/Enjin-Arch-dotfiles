# Security notes

This repository is intended for public or private source control. It contains
desktop configuration, scripts, themes, and package names only.

Do not add any of the following:

- SSH keys, API tokens, passwords, cookies, browser profiles, or auth files
- NetworkManager connection profiles or other saved Wi-Fi secrets
- Quickshell runtime state, caches, logs, or generated machine state
- Personal backups, recordings, or private wallpapers

The installer creates backups outside this repository in
`~/.config-backups/`. Before pushing a new change, review `git diff --cached`
and run a secret scanner if one is available on the system.
