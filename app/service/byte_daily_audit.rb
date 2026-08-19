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
  # Found or made by NAME, never by "whichever thread is current". The audit is
  # a fixed place you scroll back through, so the thread has to be the same one
  # every day — and a report that lands anywhere else is a report nobody will
  # look for again.
  #
  # `mode:` is asserted on the way out for the same reason. On 19 Aug the report
  # was published into a Buddy companion thread because the Mac replied naming
  # one, and a companion thread cannot be the audit however it gets nominated.
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
    convo.update!(mode: :claude) unless convo.claude?
    convo.update!(metadata: wanted) if convo.metadata.to_h != wanted
    convo
  end

  def base_metadata
    { "cwd" => CWD, "permission_mode" => "ask", "daily_audit" => true }
  end

  # The last 24 hours, ending right now.
  #
  # Ending at `now` and not at a fixed hour, so that a run kicked by hand always
  # picks up what was just said. An audit you can't point at the last twenty
  # minutes is one you have to wait until tomorrow to use.
  #
  # It used to run two whole days and deliberately overlap, so that a fresh
  # session with no memory of last night's report could see this morning's fix
  # sitting next to yesterday's failure and not hand the problem back.
  def window(user, now: Time.current)
    local = now.in_time_zone(user.timezone)

    (local - 24.hours)..local
  end

  # sidekiq-cron can fire the same minute twice across a restart, so the guard
  # is a real requirement rather than belt-and-braces.
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
    span = window(user, now: now)
    <<~TXT
      You are the daily audit for this app. Review the 24 hours from **#{stamp(span.first)}** to **#{stamp(span.last)}** (America/Denver) - right up to now, the last few minutes included - and write up what didn't work quite as desired.

      REPORT ONLY. Do not change any code, and do not offer to until asked. If a fix is obvious, describe it precisely enough that it could be applied in one step, and stop there. Reads, greps and prod queries are yours to run freely; a Write or an Edit will stop and wait for a tap, so don't reach for one.

      WHERE THE DAY IS
      - `bash .claude/prod-query.sh "SQL"` is read-only and is how you reach production. Use `COPY (SELECT ... ) TO STDOUT (FORMAT csv)` for anything wide - the default table output wraps and becomes unreadable.
      - `byte_messages` is the transcript: `direction` 0 = the person, 1 = the companion. `metadata->>'kind'` separates real turns (`buddy`, `buddy_reply`, `claude`) from receipt chips (`buddy_activity`), forms, relays and hidden trigger seeds (`metadata->>'hidden' = 'true'`). `byte_conversation_id` tells you which companion: read `byte_conversations.name`.
      - `metadata->'usage'->>'calls'` is how many model calls a turn took. A turn that claims something happened with no `buddy_activity` chip after it, and no proposal in `buttons`, is a turn where nothing ran.
      - Deploys are in the thread already: messages with `metadata->>'source' = 'watch'` whose body starts with a deploy marker carry the commit sha, the title and the time, and a failed deploy says so. `git log` and `git show --stat` in this repo fill in what each one actually contained - read those rather than guessing from the commit title, which is usually too terse to tell you whether a specific bug was addressed.

      WHAT TO PRODUCE
      1. **Counts.** Messages per conversation AND per direction, so each companion's inbound/outbound is visible separately. Name the companion, not the id. It's one rolling 24 hours, not two calendar days - don't split it at midnight, the halves aren't comparable and the boundary means nothing.
      2. **What misfired.** Anything that didn't do what the person plainly asked, answered a question wrongly, claimed something it hadn't done, fired twice, or fired never. Cite the message id for every single one - a claim without an id is not usable. Say what should have happened instead. **One section per problem, and each one opens with its status marker** - see the next point for which.
      3. **Deploys, and what they already fixed.** List which went out and when across the window. Then reconcile: **for every problem you find, check whether a deploy LATER IN THE WINDOW addressed it, and check the traffic after that deploy to see whether it actually took.**

         **The verdict goes in the HEADLINE of that problem's own section, as the first thing in it.** Lead every finding with one of these:
         - `✅` - fixed, and the traffic after the deploy proves it. Keep it to a line or two: what broke, what shipped, done. No suggested change.
         - `⚠️` - a deploy was clearly aimed at it and the thing still happened afterwards. The most important kind of item in the report. Say what shipped and what still went wrong after it.
         - `🔲` - still open. Nothing has been deployed for it.

         **There is no separate "resolved since" section, and never a second pass over the same problems at the end.** One section per problem, its status on the front of it, and that is the only place that problem is discussed. Splitting the verdicts out from the findings means re-reading the same list twice to work out which is which, and it breaks a reply written by working down the list in order.

         Order them `⚠️` then `🔲` then `✅`, so the ones that still need something come first and the settled ones don't sit between them.

         You have no memory of previous reports - a fresh session runs each time - so the deploys are the only thing telling you whether a problem is already handled. Two places to look besides the window itself: a **previous report already in this thread** may have raised it (read back before you write it up as new), and a fix may have shipped after the window closed. Either way say so and mark it `✅` rather than handing the problem back.
      4. **Backfills.** Data that should have been written and wasn't - a watch that never fired, a chore that never advanced, a record left half-linked. Say which rows, and what the corrected value would be. Do not write them.
      5. **What to do about it lives WITH the problem**, in that problem's own section, right under the evidence: the file, the mechanism, and whether this is a one-off or something that has now failed more than once. Not gathered into a list at the end - the whole point of one-section-per-problem is that I can read a problem and reply to it in place.

         Close with a bare **priority order** if it's worth one: the open items by name, worst first, one line. A ranking, not a second telling.

      HARD RULES
      - **Never suggest compacting, debouncing, batching, deduping or collapsing messages or notifications. Ever.** Each notification is a real event and the person wants all of them. This is not a tradeoff to re-litigate; do not raise it in any form.
      - Do not suggest anything you have not seen evidence for in the data. No speculative hardening, no "might be worth considering".
      - If it was quiet and little went wrong, say so and stop. A short report is a correct report; padding it out to look thorough is worse than nothing.
      - Read the whole window in full. Do not sample.
    TXT
  end

  # Day and clock time both: the window's edges land wherever the run did, so a
  # bare date would put them in the wrong place.
  def stamp(time)
    time.strftime("%A %B %-d, %Y at %-I:%M %p")
  end

  # Kick a run by hand:
  #
  #   ByteDailyAudit.kick!                      # the last 24 hours, right now
  #   ByteDailyAudit.kick!(now: 3.days.ago)     # the 24 hours before then
  #
  # The window ends at `now`, so a kick picks up what was said a minute ago.
  # That is the point of being able to kick one.
  #
  # "already ran today" is ignored here. That guard is for a cron that can fire
  # twice across a restart, and applying it to a console call would silently do
  # nothing at the exact moment someone is watching.
  #
  # Returns as soon as the message is posted — the Mac does the actual work and
  # streams the report into the thread, same as any other Claude turn.
  def kick!(user=User.me, now: Time.current)
    run!(user, now: now, force: true)
  end

  # Post the day's prompt.
  def run!(user, now: Time.current, force: false)
    convo = conversation(user)
    return :already_ran if !force && already_ran?(user, convo, now: now)

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
