# GPT skills

Shared source for these Windows desktop/Codex skills:

| Folder | Purpose |
| --- | --- |
| `officecli` | Work with office files using OfficeCLI |
| `neat-freak` | Reconcile project documentation and agent knowledge |
| `tudou-value-valuation` | Equity valuation workflow |
| `sync-claude-memory` | Read Claude project memory on explicit request |

Skill instructions and bundled references are preserved byte for byte. The
Claude memory skill's UI policy disables implicit invocation: it runs only when
you explicitly request it.
Third-party authoring and license terms still apply. Only skill code and instructions
are included; Claude memory, chat history, credentials, and client configuration
are not uploaded.

## First computer

Extract the prepared bundle and run `Install.cmd`.
It clones `https://github.com/mqIndex/MySkill.git` into `%USERPROFILE%\MySkill`,
adds only the `GPT` directory, commits and pushes using your Git credentials,
backs up matching existing local skill directories, and creates directory
junctions under `%USERPROFILE%\.agents\skills` pointing into the checkout.
It preserves unrelated repository content. Conflicting versions stop installation
instead of being overwritten. Git must be installed; the first push may require
GitHub sign-in. A missing Git author name/email causes commit to stop: set your
own identity rather than accepting a fabricated one.

An installation error means setup is not complete. For example, if Task Scheduler
registration fails, the skill links may already exist but automatic pull is not
enabled. Backups are retained and indexed in
`%LOCALAPPDATA%\MySkill-GPT\backups.jsonl`.

## Other Windows computers

After the first upload, clone the repository and run:

```powershell
git clone https://github.com/mqIndex/MySkill.git "$env:USERPROFILE\MySkill"
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\MySkill\GPT\Setup-GPT-Skills.ps1"
```

The installer is also stored inside `GPT`, so later machines use the already
published source. If the installer finds a different local version, compare it
with the repository before retrying. Restart the desktop client after installing.

## Sync behavior

Windows task `MySkill-GPT-Sync` pulls at logon and every 30 minutes while the user
is logged in. It uses fast-forward-only Git updates and skips the pull when the
checkout contains any local changes. Git conflicts are reported, never resolved
by force. Errors are written to `%LOCALAPPDATA%\MySkill-GPT\sync.log`.

Local edits change the checkout through the skill junctions. Review and upload
them explicitly:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\MySkill\GPT\Sync-Skills.ps1" -Mode Status
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\MySkill\GPT\Sync-Skills.ps1" -Mode Push
```

Only `GPT` is staged/committed by this upload command. An existing staged file
outside `GPT` stops the upload. If two computers have made independent commits,
the push command stops at the fast-forward check; merge/rebase and review first.
This setup synchronizes skill files, not tool installations, environment
dependencies, authorizations, or ChatGPT web Skills. Install required tools such
as OfficeCLI separately. Clients must support the `.agents\skills` discovery path.

New skill folders become visible in the repository after pull. Rerun the installer
in `GPT` to create links for newly added skills; the periodic job updates existing
linked skills but does not silently install additional ones.

## Disable automatic updates

```powershell
Unregister-ScheduledTask -TaskName 'MySkill-GPT-Sync' -Confirm:$false
```

This removes only the schedule. Existing skill links and backups remain.
