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
  # isn't finished. `Buddy::Compile.flag!` sets a target roughly an hour out and
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
    QUIET_PERIOD = 1.hour

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
      You read a stretch of conversation between a person and their companion,
      and write down what is worth keeping. You are not talking to anyone. Your
      entire output is one JSON object.

      {
        "memories": [
          {
            "content": "one sentence, under 400 characters, third person",
            "summary": "3-6 words",
            "kind": "concept" | "preference",
            "severity": 0-100,
            "tags": ["lowercase", "subjects"],
            "check_in_days": null | number,
            "relevant_in_days": null | number
          }
        ],
        "updates": [
          {
            "id": <id of an open follow-up you were shown>,
            "action": "resolved" | "answered" | "dropped",
            "check_in_days": null | number,
            "note": "what they said about it, one sentence"
          }
        ],
        "face": null | "<expression name>"
      }

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

      A CLOCK TIME OR A DATE MEANS IT IS NOT A CONCEPT. Something happening once
      at a stated time is an event, and a `concept` never expires and carries no
      date - so filing one as a concept leaves a permanent record saying they do
      that at that hour, forever. If the moment is worth keeping at all it is a
      `followup` with `relevant_in_days`. If it has already been and gone, or
      something was already set up for it in the conversation, it is nothing:
      drop it.

      ONE MESSAGE CAN CARRY SEVERAL THINGS. A person mentioning a health flare
      and a job loss in one breath has told you two separate things with two
      different weights and two different timings. Split them.

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

      `check_in_days` is how long until this is worth ASKING about, unprompted.
      Leave it null unless a person who cared would actually follow up.

      - A sick pet, a hard day, a hospital visit: 0 (later today) or 1.
      - A project, an interview, something they were excited about: 3 to 14.
      - Something dated in the future - "surgery next week" - set
        `relevant_in_days` to when it happens and `check_in_days` to just after.
        Do NOT ask about next week's surgery tomorrow.

      Most memories have no check-in. An unprompted question about something
      they mentioned in passing is worse than silence.

      `relevant_in_days` says when this becomes live at all. Null means now.

      UPDATING WHAT IS ALREADY WAITING

      You are shown the follow-ups already scheduled for this person. If this
      conversation touched any of them, say so in `updates` - otherwise leave
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
        hospital, doing okay for now"). Set `check_in_days` to when it would be
        worth asking again. Leave `check_in_days` null if their update reads
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

      parsed = distill(conversation, user, messages)
      return clear!(conversation, now) if parsed.nil?

      written = Array(parsed["memories"]).filter_map { |row|
        write_memory!(user, conversation, messages, row, now)
      }
      touched = Array(parsed["updates"]).filter_map { |row| apply_update!(user, row, now) }
      apply_face(conversation, parsed["face"])

      # Placing happens once, over everything pending, so a batch of three
      # follow-ups out of one message can't all land on the same evening.
      Buddy::CheckIns.replan!(user, now: now) if written.any?(&:check_in_at) || touched.any?

      clear!(conversation, now)
      written
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
    def apply_update!(user, row, now)
      memory = BuddyMemory.where(user: user).find_by(id: row["id"])
      return nil if memory.nil?

      note = row["note"].to_s.strip
      memory.notes.create!(body: note.first(BuddyMemoryNote::MAX_BODY), source: :companion) if note.present?

      case row["action"].to_s
      when "resolved"
        memory.update!(status: :done, check_in_at: nil)
      when "dropped"
        memory.update!(status: :dropped, check_in_at: nil)
      when "answered"
        days = row["check_in_days"]
        # No new interval offered means the update was the end of it — they
        # spoke, so stop asking rather than inventing a fresh reason to.
        return memory.tap { memory.update!(check_in_at: nil) } if days.nil?

        memory.update!(check_in_at: Buddy::CheckIns.place(days_from(days, now), user: user, now: now))
      else
        return nil
      end

      memory
    rescue StandardError => e
      Rails.logger.warn("[Buddy::Compile] update failed: #{e.class}: #{e.message}")
      nil
    end

    def clear!(conversation, now)
      conversation.update_columns(
        buddy_compile_after: nil, buddy_compiled_at: now, updated_at: now,
      )
      []
    end

    # How far back the FIRST compile on a thread may reach.
    #
    # `buddy_compiled_at` is null until a thread has compiled once, and the
    # count cap alone let that first run read whatever forty messages happened
    # to be there — which on a thread older than the feature is months of
    # backlog, not a sitting. Suki's first run on 19 Aug read back to 16 Aug and
    # wrote two memories off things that had been asked for, actioned and
    # finished three days earlier: a 3pm visit became an undated permanent
    # concept, so the record now says she visits Doug at 3pm forever.
    #
    # Six hours because a compile fires QUIET_PERIOD after the last message, so
    # this covers the sitting that just ended with hours to spare and reaches no
    # further. Chelsea's thread has never compiled either and was primed to do
    # exactly the same thing.
    FIRST_READ = 6.hours

    # Everything since the last compile, capped. A thread that has never
    # compiled reads the sitting that just happened, not its history.
    def window(conversation, now: Time.current)
      since = conversation.buddy_compiled_at || (now - FIRST_READ)
      scope = conversation.byte_messages.order(created_at: :desc).where("created_at > ?", since)
      scope.limit(WINDOW * 3).to_a.reject { |m| skip?(m) }.first(WINDOW).reverse
    end

    def skip?(message)
      meta = message.metadata.is_a?(Hash) ? message.metadata : {}
      return true if meta["hidden"]
      return true if SKIP_SOURCES.include?(meta["source"].to_s)
      return true if SKIP_KINDS.include?(meta["kind"].to_s)

      message.body.to_s.strip.empty?
    end

    def distill(conversation, user, messages)
      result = Buddy::GPT::Client.new(model: MODEL, reasoning_effort: nil).stream(
        instructions: INSTRUCTIONS,
        input:        [{ role: :user, content: brief(conversation, user, messages) }],
      )
      record_usage(result, conversation)
      return nil unless result[:ok]

      parse(result[:text])
    end

    # Tolerant of the fences a model wraps JSON in even when told not to. A
    # compile that can't be parsed writes nothing, which is the same outcome as
    # a compile that found nothing — so it degrades to silence rather than to an
    # error the person would see.
    def parse(text)
      raw = text.to_s.strip.sub(/\A```(?:json)?/, "").sub(/```\z/, "").strip
      body = raw[/\{.*\}/m]
      return nil if body.blank?

      parsed = JSON.parse(body)
      parsed.is_a?(Hash) ? parsed : nil
    rescue JSON::ParserError => e
      Rails.logger.warn("[Buddy::Compile] unparseable output: #{e.message}")
      nil
    end

    def brief(conversation, user, messages)
      <<~TXT
        PERSON: #{user.first_name}

        THE COMPANION'S CURRENT FACE: #{conversation.buddy_expression.presence || "neutral"}
        AVAILABLE FACES: #{Buddy::Faces.selectable(conversation.buddy_theme).join(", ")}

        ALREADY KEPT (do not repeat any of these):
        #{existing(user)}

        FOLLOW-UPS ALREADY SCHEDULED (update these by id if the conversation touched them):
        #{pending(user)}

        THE CONVERSATION:
        #{stretch(conversation, messages)}
      TXT
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
    def existing(user)
      rows = BuddyMemory.where(user: user).unexpired.for_recall.limit(40).to_a
      return "(nothing yet)" if rows.empty?

      rows.map { |m| "- #{m.summary.presence || m.content.to_s.truncate(80)}" }.join("\n")
    end

    def stretch(conversation, messages)
      name = conversation.buddy_name
      messages.map { |message|
        who = message.direction == "outbound" ? "Them" : name
        "#{who}: #{message.body.to_s.strip}"
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

    def write_memory!(user, _conversation, messages, row, now)
      content = row["content"].to_s.strip
      return nil if content.empty?
      return nil if duplicate?(user, content)

      kind = %w[concept preference].include?(row["kind"].to_s) ? row["kind"].to_s : "concept"
      memory = BuddyMemory.new(
        user:           user,
        kind:           kind,
        content:        content.first(BuddyMemory::MAX_CONTENT),
        summary:        row["summary"].to_s.strip.presence&.first(BuddyMemory::MAX_SUMMARY),
        severity:       clamp_severity(row["severity"]),
        source_message: origin_message(messages, content),
        last_used_at:   now,
      )
      memory.tag_list = row["tags"]
      memory.relevant_at = days_from(row["relevant_in_days"], now)
      arm_check_in(memory, row, now)
      memory.save!
      memory
    rescue StandardError => e
      Rails.logger.warn("[Buddy::Compile] memory write failed: #{e.class}: #{e.message}")
      nil
    end

    # A follow-up is a memory that also carries a time to come back to it. The
    # severity floor is what stops "they mentioned a mug preference" turning
    # into an unprompted question three days later.
    def arm_check_in(memory, row, now)
      days = row["check_in_days"]
      return if days.nil?

      memory.kind = :followup
      return if memory.severity < BuddyMemory::CHECK_IN_FLOOR

      base = [days_from(days, now), memory.relevant_at].compact.max || now
      memory.check_in_at = Buddy::CheckIns.place(base, user: memory.user)
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
    def duplicate?(user, content)
      norm = content.downcase.gsub(/[^a-z0-9 ]/, "").squeeze(" ").strip
      return false if norm.length < 12

      BuddyMemory.where(user: user).unexpired.where(kind: [:concept, :preference, :followup]).any? { |m|
        m.content.to_s.downcase.gsub(/[^a-z0-9 ]/, "").squeeze(" ").strip == norm
      }
    end

    # The stale-face fix (prod message 3908: an unmistakably warm and correct
    # reply about a health flare and a job loss, delivered wearing `happy`).
    #
    # The mood persists by design — Buddy::ExpressionState keeps it until
    # something DELIBERATELY changes it — so a turn that emits no `[[mood:]]`
    # marker inherits whatever the last cheerful exchange left behind. That is
    # the default, and it fails hardest exactly where it shows most.
    #
    # Correcting it here is a beat late, which the persona rightly complains
    # about. A beat late is still better than an hour wrong.
    def apply_face(conversation, face)
      wanted = face.to_s.strip
      return if wanted.empty?
      return if conversation.buddy_expression.to_s == wanted

      Buddy::SideEffects.apply_mood(conversation, wanted)
    rescue StandardError => e
      Rails.logger.warn("[Buddy::Compile] face correction failed: #{e.class}: #{e.message}")
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
