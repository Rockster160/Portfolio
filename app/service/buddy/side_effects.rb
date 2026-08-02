module Buddy
  # The immediate, non-checkbox actions Buddy can take. Unlike proposals these
  # fire the moment the model calls them — no user confirmation — so the
  # vocabulary is deliberately small and non-destructive.
  #
  # These live OUTSIDE the Buddy::Tools registry on purpose: that registry is
  # the proposal/checkbox surface (ProposalBuilder iterates it), and none of
  # these produce a row. They are exposed to the model as their own function
  # schemas via `function_schemas` below.
  #
  # Adding a new side effect:
  #   1. Add a SCHEMAS entry (name, description, args).
  #   2. Add a `when :name` branch in `call`.
  #   3. Teach it in the persona's Rules of the House if it needs nuance.
  module SideEffects
    module_function

    # Function names the model can call. Kept as a flat list so Turn can ask
    # `SideEffects.handles?(name)` to route a tool call without a registry hit.
    NAMES = %i[set_mood add_note remember forget sort_stash].freeze

    def handles?(name)
      NAMES.include?(name.to_sym)
    end

    # Dispatch one structured tool call. Failures are logged and swallowed: a
    # bad side effect must never cost the person the rest of a good reply.
    def call(conversation, name, args)
      user = conversation.user
      args = (args || {}).transform_keys(&:to_sym)

      case name.to_sym
      when :set_mood   then apply_mood(conversation, args[:expression])
      when :add_note   then apply_note(conversation, args[:fact])
      when :remember   then apply_remember(user, args[:fact], args[:expires_in])
      when :forget     then apply_forget(user, args[:match])
      when :sort_stash then Buddy::Stash.apply_sort(user, args)
      end
      true
    rescue StandardError => e
      Rails.logger.warn("[Buddy::SideEffects] #{name} failed: #{e.class}: #{e.message}")
      false
    end

    # Flat Responses-API function tools, same shape Buddy::Tools produces. All
    # of these are strict, so optional args are nullable and every property is
    # listed in `required`.
    #
    # `theme` scopes set_mood's enum to the faces that theme actually has, which
    # makes an unrenderable face structurally impossible rather than something
    # apply_mood has to detect and discard.
    def function_schemas(theme: :byte)
      [
        schema(
          :set_mood,
          "Set the pet's face to match the expression YOU are wearing as you deliver THIS reply - " \
          "your own tone, not a readout of the user's mood. Call this whenever the face should " \
          "change from its current value. At most once per reply. Silent: never mention it in prose.",
          {
            expression: {
              type:        :enum,
              required:    true,
              values:      Buddy::Faces.selectable(theme),
              description: "The face you're wearing as you say this",
            },
          },
        ),
        schema(
          :add_note,
          "Record a note about THIS conversation only (how the person wants this thread to work, " \
          "or a detail that matters here but not globally). Scoped to this thread. Silent.",
          { fact: { type: :string, required: true, description: "One short line" } },
        ),
        schema(
          :remember,
          "Write a durable fact about the person, carried into every future conversation. " \
          "Durable facts only - preferences, names, routines, ongoing projects. Not conversational " \
          "trivia, not moods, not counts. One fact per call. Silent.",
          {
            fact:       { type: :string, required: true, description: "A statement future-you can act on" },
            expires_in: {
              type:        :string,
              required:    false,
              description: "Set for a fact that's only true for a while, so it self-clears: " \
                           "\"today\", \"tomorrow\", or \"N days/weeks/months\". Null means it never expires",
            },
          },
        ),
        schema(
          :forget,
          "Prune a memory when the person says it's wrong or asks you to drop it. Silent.",
          { match: { type: :string, required: true, description: "Short substring of the memory, or its numeric id" } },
        ),
        schema(
          :sort_stash,
          "File or refine a brain-dumped idea. Pass category when first sorting it; pass summary " \
          "alone to sharpen an existing note as the idea gets clearer. Silent.",
          {
            id:       { type: :integer, required: true,  description: "Idea id from stashed_ideas" },
            category: { type: :enum,    required: false, values: %i[me home work], description: "Which bucket it belongs in" },
            summary:  { type: :string,  required: false, description: "Short summary of the idea" },
          },
        ),
      ]
    end

    # Reuses Buddy::Tools' property builder so side-effect schemas and proposal
    # schemas can never drift in how they express types, enums, or nullability.
    def schema(name, description, args)
      Buddy::Tools.function_schema({
        name:        name,
        description: description,
        args:        args.transform_values { |v| v.transform_keys(&:to_sym) },
      })
    end

    # `[[mood: <one of the expressions>]]` — shifts this thread's pet face
    # and broadcasts. The pet expression IS the mood state; the field
    # (byte_conversations.buddy_expression) persists across turns and rides in
    # every context block, so no shadow log or event trail is needed.
    def apply_mood(conversation, body)
      expression = body.to_s.downcase.strip
      theme = conversation.buddy_theme
      # `selectable?` not `valid?` — a delivered mood may never be a
      # system/transitional face (e.g. `thinking`), even if the model emits
      # one off-list. Those would leave the pet resting on a non-mood face.
      valid = Buddy::Faces.selectable?(theme, expression)
      # Observability: mood markers are otherwise trail-less (stripped from the
      # body, set via update_column). This line is how we can actually answer
      # "is Buddy using expressions?" — grep prod for `[Buddy::mood]`.
      Rails.logger.info(
        "[Buddy::mood] user=#{conversation.user_id} conversation=#{conversation.id} " \
        "theme=#{theme} requested=#{expression.inspect} " \
        "valid=#{valid} current=#{conversation.buddy_expression.inspect}",
      )
      return unless valid
      return if conversation.buddy_expression == expression  # no-op if unchanged

      Buddy::ExpressionState.set(conversation, expression)
    end

    # `[[note: <fact>]]` — appends a line to this conversation's small notes
    # block (byte_conversations.buddy_memories). Per-conversation and
    # short-lived by nature ("keep this thread strictly work"); durable global
    # facts go through `[[remember:]]` instead. Fires silently.
    def apply_note(conversation, body)
      Buddy::ConversationNotes.append(conversation, body)
    end

    # Writes a durable BuddyMemory row. Bounded to 500 chars (matches the model
    # validation) so an accidental paragraph-length fact can't create a giant
    # row.
    #
    # `expires_in` is an optional duration phrase ("today", "2 weeks") for a
    # fact that's only true for a while, so it self-prunes. Nil means durable.
    # Reinforcement: if we already hold this fact (near-duplicate), bump it
    # instead of storing a copy, so re-mentions keep it fresh and high.
    def apply_remember(user, fact, expires_in=nil)
      fact = fact.to_s.strip
      return if fact.empty?

      ttl = parse_duration(expires_in, user)

      existing = find_similar_memory(user, fact)
      if existing
        existing.reinforce!
        existing.update_columns(expires_at: ttl, updated_at: Time.current) if ttl
        return
      end

      BuddyMemory.create!(
        user:         user,
        content:      fact.first(500),
        expires_at:   ttl,
        last_used_at: Time.current,
      )
    end

    # Duration phrase to an absolute expiry. Unparseable (or nil) is treated as
    # durable rather than guessed at — a fact that outlives its usefulness is a
    # smaller problem than one that vanishes early.
    # "today" and "tomorrow" end at the end of THEIR day. `Time.current` carries
    # the app-wide UTC zone, so `end_of_day` was 23:59 UTC — 5:59pm on a UTC-6
    # account, which quietly expired a fact meant to last the evening several
    # hours before the evening was over.
    def parse_duration(text, user=nil)
      t = text.to_s.strip.downcase
      return nil if t.empty?
      return end_of_local_day(user) if t == "today"
      return end_of_local_day(user, offset: 1) if t == "tomorrow"

      m = t.match(/\A(\d+)\s*(day|week|month|year|hour)s?\z/)
      return nil unless m

      Time.current + m[1].to_i.public_send("#{m[2]}s")
    rescue StandardError
      nil
    end

    # The end of their PERCEIVED day (3am, like everywhere else in Buddy) rather
    # than local midnight. Two reasons, and the second is the one that matters:
    # someone still up at 1am means the day they're in, not the one the calendar
    # rolled to an hour ago — and anchoring on midnight would have handed back
    # an expiry already in the past, so the fact would vanish on write.
    def end_of_local_day(user, offset: 0)
      return Time.current.end_of_day + offset.days if user.nil?

      Buddy::Day.range(user, date: Buddy::Day.today(user) + offset).last
    end

    # An active memory that's effectively the same fact - exact (normalized)
    # match, or one clearly contains the other. Conservative on purpose: only
    # obvious re-mentions reinforce; anything novel becomes its own row.
    def find_similar_memory(user, fact)
      norm = fact.to_s.downcase.gsub(/\s+/, " ").strip
      return nil if norm.length < 8

      BuddyMemory.where(user: user).active.find { |m|
        other = m.content.to_s.downcase.gsub(/\s+/, " ").strip
        other == norm || other.include?(norm) || norm.include?(other)
      }
    end

    # `[[forget: <substring or id>]]` — prunes matching memory rows. If
    # the body is a bare integer, deletes by id; otherwise deletes rows
    # whose content contains the substring (case-insensitive). Cap the
    # damage at 5 rows per marker so a stray "forget everything" can't
    # nuke the whole history.
    def apply_forget(user, body)
      needle = body.to_s.strip
      return if needle.empty?

      scope = user.buddy_memories rescue BuddyMemory.where(user: user)
      matches = if needle.match?(/\A\d+\z/)
        scope.where(id: needle.to_i)
      else
        scope.where("LOWER(content) LIKE ?", "%#{needle.downcase}%")
      end
      matches.order(created_at: :desc).limit(5).destroy_all
    end
  end
end
