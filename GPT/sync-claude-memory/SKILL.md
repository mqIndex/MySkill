---
name: sync-claude-memory
description: Locate and load the Claude memory associated with the current Codex project without modifying Claude files. Use only when the user explicitly asks to sync, load, refresh, or reuse Claude memory or context, including prompts such as “同步 Claude 记忆”, “加载 Claude 上下文”, or “refresh Claude memory”.
---

# Sync Claude Memory

Load Claude memory into the current task on explicit user request. Treat every Claude source file as read-only.

## Workflow

1. Resolve the current workspace or project root. Prefer the active workspace root; otherwise use the current working directory.
2. Run the bundled locator from this skill directory:

   ```powershell
   python scripts/load_claude_memory.py --project "<project-root>"
   ```

3. Read the complete command output. It contains `MEMORY.md` followed by its referenced Markdown files. If no index exists, it contains all Markdown files in the discovered memory directory.
4. Apply the loaded memory to the current task, separating:
   - durable user preferences and operating rules;
   - mutable project state such as holdings, task status, or environment details;
   - dated historical notes.
5. For mutable state, prefer the latest explicitly dated statement. Flag contradictions or stale snapshots instead of silently guessing.
6. Briefly tell the user which Claude memory directory was loaded, whether any entries appear stale or conflicting, and that the source remained unchanged.

## Discovery behavior

The locator checks, in order:

- `memory/` when the workspace itself is a Claude project-state directory;
- `.claude/memory/` in the project or an ancestor;
- the matching project under the user's global `.claude/projects/` store, identified from session JSONL `cwd` metadata.

If automatic discovery is ambiguous, do not choose by folder name alone. Show the exact candidate paths and ask the user which one belongs to the project. The user can then select one with:

```powershell
python scripts/load_claude_memory.py --project "<project-root>" --source "<memory-directory>"
```

## Safety rules

- Never edit, move, delete, rename, normalize, or re-encode Claude memory or session files.
- Never write a synchronized copy unless the user explicitly asks for a persistent Codex-side snapshot.
- If a persistent snapshot is requested, write to a clearly Codex-owned path such as `.codex/claude-memory-import.md`; never write under `.claude/` or the discovered Claude memory directory.
- Do not treat historical portfolio, credential, identity, deployment, or environment data as current without confirmation.
- Do not expose unrelated Claude projects or their memory contents. Read only the project matched to the current workspace.
- If filesystem permission is required, request read access only for the exact matched Claude project directory.

