module Buddy
  # Reads a stretch of conversation once it has gone quiet and writes down
  # whatever was worth keeping — as memories, as follow-ups, or as both.
  #
  # This is the widened capture. `remember` still exists and still writes the
  # preferences the model is explicitly told to hold, but it only ever fires
  # when the model thinks to call it, and Buddy::IdeaDwell's header is the
  # standing evidence for how that goes: a tool with an explicit instruction to
  # reach for it went unused across a 22-minute conversation, because the
  # general "pure conversation takes no tools" rule beat the specific
  # instruction every time. Somebody saying their cat is dying is exactly the
  # kind of turn that takes no tools.
  #
  # So nothing here depends on the model noticing in the moment. Every turn with
  # a person's message in it flags the conversation; the flag says only "there
  # was conversation here", not what it was about. Deciding what mattered
  # happens later, once, over the whole stretch.
  #
  # ## Why it waits
  #
  # Someone who has just said their cat is dying should not sit watching a
  # spinner while a model sorts through their history. The reply goes out first
  # and this runs behind it — and not immediately, because the stretch usually
  # isn't finished. `Buddy::Compile.flag!` sets a target a quarter of an hour out and
  # every further message pushes it back, so one compile covers a whole
  # conversation instead of one per message.
  #
  # The worker never cancels or tracks Sidekiq jids. It fires, re-reads the
  # target, and reschedules itself when the target has moved — the same shape
  # TimerFireWorker uses for drift. That survives a dropped job, a restart, and
  # two turns racing, none of which jid bookkeeping does.
  #
  # ## One message, several records
  #
  # This is the normal case, not the exception. Prod message 3907:
  #
  #   "Just noticed that my CSCR has flared up a bit today. Likely related to
  #    the fact that I heard that I'll be out of a job before the end of the
  #    year."
  #
  # is an eye condition worth asking about in a while, a stress worth asking
  # about soon, and a job situation worth REMEMBERING and asking about later —
  # three records, three severities, three timings, out of two sentences. So the
  # model returns a list and every entry is written on its own.
  module Compile
    module_function

    # How long after the last message the stretch is presumed over. Long enough
    # that a pause to make coffee doesn't count as the end of a conversation.
    QUIET_PERIOD = 15.minutes

    # How far back a compile reads. Bounded so a marathon thread doesn't hand a
    # cheap model a novel; the debounce means this is normally one sitting.
    WINDOW = 40

    # Cheapest thing that can read a transcript and make a judgement about it,
    # same as compaction and idea notes. Distilling is not the work Buddy is
    # good at, it's the work Buddy needs done quietly.
    MODEL = "gpt-5.4-mini".freeze

    # Kinds that aren't somebody talking. Same list Buddy::IdeaDwell skips, for
    # the same reason: a doorbell notification should not get a vote on what the
    # conversation was about.
    SKIP_KINDS = %w[action_chip buddy_activity buddy_trigger buddy_receipt].freeze

    # Sources that are the APP asking or announcing, not the conversation.
    #
    # `watch` was already here. `form` is the attribution prompt ("Who did:
    # Puppy Up?"), which is a widget with buttons and reads as a question the
    # companion asked. Prod memory 64 is what that costs: the form went up at
    # 15:04, Rocco typed an unrelated printer command at 15:13, and the compile
    # read them as one exchange and wrote down that "Puppy Up" MEANS "print game
    # tray vase". Two unrelated things fused into a false definition, which is
    # worse than either being lost - it is now a fact about his vocabulary.
    SKIP_SOURCES = %w[watch form relay_copy].freeze

    INSTRUCTIONS = <<~TXT.freeze
      You keep the long-term record of one person, and you are the ONLY thing
      that writes it. Their companion talks to them and acts for them in the
      moment; once a conversation has gone quiet you read the whole
      stretch at once and decide what it changed about what is held. Nobody
      reads what you say and nothing you write is shown to anyone - your tools
      are the entire result of this run.

      You have as many rounds as you need, and the stretch below is a starting
      point rather than a limit. GO AND LOOK before you write. If something
      refers to an exchange you cannot see - a "that", a "the thing we talked
      about", a plan whose beginning is missing - call `read_conversation` and
      keep calling it, paging back with `before`, until you have the part that
      explains it or you reach the start of the thread. Deciding from half a
      conversation is how a finished errand becomes a permanent fact.

      Same with what is held: `search_memories` before writing anything you
      suspect is already there. A run that changes nothing is a good run and is
      the usual one.

      YOUR TOOLS

      - `search_memories` - everything held, well past the rows listed below.
      - `read_conversation` - further back than the stretch you were given.
      - `write_memory` - hold something new.
      - `revise_memory` - rewrite a row that is already there.
      - `close_memory` - retire one: `done` if it happened, `dropped` if it
        stopped being worth holding.
      - `set_check_in` - when a follow-up is worth asking about, or no longer is.

      Stop calling tools when you are finished. A short sentence saying what you
      did is fine and goes nowhere.

      A PAUSE IS NOT A NEW SUBJECT. Every line carries its time, and you will
      see gaps - minutes, hours, sometimes days. None of that decides anything
      on its own: people come back after four days and carry straight on as
      though they never left, and they also change the subject completely
      between two messages a minute apart. Read what was said. If a line only
      makes sense as a continuation of something earlier, it IS one, whatever
      the clock says in between.

      Anything above the "read before" line you have already weighed once. That
      is not a reason to skip it - it is context for what came after, and a
      second look is your chance to improve what you wrote the first time.

      CHECK WHAT THE COMPANION SAID IT DID

      You are reading its side of the conversation as well as theirs, and it
      answers in the moment with no way to look back. So it sometimes says a
      thing is handled when nothing was written. On 14 Aug it was taught an
      Afrikaans saying and replied "that's in the house words too" - and it was
      not, anywhere, until somebody noticed five days later.

      A claim looks like: "I'll remember that", "tucked away", "got it", "that's
      on your list now", "I've set that". For anything it claimed to REMEMBER,
      you can settle it yourself: `search_memories` for the thing, and if it
      isn't there, `write_memory` it. That is the promise being kept rather than
      a note about a promise.

      For a claim about something you can't write - a reminder, a list, the
      calendar - check the ALREADY DONE list first, because a receipt there
      means it really happened and there is nothing to fix. If a claim has no
      receipt and no other sign of it, hold a `followup` saying what they were
      told was done, so it comes up rather than being quietly wrong forever.
      Don't do this for small talk; do it for anything they would act on.

      WHAT TO KEEP

      Keep something when a person reading it back in six months would be glad
      it was there:

      - Things that happened to them, especially with a lesson attached. "They
        forgot the sleeping bags on the last camping trip" is worth keeping
        precisely because it is useless until the next camping trip.
      - What they are going through: an illness, a job situation, a strained
        relationship, a big project, a worry they voiced.
      - Facts about their world - people, pets, places, how things work at their
        house, what a word of theirs means.
      - How they want things done. Those are `kind: "preference"` and they get
        carried in every conversation, so keep that kind rare and genuinely
        about their preferences.

      Do NOT keep: what they had for lunch, small talk, anything already handled
      by an action that was taken, or anything already in the EXISTING list you
      are shown. Nothing at all is a perfectly good answer, and it is the right
      one most of the time.

      A REQUEST THAT WAS CARRIED OUT IS NOT A PREFERENCE. If they asked for
      something and the ALREADY DONE list shows it was set up, the record of it
      is the thing that was set up - a reminder, a list item, an agenda entry.
      Writing "they want X" alongside the X that now exists stores the same
      request twice, and the copy in here has no way to be cancelled when they
      change their mind about the real one.

      A CLOCK TIME OR A DATE MEANS IT IS NOT A CONCEPT. Something happening once
      at a stated time is an event, and a `concept` never expires and carries no
      date - so filing one as a concept leaves a permanent record saying they do
      that at that hour, forever. If the moment is worth keeping at all it is a
      `followup` with a check-in. If it has already been and gone, or
      something was already set up for it in the conversation, it is nothing:
      drop it.

      ONE MESSAGE CAN CARRY SEVERAL THINGS. A person mentioning a health flare
      and a job loss in one breath has told you two separate things with two
      different weights and two different timings. Split them.

      EVERY ROW HAS TO STAND ALONE. These are never read in order, never read
      beside each other, and one surfaces months later with no conversation
      around it. So splitting a sentence in two is not finished until both
      halves make sense by themselves: "after that, clear out the pantry" leans
      on a row that will not be there, and comes back out as a sentence about
      nothing. Say which thing it comes after, or say it without the ordering.

      WRITE THE FACT, NOT A NOTE ABOUT THE FACT. Content is handed over as
      something TRUE ABOUT THEM. An instruction filed there - "do not remind her
      about this", "check on this next week", "the earlier version was wrong" -
      does nothing at all, because nothing reads content and acts on it; it just
      comes back out as a claim about the person.

      Each of those has a tool: something to come back to is `set_check_in`, a
      row that is finished or no longer worth holding is `close_memory`, and a
      row that is wrong is `revise_memory`. A sentence describing what should
      happen is the one option that does nothing.

      A CORRECTION IS NOT A MEMORY. When they fix something mid-conversation -
      a spelling, a name, a misunderstanding - what to keep is the corrected
      fact, written once, correctly. That there was a mistake, and what the
      mistake was, is not a fact about them and does not belong in the row. If
      the wrong version is already held, `revise_memory` it; otherwise just
      write the right one.

      TIDY WHAT IS ALREADY THERE. Every row in ALREADY KEPT carries its id, and
      `revise_memory` rewrites one in place - content, summary, tags. Reach for it
      when this stretch changed something you already hold rather than adding to
      it:

      - The same fact said better, or with the part that was missing. A row that
        only makes sense next to another one is the clearest case: rewrite it so
        it stands alone.
      - Two rows that turned out to be one thing. Revise the fuller one to say
        all of it, and `dropped` the other. Never leave both.
      - A row that has drifted - a project that moved on, a detail that changed.
        Rewrite it as it is now.

      Rewriting is not free: the old wording is kept as a note, so a bad rewrite
      can be seen and undone, but the row itself is what everything reads. Only
      revise when THIS conversation gave you a reason to. Tidying for its own
      sake, across rows nobody mentioned, is how a memory quietly turns into
      something they never said.

      SEVERITY, 0-100

      How much this matters to their life, NOT how interesting it is.

      - 0-15   trivia and conveniences. A preference about mug size.
      - 16-40  ordinary life. A project they're enjoying, a mild annoyance.
      - 41-70  things that weigh on someone. Money worry, a rough patch, a
               relationship strain, a health thing that isn't dangerous.
      - 71-100 the big ones. Serious illness, bereavement, losing a job, a
               relationship ending. Reserve the top for what genuinely
               dominates a life.

      CHECKING IN

      A check-in is how long until this is worth ASKING about, unprompted.
      Leave it null unless a person who cared would actually follow up.

      - A sick pet, a hard day, a hospital visit: 0 (later today) or 1.
      - A project, an interview, something they were excited about: 3 to 14.
      - Something dated in the future - "surgery next week" - set
        the check-in to just after it happens.
        Do NOT ask about next week's surgery tomorrow.

      Most memories have no check-in. An unprompted question about something
      they mentioned in passing is worse than silence.

      A check-in in the future is also how something becomes live later rather
      than now.

      UPDATING WHAT IS ALREADY WAITING

      You are shown the follow-ups already scheduled for this person. If this
      conversation touched any of them, say so with the tools - otherwise leave
      the list empty.

      A check-in exists to ASK a question. Someone who volunteers the answer
      first has made that question redundant, and a companion that asks how you
      are feeling six hours after you told it is worse than one that never
      asked. So when they bring it up themselves, act on it:

      - "resolved" - it's over, or they've said it's fine now. Nothing asks
        again. A pending emotional check-in is resolved by them simply telling
        you how they are - a good day reported unprompted answers "how are they
        doing" completely.
      - "answered" - they gave an update and it is still going ("she's still in
        hospital, doing okay for now"). `set_check_in` to when it would be
        worth asking again. Clear it if their update reads
        like the end of it.
      - "dropped" - it stopped being worth asking about at all.

      `note` is what they actually said about it, and it gets kept on the
      thread, so write it even when the action is "resolved".

      Do NOT update a follow-up the conversation didn't touch.

      THE FACE

      You are also shown the expression the companion is currently wearing. If
      it plainly contradicts what the conversation turned out to be about - a
      cheerful face on someone describing a bereavement - return the expression
      it should be wearing in `face`. Otherwise return null. Only choose from
      the list of available faces you are given.

      Write everything in the third person, about the person. Prose, no
      markdown, no em dashes.
    TXT

    # Note the conversation had a real exchange in it and set the compile for
    # once it's over. Called on every turn carrying a person's message; the flag
    # itself makes no claim about whether anything was worth keeping.
    def flag!(conversation, now: Time.current)
      return if conversation.nil?

      conversation.update_columns(buddy_compile_after: now + QUIET_PERIOD, updated_at: now)
      BuddyCompileWorker.perform_at(now + QUIET_PERIOD, conversation.id)
    rescue StandardError => e
      Rails.logger.warn("[Buddy::Compile] flag failed: #{e.class}: #{e.message}")
    end

    # Run the compile if the conversation really has gone quiet; otherwise
    # reschedule for whenever the target has moved to. Returns the records
    # written, empty when there was nothing worth keeping.
    def run!(conversation, now: Time.current)
      return [] if conversation.nil?

      target = conversation.buddy_compile_after
      return [] if target.nil?

      # A message landed after this job was queued, so the stretch isn't over.
      # Exit rather than rescheduling: `flag!` enqueued a job for the new target
      # at the moment it moved it, so one already exists. A job that reschedules
      # itself here would be a second one, and under inline execution it
      # re-enters immediately and never unwinds.
      return [] if target > now

      # Two compiles of one stretch would write the same records twice.
      attempt = ByteConversation.with_advisory_lock_result(
        "buddy_compile:#{conversation.id}", timeout_seconds: 0
      ) { compile!(conversation, now) }

      attempt.lock_was_acquired? ? attempt.result : []
    rescue StandardError => e
      Buddy::Errors.report(
        section:   "compile.run",
        exception: e,
        user:      conversation&.user,
        extra:     { conversation_id: conversation&.id },
      )
      []
    end

    def compile!(conversation, now)
      user     = conversation.user
      messages = window(conversation)
      return clear!(conversation, now) if user.nil? || messages.size < 2
      return clear!(conversation, now) unless fresh?(conversation, messages)

      box = Buddy::Compile::Toolbox.new(
        user: user, conversation: conversation, messages: messages, now: now,
      )
      converse!(conversation, user, messages, box, now)

      # Placing happens once, over everything pending, so a batch of three
      # follow-ups out of one message can't all land on the same evening.
      if box.written.any?(&:check_in_at) || box.touched.any?
        Buddy::CheckIns.replan!(user, now: now)
      end

      clear!(conversation, now)
      box.written
    end

    # The pass, as a conversation with itself rather than one shot at a JSON
    # blob.
    #
    # It used to answer once, in a fixed shape, and Rails applied whatever came
    # back. That could only ever ADD: forty truncated labels was not enough to
    # judge overlap, there was no way to look further, and nothing could fix a
    # row that was already wrong. Every tangle found in prod on 19 Aug — the
    # same request held twice, a sentence leaning on a row beside it, a
    # correction stored instead of applied — was something this pass had written
    # and then had no means to repair.
    #
    # Rounds are bounded and the tools are its own. There is nobody waiting on
    # this, so the cost of a loop that will not settle is a quiet bill rather
    # than a hang, which is why the ceiling is well under the turn's.
    def converse!(conversation, user, messages, box, now)
      client = Buddy::GPT::Client.new(model: MODEL, reasoning_effort: nil)
      input  = [{ role: :user, content: brief(conversation, user, messages, now) }]

      Buddy::Compile::Toolbox::MAX_ROUNDS.times do
        result = client.stream(
          instructions: INSTRUCTIONS, input: input, tools: Buddy::Compile::Toolbox.schemas,
        )
        record_usage(result, conversation)
        return nil unless result[:ok]

        calls = Array(result[:tool_calls])
        return result[:text] if calls.empty?

        input += calls.flat_map { |call|
          answer = box.call(call[:name], call[:arguments])
          [
            {
              type:      :function_call,
              call_id:   call[:call_id],
              name:      call[:name].to_s,
              arguments: JSON.generate(call[:arguments] || {}),
            },
            { type: :function_call_output, call_id: call[:call_id], output: answer.to_s },
          ]
        }
      end

      Rails.logger.info("[Buddy::Compile] hit the round ceiling for conversation #{conversation.id}")
      nil
    rescue StandardError => e
      Buddy::Errors.report(section: "compile.converse", exception: e, user: user)
      nil
    end

    # Act on a follow-up that was already waiting, because the person has since
    # said something about it themselves.
    #
    # This is the half a write-only compile was missing. A check-in exists to
    # ASK a question; someone who volunteers the answer first has made the
    # question redundant, and the worst version of this feature is a companion
    # that asks how you're feeling six hours after you told it. It matters most
    # for exactly the check-ins that are about somebody's state — those get
    # armed readily and go stale fastest.
    #
    # Three outcomes:
    #
    #   resolved  — it's done, or the update closed it out. Status goes `done`
    #               and the check-in is disarmed. Nothing asks again.
    #   answered  — they gave an update and it's still live ("she's still in the
    #               hospital, doing okay"). The answer lands on the thread as a
    #               note and the check-in is re-armed further out. This is the
    #               re-arm path: `checked_in_at` is a last-checked mark, not a
    #               seal.
    #   dropped   — no longer worth asking about at all.
    def clear!(conversation, now)
      conversation.update_columns(
        buddy_compile_after: nil, buddy_compiled_at: now, updated_at: now,
      )
      []
    end

    # The last stretch of real conversation, however long ago any of it was.
    #
    # It used to read from `buddy_compiled_at` forward, which left every run
    # after a mid-conversation compile blind to everything before it: somebody
    # talks for twenty minutes, pauses long enough to trip the debounce, carries
    # on — and the next run sees only the second half, judging "so I'll do that
    # on Thursday then" with no idea what THAT is.
    #
    # There is deliberately NO time boundary here. A gap is not a subject
    # change: people come back four days later and carry straight on as though
    # they never left, and cutting the read at some number of hours would throw
    # away the half of that conversation that explains the other half. Whether
    # the thread moved on is a question about what was SAID, so the timestamps
    # go in the brief and the model judges it — and `read_conversation` is there
    # when it needs more than this.
    #
    # Re-reading what it already saw is the point rather than the cost: it can
    # revise and consolidate now, so a second look at the same exchange is a
    # chance to improve what it wrote the first time. `duplicate?`, the ALREADY
    # KEPT list and the instruction against repeating are what stop that
    # becoming a second copy.
    def window(conversation, _now: Time.current)
      recent = conversation.byte_messages.order(created_at: :desc).limit(WINDOW * 3).to_a
      recent.reject { |m| skip?(m) }.first(WINDOW).reverse
    end

    # Whether anything has actually been said since the last run. Without this
    # the whole-stretch read would recompile the same exchange on every debounce
    # for as long as the conversation lasts, paying a model call each time to
    # reach the same conclusion.
    def fresh?(conversation, messages)
      compiled = conversation.buddy_compiled_at
      return true if compiled.nil?

      messages.any? { |m| m.created_at > compiled }
    end

    def skip?(message)
      meta = message.metadata.is_a?(Hash) ? message.metadata : {}
      return true if meta["hidden"]
      return true if SKIP_SOURCES.include?(meta["source"].to_s)
      return true if SKIP_KINDS.include?(meta["kind"].to_s)

      message.body.to_s.strip.empty?
    end

    def brief(conversation, user, messages, now)
      <<~TXT
        PERSON: #{user.first_name}
        TODAY: #{now.in_time_zone(Buddy::Day.zone(user)).strftime("%A %-d %b %Y")}

        THE COMPANION'S CURRENT FACE: #{conversation.buddy_expression.presence || "neutral"}
        AVAILABLE FACES: #{Buddy::Faces.selectable(conversation.buddy_theme).join(", ")}

        ALREADY KEPT (do not repeat any of these):
        #{existing(user)}

        FOLLOW-UPS ALREADY SCHEDULED (update these by id if the conversation touched them):
        #{pending(user)}

        ALREADY DONE IN THIS STRETCH - these were asked for and HANDLED, so keep nothing about them:
        #{receipts(conversation, messages)}

        THE CONVERSATION:
        #{stretch(conversation, messages)}
      TXT
    end

    # What the companion actually DID while this was being said.
    #
    # A receipt is `buddy_activity`, which SKIP_KINDS drops so a doorbell
    # notification can't vote on what the conversation was about — and dropping
    # it took the evidence with it. Asked for a daily nudge on 19 Aug, Suki set
    # the reminder and posted "Suki will remind you every day at 9am"; the
    # compile saw only the asking and wrote down "she wants a daily reminder to
    # let things go" as a standing preference, so the same request now exists
    # twice, once as a live reminder and once as a fact about her.
    #
    # Listed apart from the transcript rather than folded back into it: these
    # are not somebody talking, and the whole reason they were filtered stands.
    # What changes is that the rule against keeping something "already handled
    # by an action that was taken" now has the actions in front of it.
    RECEIPT_KINDS = %w[buddy_activity buddy_receipt action_chip].freeze

    def receipts(conversation, messages)
      window = messages.first&.created_at
      return "(none)" if window.blank?

      rows = conversation.byte_messages.where(created_at: window..).order(:created_at).select { |m|
        meta = m.metadata.is_a?(Hash) ? m.metadata : {}
        RECEIPT_KINDS.include?(meta["kind"].to_s) && m.body.to_s.strip.present?
      }
      return "(none)" if rows.empty?

      rows.last(15).map { |m| "- #{m.body.to_s.squish.truncate(120)}" }.join("\n")
    rescue StandardError => e
      Rails.logger.warn("[Buddy::Compile] receipts failed: #{e.class}: #{e.message}")
      "(none)"
    end

    # The open follow-ups, by id, so a conversation that answered one can say
    # so. Without this the compile can only ever add, and a person who tells
    # their companion they're feeling better still gets asked about it later.
    def pending(user)
      rows = BuddyMemory.where(user: user).kind_followup.live.where.not(check_in_at: nil)
      rows = rows.order(:check_in_at).limit(20).to_a
      return "(none)" if rows.empty?

      rows.map { |m| "- ##{m.id} #{m.summary.presence || m.content.to_s.truncate(90)}" }.join("\n")
    end

    # What's already held, so the compile doesn't write a fourth copy of a fact
    # it has written three times. Deliberately the labels only — the full text
    # of every memory would be most of the reason this runs on a cheap model.
    # Ids and full wording, because `revised` needs both: a row can't be tidied
    # without being nameable, and overlap can't be judged off a label truncated
    # at 80 characters. It used to be labels only — enough to avoid writing a
    # fourth copy of the same fact, and not enough to fix the three already
    # there.
    def existing(user)
      rows = BuddyMemory.where(user: user).unexpired.for_recall.limit(40).to_a
      return "(nothing yet)" if rows.empty?

      rows.map { |m| "- ##{m.id} [#{m.kind}] #{m.content.to_s.squish.truncate(200)}" }.join("\n")
    end

    # Timestamped, and marked where the last run stopped reading. Both are
    # judgement the model has to make rather than judgement made for it: how
    # long a pause was, and which of this it has weighed before.
    def stretch(conversation, messages)
      name     = conversation.buddy_name
      compiled = conversation.buddy_compiled_at
      zone     = Buddy::Day.zone(conversation.user)
      marked   = false

      messages.map { |message|
        line = +""
        if compiled && !marked && message.created_at > compiled
          marked = true
          line << "--- you have read everything above this line before ---\n"
        end
        who = message.direction == "outbound" ? "Them" : name
        line << "[#{message.created_at.in_time_zone(zone).strftime("%a %-d %b, %-l:%M%P")}] #{who}: #{message.body.to_s.strip}"
      }.join("\n")
    end

    # Which message in the window this memory actually came out of.
    #
    # It used to be the LAST thing the person said, which is where they stopped
    # talking and has nothing to do with where the content came from: both
    # memories written off Suki's thread on 19 Aug point at a goodnight message
    # containing neither subject. Nothing reads `source_message` yet, which is
    # precisely why it has to be right or absent - a provenance link is only
    # worth having if following it lands somewhere, and a wrong one is worse
    # than none the first time somebody trusts it.
    #
    # Overlap on the distinctive words, and nil when nothing carries them.
    ORIGIN_MIN_OVERLAP = 2

    def origin_message(messages, content)
      words = content.to_s.downcase.scan(/[a-z]{5,}/).uniq
      return nil if words.empty?

      scored = messages.select { |m| m.direction == "outbound" }.map { |m|
        body = m.body.to_s.downcase
        [m, words.count { |word| body.include?(word) }]
      }
      best, score = scored.max_by { |(_, count)| count }

      score.to_i >= ORIGIN_MIN_OVERLAP ? best : nil
    end

    def days_from(days, now)
      return nil if days.nil?

      now + (days.to_f.clamp(0, 3650) * 1.day)
    end

    def clamp_severity(value)
      value.to_i.clamp(BuddyMemory::SEVERITY_RANGE.min, BuddyMemory::SEVERITY_RANGE.max)
    end

    # Cheap guard against writing the same thing twice when a stretch gets
    # compiled and then the person immediately says it again. The model is also
    # shown what's already held; this catches what it writes anyway.
    #
    # EVERY kind, not three of them. `stash` was missing, which is how memory 88
    # came to be a byte-identical copy of 84 - same content, same
    # source_message_id, written half an hour later by the compile pass over a
    # row this check couldn't see.
    #
    # And spaces come out with the punctuation. Keeping them meant `naptime` and
    # `nap time` normalized differently and both got written (78 and 82), which
    # is the same fact twice with a space between.
    #
    # Two tests, because string equality only ever catches a verbatim repeat and
    # the gap between the two writes is where the wording moves. The inline
    # `remember` path writes first and stamps no source_message_id, then compile
    # re-reads the same turns half an hour later and says it again in its own
    # words: "a good time for Eve to water outside" became "for her" (79/83),
    # and a followup grew its own second half (76/80). Buddy::SideEffects
    # already knew how to tell those apart for the inline path; this asks it.
    def duplicate?(user, content)
      return true if restates_feature_request?(user, content)

      norm = normalize_memory(content)
      return subsumed?(user, content) if norm.length < 12

      BuddyMemory.where(user: user).unexpired.any? { |m|
        normalize_memory(m.content) == norm || Buddy::SideEffects.same_fact?(content, m.content)
      }
    end

    # A record that already exists in a DIFFERENT table.
    #
    # `feature_requests` is the only one a compile pass can restate, because it
    # is the only one the companion raises mid-conversation and then describes
    # back in prose. Memory 97 - "Rocco needs a feature request for Inventory
    # access" - was written half an hour after feature request 1 was created
    # with a receipt chip saying so. A note about a row is not the row, and
    # holding one keeps a finished job on the pile forever.
    def restates_feature_request?(user, content)
      words = Buddy::SideEffects.significant_words(content.to_s.downcase)
      return false if words.size < 2

      FeatureRequest.where(user: user).live.pluck(:title).any? { |title|
        title_words = Buddy::SideEffects.significant_words(title.to_s.downcase)
        title_words.any? && title_words.subset?(words)
      }
    end

    # Content too short for the string tests above, which is where the floor
    # used to give up and answer false.
    #
    # A one-word stash ("pantry") is almost never a new thing to do; it is
    # somebody agreeing about one already on the pile - memory 91 was written
    # off "Keep the pantry on the stash pile", which is a sentence asking to
    # KEEP memory 60. Word containment rather than substring, so "milk" doesn't
    # collide with "buttermilk", and it needs at least one word worth carrying.
    def subsumed?(user, content)
      words = Buddy::SideEffects.significant_words(content.to_s.downcase)
      return false if words.empty?

      BuddyMemory.where(user: user).unexpired.any? { |m|
        words.subset?(Buddy::SideEffects.significant_words(m.content.to_s.downcase))
      }
    end

    def normalize_memory(content)
      content.to_s.downcase.gsub(/[^a-z0-9]/, "")
    end

    # Its own usage kind so a compile's spend stays legible next to a turn's.
    def record_usage(result, conversation)
      BuddyUsage.record!(
        result,
        user:         conversation.user,
        kind:         :compile,
        conversation: conversation,
      )
    rescue StandardError => e
      Rails.logger.warn("[Buddy::Compile] usage record failed: #{e.class}: #{e.message}")
    end
  end
end
