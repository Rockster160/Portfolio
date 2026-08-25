module Buddy
  module Compile
    # What the background memory pass can DO.
    #
    # Compile used to answer in one shot with a JSON blob that Rails applied,
    # which is why it could only ever add: it saw forty labels, wrote what it
    # thought was new, and had no way to look further or fix what was there.
    # These are its hands.
    #
    # Deliberately NOT registered in Buddy::Tools. That registry is the
    # conversational turn's, where every entry becomes a proposal row with a
    # checkbox in front of somebody. Nothing here is ever shown to anyone —
    # this pass runs an hour after the conversation ended and answers to no
    # message.
    class Toolbox
      # A memory outlives the day it was written on, so a word that means a
      # different day tomorrow does not belong in one.
      #
      # `buddy_memories` 105, written 15:21 Mon 24 Aug: "Eve has a therapist
      # appointment with Iberty tomorrow at 10:00 AM", `check_in_at` 6pm the
      # NEXT evening and no expiry. By the time it reads itself out, "tomorrow"
      # means Wednesday and the appointment was that morning. Rows 44 and 71
      # carry the same defect ("...tomorrow, since it will be trash day",
      # "...to tonight's agenda"); both have since been dropped, and the third
      # occurrence in three weeks is what says prose is the wrong place for it.
      #
      # "Stands alone" was already there and is evidently not enough - a
      # sentence with "tomorrow" in it reads as standing alone, right up until
      # it is read on a different day. So the failures get named.
      MEMORY_CONTENT_DATES = "Write every date and time ABSOLUTELY - " \
                             "\"on Tue 25 Aug at 10:00 AM\", never \"tomorrow\", " \
                             "\"tonight\", \"next week\" or \"today\". " \
                             "This row will be read on a day that is not this one.".freeze
      MEMORY_CONTENT = "The whole fact, as one sentence that stands alone. #{MEMORY_CONTENT_DATES}".freeze

      # What this run changed, so the caller can replan check-ins over the
      # result and report what it did.
      attr_reader :written, :touched

      def initialize(user:, conversation:, messages:, now: Time.current)
        @user         = user
        @conversation = conversation
        @messages     = messages
        @now          = now
        @written      = []
        @touched      = []
      end

      # Room to actually go looking. Reading back through a long thread costs a
      # round per page, so a ceiling tight enough to be safe for a turn would
      # spend the whole budget on lookups and leave none for the writing. This
      # is a cheap model against a bounded transcript with nobody waiting on it,
      # and the failure mode of a loop that will not settle is a quiet bill
      # rather than a visible hang.
      MAX_ROUNDS = 14

      SCHEMAS = [
        {
          type:        :function,
          name:        "search_memories",
          strict:      false,
          description: "Search everything held about this person, well past the forty shown to " \
                       "you. Use before writing anything you suspect is already held, and to " \
                       "find the rows a new fact belongs with.",
          parameters:  {
            type:       :object,
            properties: {
              query: { type: :string, description: "Words to match in content, summaries and notes" },
              kind:  { type: :string, enum: %w[concept preference stash followup], description: "Narrow to one kind" },
            },
            required:   [],
          },
        },
        {
          type:        :function,
          name:        "read_conversation",
          strict:      false,
          description: "Read further back in this conversation than the stretch you were given. " \
                       "Use when something refers to an exchange you can't see, rather than " \
                       "guessing what it meant. Answers with ids and times, and you can call it " \
                       "again and again - pass `before` the oldest id you got to keep going back " \
                       "until you have what you need or reach the start.",
          parameters:  {
            type:       :object,
            properties: {
              query:  { type: :string, description: "Words to find. Omit for simply the messages before the stretch." },
              before: { type: :integer, description: "Only messages older than this id" },
            },
            required:   [],
          },
        },
        {
          type:        :function,
          name:        "write_memory",
          strict:      false,
          description: "Hold something new. Only for something not already held - search first.",
          parameters:  {
            type:       :object,
            properties: {
              kind:          { type: :string, enum: %w[concept preference followup] },
              content:       { type: :string, description: MEMORY_CONTENT },
              summary:       { type: :string, description: "Three to six words" },
              severity:      { type: :integer, description: "0-100" },
              tags:          { type: :array, items: { type: :string } },
              check_in_days: { type: :integer, description: "Days until this is worth asking about. Omit for none." },
              relevant_days: { type: :integer, description: "Days until this becomes live at all. Omit for now." },
              expires_days:  { type: :integer, description: "Days until it stops being true. Omit for a lasting fact." },
            },
            required:   %w[kind content],
          },
        },
        {
          type:        :function,
          name:        "revise_memory",
          strict:      false,
          description: "Rewrite a row that is already held: a fact said better, one that only " \
                       "made sense beside another, one that has drifted. The wording it replaces " \
                       "is kept on the row's thread.",
          parameters:  {
            type:       :object,
            properties: {
              id:       { type: :integer },
              content:  { type: :string, description: "The whole row, rewritten. #{MEMORY_CONTENT_DATES}" },
              summary:  { type: :string },
              tags:     { type: :array, items: { type: :string } },
              severity: { type: :integer },
              note:     { type: :string, description: "Why, one sentence" },
            },
            required:   %w[id content],
          },
        },
        {
          type:        :function,
          name:        "close_memory",
          strict:      false,
          description: "Retire a row. `done` for something that happened or was resolved, " \
                       "`dropped` for something that stopped being worth holding - including " \
                       "the redundant half of two rows saying one thing. Not for anything on " \
                       "their stash pile - that is theirs to close. `revise_memory` is what a " \
                       "pile row takes.",
          parameters:  {
            type:       :object,
            properties: {
              id:     { type: :integer },
              status: { type: :string, enum: %w[done dropped] },
              note:   { type: :string, description: "Why, one sentence" },
            },
            required:   %w[id status],
          },
        },
        {
          type:        :function,
          name:        "set_check_in",
          strict:      false,
          description: "Arm, move or clear when a follow-up is worth asking about. Pass no days " \
                       "to stop asking.",
          parameters:  {
            type:       :object,
            properties: {
              id:   { type: :integer },
              days: { type: :integer, description: "Days from now. Omit to clear." },
              note: { type: :string },
            },
            required:   %w[id],
          },
        },
      ].freeze

      def self.schemas = SCHEMAS

      # Runs one call and answers the model. Every answer is a plain sentence
      # rather than a payload: this model's whole job is judgement about prose,
      # and a row it just wrote reads back more usefully as words.
      def call(name, args)
        args = args.is_a?(Hash) ? args.stringify_keys : {}

        case name.to_s
        when "search_memories"   then search_memories(args)
        when "read_conversation" then read_conversation(args)
        when "write_memory"      then write_memory(args)
        when "revise_memory"     then revise_memory(args)
        when "close_memory"      then close_memory(args)
        when "set_check_in"      then set_check_in(args)
        else "no such tool"
        end
      rescue StandardError => e
        Rails.logger.warn("[Buddy::Compile::Tools] #{name} failed: #{e.class}: #{e.message}")
        "that failed: #{e.message}"
      end

      LIMIT = 25

      def search_memories(args)
        scope = BuddyMemory.where(user: @user).unexpired
        scope = scope.where(kind: args["kind"]) if BuddyMemory.kinds.key?(args["kind"].to_s)
        scope = Buddy::MemorySearch.matching(scope, args["query"]) if args["query"].to_s.strip.present?
        rows  = scope.for_recall.limit(LIMIT).to_a
        return "nothing held matching that" if rows.empty?

        rows.map { |m| line(m) }.join("\n")
      end

      def line(memory)
        bits = ["##{memory.id}", "[#{memory.kind}]"]
        bits << "sev #{memory.severity}" if memory.severity.to_i.positive?
        bits << memory.status unless memory.status_active?
        bits << memory.content.to_s.squish.truncate(220)
        bits << "(tags: #{memory.tag_list.join(", ")})" if memory.tag_list.any?
        "- #{bits.join(" ")}"
      end

      # Older than the stretch, not a second copy of it: the stretch is already
      # in front of the model, and handing it back doubles the prompt for
      # nothing.
      def read_conversation(args)
        oldest = args["before"].presence || @messages.first&.id
        scope  = @conversation.byte_messages.order(created_at: :desc)
        scope  = scope.where(byte_messages: { id: ...oldest }) if oldest
        words  = args["query"].to_s.split(/\s+/).compact_blank
        scope  = words.reduce(scope) { |acc, word|
          acc.where("byte_messages.body ILIKE ?", "%#{Buddy::MemorySearch.sanitize_like(word)}%")
        }

        rows = scope.limit(LIMIT).to_a.reject { |m| Buddy::Compile.skip?(m) }.reverse
        return "nothing further back - that is the start of the thread" if rows.empty?

        name = @conversation.buddy_name
        zone = Buddy::Day.zone(@user)
        # Ids and times on every line, because without them this can only ever
        # be called once: the model has nothing to pass as `before` and no way
        # to tell how old what it got is.
        lines = rows.map { |m|
          who   = m.direction == "outbound" ? "Them" : name
          stamp = m.created_at.in_time_zone(zone).strftime("%a %-d %b, %-l:%M%P")
          "##{m.id} [#{stamp}] #{who}: #{m.body.to_s.squish.truncate(300)}"
        }
        "#{lines.join("\n")}\n\n(call again with before: #{rows.first.id} for what came before this)"
      end

      # The three kinds this pass may write. `stash` is deliberately absent, and
      # always has been - the schema above has never offered it. What was
      # missing is the enforcement: `BuddyMemory.kinds` knows `stash`, so the
      # fallback below waved it through, and rows 91, 97 and 99 all reached the
      # person's pile that way inside two hours. The pile grows when THEY put
      # something on it (`stash_idea`, or the armed latch), in front of them.
      WRITABLE_KINDS = %w[concept preference followup].freeze

      def write_memory(args)
        content = args["content"].to_s.strip
        kind    = args["kind"].to_s
        return "nothing to write" if content.empty?

        if kind == "stash"
          return "the pile is theirs to add to, so that one isn't yours to write - if it is " \
                 "something TRUE ABOUT THEM rather than a job they mean to get to, hold it as " \
                 "a concept or a preference instead."
        end

        return "already held, near enough - revise it instead" if Buddy::Compile.duplicate?(@user, content)

        memory = BuddyMemory.new(
          user:           @user,
          source_message: Buddy::Compile.origin_message(@messages, content),
          relevant_at:    Buddy::Compile.days_from(args["relevant_days"], @now),
          kind:           WRITABLE_KINDS.include?(kind) ? kind : "concept",
          content:        content.first(BuddyMemory::MAX_CONTENT),
          summary:        args["summary"].to_s.strip.presence&.first(BuddyMemory::MAX_SUMMARY),
          severity:       Buddy::Compile.clamp_severity(args["severity"]),
          expires_at:     Buddy::Compile.days_from(args["expires_days"], @now),
          last_used_at:   @now,
        )
        memory.tag_list = args["tags"] if args["tags"].present?
        arm(memory, args["check_in_days"])
        memory.save!
        @written << memory

        "held as ##{memory.id}"
      end

      def revise_memory(args)
        memory  = find!(args)
        content = args["content"].to_s.strip
        return "nothing to write" if content.empty?
        return "unchanged" if content == memory.content

        # The row is what everything reads, so the version it replaced has to
        # survive somewhere or a bad rewrite is invisible.
        memory.notes.create!(body: "Was: #{memory.content.to_s.truncate(400)}", source: :companion)
        memory.notes.create!(body: args["note"].to_s.strip, source: :companion) if args["note"].to_s.strip.present?
        memory.content  = content.first(BuddyMemory::MAX_CONTENT)
        memory.summary  = args["summary"].to_s.strip.presence&.first(BuddyMemory::MAX_SUMMARY) if args.key?("summary")
        memory.severity = Buddy::Compile.clamp_severity(args["severity"]) if args.key?("severity")
        memory.tag_list = args["tags"] if args["tags"].present?
        memory.save!
        @touched << memory

        "##{memory.id} rewritten"
      end

      # THE PILE IS NOT YOURS TO CLEAR.
      #
      # `kind: stash` is the person's own list of things they mean to get to,
      # and it changes when THEY say so - `finish_idea`, `drop_idea`,
      # `move_idea`, each of them a tool called in front of them, each leaving a
      # card they can undo. A compile pass reading a transcript half an hour
      # later is not that, and it leaves no card and no receipt.
      #
      # Memory 95 ("Alexa fan and blind commands") went `dropped` at 12:54 with
      # nothing in the thread at 12:54 about it and no `byte_actions` row. The
      # person had asked 34 minutes earlier to ADD to that entry - the opposite
      # of finishing with it - and ended the day with it gone off the pile and
      # nothing anywhere saying it had happened.
      #
      # Buddy::SideEffects#apply_forget already draws this exact line for the
      # same reason, in almost the same words.
      def close_memory(args)
        memory = find!(args)
        if memory.kind_stash?
          return "##{memory.id} is on their pile, so it is theirs to close - leave it active. " \
                 "`revise_memory` if this stretch added to it or said it better."
        end

        status = args["status"].to_s == "done" ? :done : :dropped
        memory.notes.create!(body: args["note"].to_s.strip, source: :companion) if args["note"].to_s.strip.present?
        memory.update!(status: status, check_in_at: nil)
        @touched << memory

        "##{memory.id} #{status}"
      end

      # rubocop:disable Naming/AccessorMethodName -- these are tool NAMES the model
      # calls; the dispatch reads better matching the schema than translating
      # around a cop.
      def set_check_in(args)
        memory = find!(args)
        memory.notes.create!(body: args["note"].to_s.strip, source: :companion) if args["note"].to_s.strip.present?
        arm(memory, args["days"])
        memory.save!
        @touched << memory

        memory.check_in_at ? "##{memory.id} due #{memory.check_in_at.to_date}" : "##{memory.id} not asking again"
      end

      # rubocop:enable Naming/AccessorMethodName

      def find!(args)
        memory = BuddyMemory.where(user: @user).find_by(id: args["id"])
        raise "no memory ##{args["id"]}" if memory.nil?

        memory
      end

      # Asking about something is the expensive act here — it interrupts them —
      # so a check-in on trivia is refused however plainly it was asked for, and
      # never lands before the thing it is about is live.
      def arm(memory, days)
        return memory.check_in_at = nil if days.blank?

        memory.kind = :followup if memory.kind_concept?
        return memory.check_in_at = nil if memory.severity.to_i < BuddyMemory::CHECK_IN_FLOOR

        base = [Buddy::Compile.days_from(days, @now), memory.relevant_at].compact.max || @now
        memory.check_in_at = Buddy::CheckIns.place(base, user: @user, now: @now)
      end
    end
  end
end
