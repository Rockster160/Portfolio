# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Personal automation platform built on Rails 7.1.2 (Ruby 3.2.2). The core systems are:

- **Jarvis**: Text/voice command processor that handles input from multiple channels (Alexa, SMS, terminal, iOS Shortcut, web chat). Core file: `app/service/jarvis.rb`
- **Jil (Jarvis Integration Language)**: Custom DSL for automation workflows with trigger-listener/pub-sub architecture. 70+ active tasks. Core execution: `app/service/jil/executor.rb`

## Commands

```bash
# Server (runs on port 3141)
rails server

# Background jobs (required for automations)
bundle exec sidekiq

# JavaScript bundling
npm run build           # Build once
npm run watch:js        # Watch mode

# Testing
bundle exec rspec                      # All tests
bundle exec rspec spec/models          # Model tests only
bundle exec rspec spec/path/file_spec.rb:42  # Single test at line

# Linting
bundle exec rubocop
bundle exec rubocop -A                 # Auto-correct

# Database (ALWAYS use RAILS_ENV=test — never run in dev)
RAILS_ENV=test bundle exec rails g migration AddFooToBar   # ALWAYS generate; never hand-name
RAILS_ENV=test bundle exec rake db:migrate
bundle exec annotate                   # Update model annotations

# Deployment (auto-deploys on master push via GitHub Actions)
bundle exec cap production deploy
```

## Architecture

### Service Layer (`app/service/`)

Core business logic lives here, not in models or controllers:

- `jarvis.rb` - Main automation orchestrator
- `jil/executor.rb` - Jil language execution engine
- `jil/parser.rb` - Jil code parsing
- `jil/methods/` - 22 Jil method modules (text, email, sms, tesla, nest, etc.)
- `jarvis/` - Jarvis integration modules (tesla.rb, nest.rb, sms.rb, etc.)

### WebSocket Channels (`app/channels/`)

23 ActionCable channels for real-time features:
- `jarvis_channel.rb` - Command/response
- `monitor_channel.rb` - Dashboard updates
- `list_json_channel.rb` - Real-time list sync

### Background Jobs (`app/workers/`)

Sidekiq workers with cron scheduling (sidekiq-cron):
- `JilScheduleWorker` - Runs every minute for scheduled tasks
- `JilExecuteWorker` - Executes Jil tasks
- `ReceiveEmailWorker` - Processes inbound emails

### Jil Listener Syntax

Jil uses advanced search syntax similar to GitHub:
```
email:from:hunter body:challenge     # Email from "hunter" with "challenge" in body
tell:/open|close/ garage             # Regex match on spoken commands
event:add name:ANY(food drink)       # Event logging triggers
```

Built-in listeners: `monitor`, `email`, `sms`, `websocket`, `event`, `list`, `contact`, `tell`, `prompt`, `relay`, plus cron scheduling.

## Key Models

- `JilTask` - Automation task definitions with listener patterns
- `JilSchedule` - Cron-based task scheduling
- `ActionEvent` - Event logging (food, drinks, workouts, etc.)
- `List`/`ListItem` - Todo lists with real-time sync
- `Prompt` - Survey/question system for user input

## Migrations

**A migration filename carries the real clock time, always.** Use the generator
(`rails g migration`), or take the timestamp from the machine
(`date -u +%Y%m%d%H%M%S`). Never hand-write one, and never round it.

Rounded stamps — `20260806000001`, `20260731230000` — are the tell that a batch
was named by hand. They collide across branches, they sort by invention order
rather than the order things actually happened, and a run of them ending
`000001`…`000006` is unreadable. Several already shipped that way; they are
applied in prod and must NOT be renamed, because the filename IS the key in
`schema_migrations`. The rule is for every one after them.

## Code Style

Configured in `.rubocop.yml`:
- 100 character line length
- Double quotes for strings
- Block braces style (always braces)
- **Symbols are the default — ALWAYS.** Strings are only for user-facing values: titles, descriptions, error messages, actual text rendered on a page, multi-word labels. Anything that functions as a key, identifier, enum, flag, type tag, icon name, status, scope, action, etc. MUST be a symbol — even if it ends up interpolated into a string or passed to the DB (both handle the symbol→string conversion automatically). Default to `:foo`; only reach for `"foo"` when the value is genuinely user-facing text.

### Whitespace & Indentation (CRITICAL)

These rules are non-negotiable and apply to ALL Ruby code:

1. **No line should start or end with `.`** Keep chains on one line, use intermediate variable reassignment, or chain with consistent open/close blocks.
   ```ruby
   # WRONG
   Prompt
     .where(id: 44045)
     .active.first

   # RIGHT — single line
   Prompt.active.where(id: 44045).first

   # RIGHT — intermediate variable reassignment
   scope = Prompt.active
   scope = scope.where(id: 44045)
   scope.first

   # RIGHT — chained with consistent open/close blocks
   @list = ListBuilder.joins(
     list: :user_lists,
   ).where(
     user_lists: { user_id: current_user.id },
   ).find_by!(
     parameterized_name: params[:id],
   )
   ```

2. **No skipped indent levels.** Applies everywhere: assignments, hash values, method args, conditions. Wrap multiline expressions in parentheses so indentation increments naturally.
   ```ruby
   # WRONG
   result = if condition
              something
            else
              other
            end

   # RIGHT
   result = (
     if condition
       something
     else
       other
     end
   )
   ```

3. **Heredocs must have dedicated open/close lines** — never inline at the end of a method call, and never dangling after `=` on the next line.
   ```ruby
   # WRONG — inline
   Jil::Executor.call(user, <<~'JIL')
     code_here
   JIL

   # WRONG — dangling assignment
   code =
     <<~JIL
       code_here
     JIL

   # RIGHT — method arg
   Jil::Executor.call(user,
     <<~'JIL',
       code_here
     JIL
   )

   # RIGHT — assignment on same line
   code = <<~'JIL'
     code_here
   JIL
   ```

## Jil Code Validation & Testing

All new/modified Jil task code MUST go through both steps before deploy:

1. **Validate** — `Jil::Validator.validate!(code)` in a spec. Catches invalid casts, duplicate variables, undefined references, unknown classes, content-block/positional-arg mismatches (e.g. raw Keyval blocks as Prompt.create data), and bare variables where content blocks are expected.
2. **Test** — a temporary behavioral spec that runs `Jil::Executor.call(user, code, input_data)` with representative inputs and asserts the EXPECTED RESULT: correct branch taken, correct args passed to downstream `Custom.X` calls (stub `Jil::Methods::Custom#execute` to capture them), correct `Jarvis.command(...)` text (stub `::Jarvis.command`), correct side effects on cache/records, both positive and negative cases. Syntactic validation passes code that is logically broken — type coercions can silently produce nil, branches can be silently skipped, content blocks can wrap unexpectedly. The behavioral spec is what catches these.

**Workflow:** Write the Jil code → validate in a spec → write a behavioral spec → run both → fix any issues → THEN write the prodExec script. Do NOT write the script first.

**`spec/lib/scripts/` must not exist.** Both specs are scaffolding: they prove the code before it goes near production, and then they are done. DELETE them in the same round you wrote them, once they're green — not "before the deploy", not "once the script has run", and never with a comment saying so. A one-off spec left behind with a note asking someone to remove it later is a chore handed to the person who asked for the feature, and it will still be there months on, failing for reasons nobody remembers. Getting rid of it is part of finishing, not part of deploying.

Anything genuinely worth keeping belongs in a spec for the thing it actually tests — the propagator, the executor, the model — under that thing's own path, written so it stands on its own without the script.

When presenting a prodExec command, confirm both steps: `Tested ✓ Validated ✓ — prodExec lib/scripts/my_script.rb`

### No DRY_RUN flag

**A prodExec script does the thing when you run it.** Never add a `DRY_RUN`
constant, a `--dry-run` switch, or any other preview mode.

It reads as caution and behaves as a trap: the script runs, prints a tidy list
of what it *would* do, exits 0, and stamps itself `# PROD: Executed`. Nothing
distinguishes that from a real run afterwards, so the change is believed to be
live when it isn't, and the discrepancy only surfaces when something downstream
breaks. It also isn't safety — it was already established that `DRY_RUN=1
prodExec` mutated production, because `cap` builds its own ssh command line and
forwards no local environment.

What to do instead, all of which are real:

- **Make it idempotent and say which branch it took.** Compare against what's
  already there and print `already applied` or `WROTE <thing>`. Re-running is
  then the preview, and its output is a fact about production rather than a
  prediction.
- **Raise on unmet preconditions.** A missing record or a half-migrated state
  should abort loudly, not print a warning and carry on.
- **Verify by reading first.** `.claude/prod-query.sh` answers "what is it now"
  without writing anything, and that's what a preview was reaching for.

## Buddy tools: the eval harness is part of the change

`lib/tasks/buddy_eval.rake` says plain sentences to the real model and checks
which tool comes back. Specs prove the plumbing; this is the only thing that
proves a description can still be FOUND. A tool whose prose reads beautifully
and never gets chosen is invisible from the inside — the reply is fluent,
something happens, and it's the wrong something.

Three obligations, and none of them is optional:

1. **A new tool needs a line in `BUDDY_TOOL_PROBES`** — one sentence a person
   would actually say, plus `avoid:` naming the tool it will get confused with.
   `rake buddy:tool_coverage` fails until it's there, free and before any spend.
   Adding the tool without the probe means nobody has ever checked the model
   can reach it.

2. **A new tool that needs RECORDS to be reachable needs them in
   `lib/buddy_eval_world.rb`** — a chore, a list item, a stashed idea. The
   world is built once, everything runs against it, and it's torn down from a
   manifest afterwards. Without the records the probe reports "unanswerable",
   which is not a pass.

   Build it with `reuse`, never a bare `create!`. It runs against the real dev
   database, so anything the person already has is theirs: use it as it stands
   and don't track it. A second "Take out the recycling" doesn't make "rename
   the recycling chore" more answerable — it makes it AMBIGUOUS, and then a
   miss gets read as a description problem when the question had two right
   answers. Look records up with a fresh query (`BuddyRoutine.where(user:)`),
   not `user.buddy_routines`: the association caches on first read and `User.me`
   is memoized process-wide.

3. **Every misinterpretation found in real use becomes an entry in
   `BUDDY_EDGE_PROBES`** — the sentence as they actually said it, the tool it
   should have reached, `avoid:` for the one it did, and `note:` for what
   happened. Fix the description in the same change; the probe is what stops
   the third occurrence. Several have already come back twice wearing different
   words.

   The fields, and when each one is the right one:

   | field | for |
   |---|---|
   | `order:` | the thing was done before the wait that was supposed to hold it |
   | `args:` / `never_args:` | right tool, wrong arguments |
   | `once:` | it made two of something they asked for one of |
   | `run:` + `effect:` | **did it actually happen?** dispatches the call for real and asks the database |
   | `steps:` | several turns, each a cold start — continuity, a thing then its undo |
   | `seed:` | a precondition that's only true for one turn (an open relay question) |
   | `expect_reply:` | the words are the point — a term taught last turn coming back understood |
   | `tool: :none` | the honest answer is a question, and any call is the failure |

   **`run:`/`steps:`/`seed:`/`effect:` run inside a transaction that is always
   rolled back**, so nothing they write survives. Only tools on
   `BUDDY_EVAL_EXECUTABLE` are ever dispatched — an allowlist, so a run of the
   suite can't text anyone or start a print.

4. **A `needs:` is a KEY into `lib/buddy_eval_needs.rb`, never a sentence.** It
   goes and looks. Taking a probe's word for it filed ten real failures under
   "not answerable" in the 21 Aug run, with the records sitting in the database
   the whole time. `rake buddy:tool_coverage` rejects a key that isn't there.

```bash
rake buddy:tool_coverage   # free: does every tool have a sentence?
rake buddy:eval_tools      # the sweep + the edge cases (REAL API CALLS)
rake buddy:eval_edges      # only the ones that have gone wrong before
rake buddy:eval           # the canned scenarios: voice, not tool choice
rake buddy:eval_world      # build the world and leave it up, to poke by hand
rake buddy:eval_world_clear
```

Two failures the harness itself used to cause, worth knowing because both read
as Buddy being broken: an acting tool was answered with `note: "resolved but
not run"`, and the model dutifully said the thing hadn't landed; and a leading
`[[mood:]]` marker was judged as stray output when production consumes it.
Both are fixed — an acting tool now resolves for real and stops short of the
side effect, so a name matching nothing still fails and a name matching
something reads as success.

EVERY run writes `tmp/buddy_eval/report.md`, and that file is meant to be handed
straight to an agent. It holds three things: each probe that missed, with the
sentence, what it reached for, what it said, the known incident and the file
that owns the wording; each turn that tripped a mechanical check; and — for a
scenario run, which has no automatic verdict at all — every turn beside the
`want:` saying what a pass looks like, so the judging happens in a file instead
of in a scrollback that gets read once and lost.

## Environment

Key env vars in `.env`: `PORTFOLIO_OPENAI_KEY`, `PORTFOLIO_TESLA_CLIENT_ID`, `PORTFOLIO_TWILIO_*`, `PORTFOLIO_S3_*`, `PORTFOLIO_SLACK_HOOK`

Database: PostgreSQL with uuid-ossp and pg_stat_statements extensions.
