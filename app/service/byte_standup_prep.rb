# The pre-standup brief: a Claude session that reads yesterday's actual work out
# of the ocs-backend repo and writes it up next to what's already on the Standup
# list, fifteen minutes before the meeting.
#
# It replaces the -5 minute "Import Standup" step (Jil task 380 -> task 44),
# which moved the Standup list into Todo and told you nothing you hadn't typed
# yourself. The list is still the spine of the report — it's the part written on
# purpose — but half of what gets said in a standup is work you did and stopped
# thinking about the moment it merged.
#
# The brief is read in ONE place, the primary buddy thread, and that is the only
# place it should ever turn up.
#
# It can't be written there directly: a buddy thread is a GPT turn in Rails, and
# the Mac only ever runs `claude -p` for a claude-mode one. So there is a second
# thread, and it is plumbing rather than a place — it exists because that is the
# only handle on a local Claude session, it is created ARCHIVED so it stays out
# of the list and out of the unread count, and the prompt into it is `hidden`.
# Rails carries the finished text across when it settles
# (WebhooksController#byte_update -> forward!), which is what the person reads.
#
# Unarchive it when the brief says something wrong and you want the transcript —
# every tool call and every dead end is in there.
#
# READ-ONLY, and enforced by the machine rather than by the prompt: the
# conversation sits in `permission_mode: "read"`, and the Mac's PreToolUse hook
# answers every call itself from a fixed list — reads, greps, and read-only
# git/gh — and DENIES everything else outright. It never posts an action-request
# card, because there is nobody in front of this run to tap one; a card would be
# a ten-minute stall inside a fifteen-minute window.
#
# `ask` would not have done. That mode is exactly as wide as whatever has ever
# been tapped "always allow", and what had accumulated by the time this was
# written was a bare `"Bash"` in ~/code/.claude-personal/settings.json — a
# wildcard for every shell command there is — plus `Bash(git checkout:*)` and
# `Bash(git stash:*)` in ocs-backend's own `.claude/settings.local.json`. This
# job reads a repo somebody else may be working in at that exact moment, so a
# run that can switch a branch is not an acceptable one.
module ByteStandupPrep
  module_function

  NAME = "Standup Prep".freeze

  # What the -15 minute ScheduledTrigger fires. Created off the Tech Stand-Up
  # agenda item by a Jil task, the same way the -30 minute fan and the old -5
  # minute import were.
  TRIGGER = "standup-prep".freeze

  # The repo the work is in. Its linked worktrees are found from here at run
  # time with `git worktree list` — NOT by globbing `ocs-backend--*`, which on
  # this machine returns ten directories of which three are live worktrees and
  # seven are leftovers that no longer have a `.git` at all.
  CWD = "/Users/zoro/code/ocs-backend".freeze

  # Where the list lives. By name rather than by id so it survives the list
  # being rebuilt, and `by_name_for_user` is the same lookup `List.find` does
  # from Jil.
  LIST_NAME = "Standup".freeze

  def conversation(user)
    convo = user.byte_conversations.find_by(name: NAME)
    return sync!(convo) if convo

    user.byte_conversations.create!(
      name:            NAME,
      mode:            :claude,
      archived:        true,
      last_message_at: Time.current,
      metadata:        base_metadata,
    )
  end

  # Reasserted every run. Two of these matter:
  #
  # `permission_mode`, because the pwd bar's toggle only knows two states — it
  # reads anything that isn't "auto" as "ask" and writes back one of those two —
  # so a single tap would quietly downgrade this to a mode an allow rule can
  # widen.
  #
  # `archived`, because this thread is machinery and the person has a place they
  # read the brief. Unarchived it sits in the list with an unread count for a
  # report they have already read somewhere else.
  def sync!(convo)
    wanted = convo.metadata.to_h.merge(base_metadata)
    convo.update!(mode: :claude) unless convo.claude?
    convo.update!(archived: true) unless convo.archived?
    convo.update!(metadata: wanted) if convo.metadata.to_h != wanted
    convo
  end

  def base_metadata
    { "cwd" => CWD, "permission_mode" => "read", "standup_prep" => true }
  end

  # "Yesterday", meaning the last day there was work — so Monday reaches back
  # over the weekend to Friday morning rather than reporting on Sunday and
  # finding nothing. Ends at `now` so a kicked run picks up the commit from five
  # minutes ago, which is the commit most likely to need saying out loud.
  def window(user, now: Time.current)
    local = now.in_time_zone(user.timezone)
    from  = local.yesterday.beginning_of_day
    from  = from.yesterday.beginning_of_day while from.on_weekend?

    from..local
  end

  # The list as it stands, newest first. Empty is a real answer and says so in
  # the report rather than being hidden — a morning with nothing on the list is
  # a morning where the git half is all there is.
  def list_items(user)
    list = ::List.by_name_for_user(LIST_NAME, user)
    return [] if list.nil?

    list.list_items.map { |item| item.name.to_s.strip }.compact_blank
  end

  # Only one report per day, and a prompt that never reached the Mac does not
  # count as one — the same distinction DailyAuditWorker had to learn. A failed
  # row is a morning with no brief, and standing down on it means the person
  # walks into the meeting with nothing.
  def already_ran?(user, convo, now: Time.current)
    midnight = now.in_time_zone(user.timezone).beginning_of_day
    scope    = convo.byte_messages.where(direction: :outbound)
    scope    = scope.where("byte_messages.metadata ->> 'standup_prep' = 'true'")
    scope    = scope.where(byte_messages: { created_at: midnight.. })
    scope.where.not(byte_messages: { state: :failed }).exists?
  end

  def stamp(time)
    time.strftime("%A %B %-d, %Y at %-I:%M %p")
  end

  # Everything the run is asked to do.
  #
  # The mechanics — which repo, how to find the worktrees, which git commands —
  # are spelled out because a fresh session spends its first several turns
  # rediscovering them otherwise, and rediscovery inside a fifteen-minute window
  # is where a run quietly decides to look at one worktree instead of all of
  # them.
  #
  # The list is interpolated rather than left to be looked up: it is the one
  # input that is definitely relevant, it costs nothing to include, and a run
  # that fails to find it has failed at the only part the person wrote by hand.
  def prompt(user, now: Time.current)
    span  = window(user, now: now)
    items = list_items(user)
    listed = (
      if items.any?
        items.map { |name| "- #{name}" }.join("\n")
      else
        "(nothing on it this morning)"
      end
    )

    <<~TXT
      Standup is in about fifteen minutes. Write me the brief.

      Cover **#{stamp(span.first)}** through **#{stamp(span.last)}** (America/Denver) — that's "yesterday", stretched back over the weekend when there was one.

      READ ONLY. This session cannot change anything and there is nobody to ask: every tool call is answered by a hook against a fixed read-only list, and anything else is refused on the spot rather than queued. Do not retry a refused call and do not ask a question — say in the report what you couldn't find out and move on.

      **Never change what any working tree is on.** No `git checkout`, no `git switch`, no `git stash`, no `cd` into a worktree to run something. I may be mid-edit in one of these right now, and an agent may be working in another. Read every repo from where you are with `git -C <path> ...`. The one write allowed is `git fetch`, which moves remote-tracking refs and nothing else — run it once in the main repo before you judge what's merged, or you'll be reading yesterday's `origin/main`.

      WHAT'S ON THE LIST
      This is what I typed in myself and it is the spine of the report. Everything else is there to remind me of things I forgot to type.

      #{listed}

      WHERE THE WORK IS
      - `#{CWD}` is the repo. `git -C #{CWD} worktree list` gives you the live worktrees and their branches — use that. Do NOT glob for `ocs-backend--*` directories: most of them are leftovers with no `.git` and reading them tells you about work that finished weeks ago.
      - Mine are the commits by whoever `git -C #{CWD} config --get user.email` says I am — read it, don't assume it. `git -C <path> log --all --author=... --since=... --format=...` catches every branch at once; the worktrees share one object store, so you do not need to visit each to see its commits.
      - Uncommitted work needs each worktree separately: `git -C <path> status --porcelain` and `git -C <path> diff --stat` for what's dirty, and for a branch with commits that aren't on `origin/main` yet, `git -C <path> log origin/main..<branch>`.
      - Merged or not: `git -C #{CWD} branch -a --merged origin/main` after the fetch, and `gh pr list --state all --author @me` for anything sitting in review. A branch with an open PR is not merged; say which.

      WHAT TO WRITE
      Three sections, in this order:

      1. **On my list** — every item exactly as I wrote it, one line each. If git shows something that plainly IS one of these items, say so on that line rather than repeating it in section 2.
      2. **Committed** — what actually landed. One line per piece of work, and say whether it's merged, open in review, or sitting on a local branch.
      3. **Still going** — uncommitted changes and branches in flight. One line each, naming the worktree.

      **One thing, one short bullet.** A phrase, not a sentence. Enough to remind me what it was, and nothing else — no explanation of why, no file lists, exclude commit hashes, no "this improves". Several commits that are obviously the same piece of work are ONE bullet. If a section has nothing in it, write one line saying so and move on.

      This gets read in about twenty seconds, standing up, immediately before I have to say it out loud. Length is the failure mode here, not omission.
    TXT
  end

  # Kick a run by hand:
  #
  #   ByteStandupPrep.kick!                     # right now
  #   ByteStandupPrep.kick!(now: 1.day.ago)     # as of then
  #
  # Ignores "already ran today", which is a guard for a trigger that can fire
  # twice and would otherwise silently do nothing at the exact moment someone is
  # watching for a result.
  def kick!(user=User.me, now: Time.current)
    run!(user, now: now, force: true)
  end

  # Post the prompt. Returns as soon as it's away — the Mac does the work and
  # streams the report back into the prep thread, and #forward! carries it over
  # to the primary one when it settles.
  def run!(user, now: Time.current, force: false)
    convo = conversation(user)
    return :already_ran if !force && already_ran?(user, convo, now: now)

    # Fresh session, and it has to land before the prompt does — /byte/incoming
    # answers 202 and runs the turn on a thread, so a reset sent as a message
    # races the prompt it's meant to precede.
    ByteLocal.reset_claude_session(conversation_id: convo.id)
    convo.update!(metadata: convo.metadata.to_h.merge("claude_session_id" => nil, "claude_session_name" => nil))

    ByteMessageIntake.call(
      user:         user,
      conversation: convo,
      body:         prompt(user, now: now),
      metadata:     { "standup_prep" => true, "hidden" => true },
    )
    :sent
  end

  # A -15 minute ScheduledTrigger, hung off the Tech Stand-Up agenda item by a
  # Jil task and fired onto the same bus everything else rides. Production only,
  # for the reason DailyAuditWorker documents at length: a dev box runs its own
  # copy of the schedule against its own database, both machines answer "no" to
  # already-ran, and ByteLocal reaches the SAME Mac from either — so the second
  # run spends a full session re-reading the day and publishes a duplicate
  # report into production's thread.
  def dispatch(user, trigger, _payload={})
    return unless trigger.to_s == TRIGGER
    return unless ::Rails.env.production?

    ::Rails.logger.info("[StandupPrep] #{run!(user)}")
  rescue StandardError => e
    ::Rails.logger.warn("[StandupPrep] failed: #{e.class}: #{e.message}")
    ::Buddy::Errors.report(section: "standup_prep", exception: e, user: user) if defined?(::Buddy::Errors)
  end

  # The report has finished streaming into the prep thread: carry it to the
  # primary one, which is where self-initiated messages go and the only thread
  # the person is reliably looking at.
  #
  # Called from WebhooksController#byte_update on the transition to
  # `delivered`, which is the only completion signal there is — the Mac creates
  # the row as "…" and updates it as it streams.
  #
  # Guarded three ways, because this thread is a real thread and a person can
  # type in it: the message has to be a claude reply, in the prep conversation,
  # answering a message that carries `standup_prep`. A reply typed by hand the
  # next morning answers a different parent and stays where it was written.
  def forward!(message) # rubocop:disable Naming/PredicateMethod -- it acts; the boolean is just whether it did
    convo = message.byte_conversation
    return false unless convo&.name == NAME
    return false unless message.metadata.to_h["kind"] == "claude"
    return false unless prompted?(message)

    target = ::ByteConversation.for_self_initiated(message.user)
    return false if target.nil? || target.id == convo.id

    ::Buddy::CompanionDelivery.deliver_plain(
      user:         message.user,
      conversation: target,
      text:         message.body.to_s,
      metadata:     { "kind" => "buddy", "source" => "standup_prep", "standup_prep" => true },
      push_title:   "Standup brief",
    )
    true
  end

  def prompted?(message)
    parent_id = message.metadata.to_h["in_reply_to"]
    return false if parent_id.blank?

    parent = ::ByteMessage.find_by(id: parent_id)
    parent.present? && parent.metadata.to_h["standup_prep"].present?
  end
end
