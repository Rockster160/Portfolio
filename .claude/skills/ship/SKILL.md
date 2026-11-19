---
name: ship
description: Commit everything that's uncommitted in this Portfolio checkout, push it on its own branch and open a PR that summarizes and lists every change, the way a Feature Builder's PR would.
argument-hint: "[title or note for the PR]"
disable-model-invocation: true
---

Ship the work sitting in this checkout as a PR, written as if this session had
built it as a feature. `$ARGUMENTS`, when given, is the PR's title or a note on
what the work is for: use it.

If `BYTE_BUILD_ID` is set, this is a Feature Builder, which opens its PR with
`builder-pr open`: say so and stop.

## 1. Read everything that's going out

- `git fetch origin master`, then `git status`, `git diff HEAD`, and
  `git log --oneline origin/master..HEAD` for commits not on master yet.
- Read every untracked file in full. Nothing is published unread.
- Nothing uncommitted and nothing ahead of `origin/master`: say there's
  nothing to ship and stop.
- A file that looks like it holds a secret (`.env`, keys, tokens, credentials,
  a dump of real data) is never committed. Stop and name it.

Everything else uncommitted ships: the request is "all of the changes", so
don't leave a file behind because it looks unrelated.

## 2. Check it before anything is committed

- Run the specs for what changed: every changed spec file, plus the spec that
  mirrors each changed file under `app/` or `lib/` when one exists
  (`bundle exec rspec <paths>`).
- JS or CSS changed: `npm run build`.
- A new migration: `RAILS_ENV=test bx rails db:migrate` first, so the specs
  run against it.

Anything fails: stop with the output, and nothing is committed or pushed. The
checkout is left exactly as it was.

## 3. Branch and commit

- On `master`: `git switch -c ship/<slug>`, the slug two to five words naming
  the work. The uncommitted changes come along.
- On any other branch: ship that branch, its unpushed commits included.
- Commit in small, logical commits, staging each group by path
  (`git add <paths>`), never `git add -A`. Each message is one line, starting
  with Added / Fixed / Updated / Removed, saying what is different for a person
  using the app, with no file paths or class names. Several files serving one
  behaviour are one commit.
- `git status` is clean afterwards, apart from ignored files.

## 4. Push and open the PR

1. `git push -u origin HEAD`.
2. Write the body to `tmp/pr_body.md`:
   - **Summary**: what changes for the person using it, in a few sentences.
   - **What changed**: bullets grouped by behaviour, not by file, covering
     every change being shipped, the earlier commits on the branch included.
   - **How it works**: the parts a reviewer needs to follow the design.
   - **Testing**: what ran in step 2 and that it passed.
   - **Before deploying**: migrations, `lib/scripts/` files to run, settings
     to change, or "Nothing".
3. A PR already open for this branch
   (`gh pr list --head <branch> --state open`) is updated in place with
   `gh pr edit <number> --title ... --body-file tmp/pr_body.md`. Otherwise
   `gh pr create --base master --title "<title>" --body-file tmp/pr_body.md`.
   The title names the feature in a few words.

The checkout stays on the branch, so a later `/ship` adds to the same PR.

## 5. Reply

The PR link and two lines on what it does. Nothing else.
