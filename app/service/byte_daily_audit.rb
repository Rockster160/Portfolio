# The nightly self-review: a Claude session that reads yesterday's Byte traffic
# and writes up what didn't work.
#
# It runs as an ordinary Claude-mode Byte conversation rather than anything
# bespoke, which is what makes it cheap: the whole path already exists
# (ByteMessageIntake -> BuddyDeliverWorker#deliver_plain -> ByteLocal.deliver ->
# `claude -p` on the Mac -> streamed back into the thread). The report lands
# where the person already reads, it pushes like any other message, and replying
# to it turns the report into a working session on the spot.
#
# READ-ONLY is enforced by the machine, not by the prompt. The conversation sits
# in `permission_mode: "ask"`, so the Mac's PreToolUse hook checks each call
# against the project's `permissions.allow` list and turns anything else into an
# action-request card. Reads, greps and prod-query run unattended; a Write or an
# Edit stops dead until it's tapped. `prodExec`, `git commit`, `git push` and
# `cap production` are refused by that hook in either mode.
#
# That only became true on 2026-08-11. The hook's `load_allow_patterns`
# documented reading the PROJECT's `.claude/settings.local.json` and never did
# it — it opened the two global files only — so every in-project "always allow"
# was invisible and `ask` prompted for things that were plainly already
# permitted. Fixing it took the merged list from 26 patterns to 87, which is
# what makes an unattended read-only run possible at all. If this thread starts
# stalling on ordinary reads again, check that first.
module ByteDailyAudit
  module_function

  NAME = "Daily Audit".freeze
  CWD  = "/Users/zoro/code/Portfolio".freeze

  # One thread, a fresh Claude session each day. The thread is what makes the
  # reports scrollable side by side; the session reset is what stops a month of
  # them accumulating into one context.
  def conversation(user)
    convo = user.byte_conversations.find_by(name: NAME)
    return sync!(convo) if convo

    user.byte_conversations.create!(
      name:            NAME,
      mode:            :claude,
      last_message_at: Time.current,
      metadata:        base_metadata,
    )
  end

  # Settings the audit depends on, reasserted every run. `permission_mode` is
  # the one that matters: it's togglable from the pwd bar, and an audit left in
  # `auto` overnight is one that can rewrite the app while nobody's looking.
  def sync!(convo)
    wanted = convo.metadata.to_h.merge(base_metadata)
    convo.update!(metadata: wanted) if convo.metadata.to_h != wanted
    convo
  end

  def base_metadata
    { "cwd" => CWD, "permission_mode" => "ask", "daily_audit" => true }
  end

  # Two days, ending now: yesterday in full, plus today up to the 10pm run.
  #
  # The second day is what makes the deploy reconciliation possible. A fresh
  # Claude session every night has no memory of what it said last night, so a
  # one-day window would report Monday's bug again on Tuesday with no way to
  # know it had already been fixed. Overlapping the window means the fix and the
  # failure are visible in the same read, and "already handled" becomes
  # something it can SEE rather than something it has to be told.
  def window(user, now: Time.current)
    today = now.in_time_zone(user.timezone).to_date
    (today - 1.day)..today
  end

  # sidekiq-cron can fire the same minute twice across a restart, and the retry
  # loop re-enters this on every attempt, so the guard is a real requirement
  # rather than belt-and-braces.
  def already_ran?(user, convo, now: Time.current)
    midnight = now.in_time_zone(user.timezone).beginning_of_day
    convo.byte_messages
      .where(direction: :outbound)
      .where("byte_messages.metadata ->> 'daily_audit' = 'true'")
      .exists?(byte_messages: { created_at: midnight.. })
  end

  # Everything the audit is asked to do.
  #
  # The operational half — which tables, which columns, which script — is spelled
  # out because otherwise every run spends its first several turns rediscovering
  # it, and rediscovery is where a run quietly decides to sample instead of read
  # the lot. The judgement half is left open on purpose.
  def prompt(user, now: Time.current)
    days  = window(user, now: now)
    local = now.in_time_zone(user.timezone)
    <<~TXT
      You are the daily audit for this app. Review the two days from **#{days.first.strftime("%A %B %-d, %Y")}** through **#{days.last.strftime("%A %B %-d, %Y")}** (America/Denver), up to right now, #{local.strftime("%-I:%M %p")}, and write up what didn't work quite as desired.

      REPORT ONLY. Do not change any code, and do not offer to until asked. If a fix is obvious, describe it precisely enough that it could be applied in one step, and stop there. Reads, greps and prod queries are yours to run freely; a Write or an Edit will stop and wait for a tap, so don't reach for one.

      WHERE THE DAY IS
      - `bash .claude/prod-query.sh "SQL"` is read-only and is how you reach production. Use `COPY (SELECT ... ) TO STDOUT (FORMAT csv)` for anything wide - the default table output wraps and becomes unreadable.
      - `byte_messages` is the transcript: `direction` 0 = the person, 1 = the companion. `metadata->>'kind'` separates real turns (`buddy`, `buddy_reply`, `claude`) from receipt chips (`buddy_activity`), forms, relays and hidden trigger seeds (`metadata->>'hidden' = 'true'`). `byte_conversation_id` tells you which companion: read `byte_conversations.name`.
      - `metadata->'usage'->>'calls'` is how many model calls a turn took. A turn that claims something happened with no `buddy_activity` chip after it, and no proposal in `buttons`, is a turn where nothing ran.
      - Deploys are in the thread already: messages with `metadata->>'source' = 'watch'` whose body starts with a deploy marker carry the commit sha, the title and the time, and a failed deploy says so. `git log` and `git show --stat` in this repo fill in what each one actually contained - read those rather than guessing from the commit title, which is usually too terse to tell you whether a specific bug was addressed.

      WHAT TO PRODUCE
      1. **Counts.** Messages per conversation AND per direction, so each companion's inbound/outbound is visible separately, **split by day** so the two are comparable. Name the companion, not the id.
      2. **What misfired.** Anything that didn't do what the person plainly asked, answered a question wrongly, claimed something it hadn't done, fired twice, or fired never. Cite the message id for every single one - a claim without an id is not usable. Say what should have happened instead.
      3. **Deploys, and what they already fixed.** List which went out and when across both days. Then reconcile: **for every problem you find on the first day, check whether a deploy since then addressed it, and check the traffic after that deploy to see whether it actually took.**
         - Fixed, and the later traffic proves it: one line saying so, in a "resolved since" list. Not a finding, and no suggested change.
         - A deploy that was clearly aimed at it and the thing still happened afterwards: that is the most important item in the whole report. Say what shipped, and what still went wrong after it.
         - No deploy touched it: an ordinary finding.
         You have no memory of previous reports - a fresh session runs each night - so this reconciliation is the ONLY thing stopping you from handing back a problem that was solved this morning. Do it before you write anything up.
      4. **Backfills.** Data that should have been written and wasn't - a watch that never fired, a chore that never advanced, a record left half-linked. Say which rows, and what the corrected value would be. Do not write them.
      5. **Suggested changes**, ordered by how much they actually cost the person. Be specific about the file and the mechanism. Distinguish something that has now failed more than once from a one-off.

      HARD RULES
      - **Never suggest compacting, debouncing, batching, deduping or collapsing messages or notifications. Ever.** Each notification is a real event and the person wants all of them. This is not a tradeoff to re-litigate; do not raise it in any form.
      - Do not suggest anything you have not seen evidence for in the data. No speculative hardening, no "might be worth considering".
      - If it was quiet and little went wrong, say so and stop. A short report is a correct report; padding it out to look thorough is worse than nothing.
      - Read both days in full. Do not sample.
    TXT
  end

  # Post the day's prompt. Assumes the Mac is up — DailyAuditWorker checks that
  # first, because a message posted at a sleeping Mac is a `failed` bubble
  # nobody asked for.
  def run!(user, now: Time.current)
    convo = conversation(user)
    return :already_ran if already_ran?(user, convo, now: now)

    # Fresh session, and it has to land before the prompt does.
    ByteLocal.reset_claude_session(conversation_id: convo.id)
    convo.update!(metadata: convo.metadata.to_h.merge("claude_session_id" => nil, "claude_session_name" => nil))

    ByteMessageIntake.call(
      user:         user,
      conversation: convo,
      body:         prompt(user, now: now),
      metadata:     { "daily_audit" => true, "hidden" => true },
    )
    :sent
  end
end
