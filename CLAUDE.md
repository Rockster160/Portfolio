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

## Code Style

Configured in `.rubocop.yml`:
- 100 character line length
- Double quotes for strings
- Block braces style (always braces)
- **Symbols over strings**: Always use symbols for keys, enums, identifiers, and similar. Strings should only be used for multi-word values and user-facing messages.

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

## Jil Code Validation

All Jil code MUST be validated with `Jil::Validator.validate!(code)` before being written to a prodExec script. The validator catches: invalid casts, duplicate variables, undefined references, unknown classes, content-block/positional-arg mismatches (e.g. raw Keyval blocks as Prompt.create data), and bare variables where content blocks are expected.

**Workflow:** FIRST validate the Jil code in a spec. THEN write the prodExec script containing the validated code. Do NOT write the script first and validate after — validation must pass before the script file is finalized. Do NOT put the validator inside the script as a substitute — the script should never be created until validation has already passed in a spec.

When presenting a prodExec command to the user, always confirm whether the current iteration of the code in the file has been validated. Example: "Validated ✓ — `prodExec lib/scripts/my_script.rb`"

## Environment

Key env vars in `.env`: `PORTFOLIO_OPENAI_KEY`, `PORTFOLIO_TESLA_CLIENT_ID`, `PORTFOLIO_TWILIO_*`, `PORTFOLIO_S3_*`, `PORTFOLIO_SLACK_HOOK`

Database: PostgreSQL with uuid-ossp and pg_stat_statements extensions.
