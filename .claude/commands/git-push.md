Push the current branch to the remote repository, automatically handling conflicts.

Follow these steps strictly:

1. Run `git push` to attempt a direct push.
2. If push succeeds, report success and stop.
3. If push is rejected (remote has new commits), do the following:
   a. Check for unstaged/uncommitted changes with `git status -s`.
   b. If there are unstaged changes, run `git stash` first.
   c. Run `git pull --rebase` to rebase local commits on top of remote.
   d. If there are merge conflicts:
      - For `.idea/`, build cache, or other non-code generated files: resolve by accepting the remote version (`git rm` if deleted upstream, or `git checkout --theirs` if modified).
      - For source code conflicts: show the conflicts to the user and ask how to resolve before proceeding.
   e. If stash was used, run `git stash pop`.
   f. If stash pop causes conflicts on non-code files (IDE cache etc.), resolve them the same way (accept remote version).
   g. Clean up: `git restore --staged` and `git checkout --` any remaining IDE/cache files that shouldn't be committed.
   h. Drop stash if still present: `git stash drop` (only if stash pop failed and stash is still on stack).
4. Run `git push` again.
5. If push succeeds, report the commit hash and confirm success.
6. If push fails again, report the error and ask the user for guidance.

Important:
- Never use `git push --force` unless the user explicitly requests it.
- Never commit IDE cache files (`.idea/`, `.deveco/`, `build/`) as part of conflict resolution.
- Always show the user the final `git log --oneline -3` after a successful push.
