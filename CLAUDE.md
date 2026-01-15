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

# Database
bundle exec rake db:migrate
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

Built-in listeners: `[monitor]`, `[email]`, `[sms]`, `[websocket]`, `[event]`, `[list]`, `[contact]`, `[tell]`, `[prompt]`, `[relay]`, plus cron scheduling.

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

## Environment

Key env vars in `.env`: `PORTFOLIO_OPENAI_KEY`, `PORTFOLIO_TESLA_CLIENT_ID`, `PORTFOLIO_TWILIO_*`, `PORTFOLIO_S3_*`, `PORTFOLIO_SLACK_HOOK`

Database: PostgreSQL with uuid-ossp and pg_stat_statements extensions.
