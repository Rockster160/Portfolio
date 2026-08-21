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
  #   4. If it can CHANGE A RECORD, decide what evidence it leaves. "Silent"
  #      here means no prose and no checklist row — it was never meant to mean
  #      no trace. A mutation with no chip is invisible twice over: the person
  #      has nothing to point at, and Buddy has nothing to find in
  #      `recent_actions`, which the persona tells it to read as proof that
  #      something didn't happen. Post a Buddy::ActivityChip and report true
  #      from `call`, or you get prod 3332-3337, where a refile that really
  #      worked got talked out of having happened.
  module SideEffects
    module_function

    # Function names the model can call. Kept as a flat list so Turn can ask
    # `SideEffects.handles?(name)` to route a tool call without a registry hit.
    NAMES = %i[set_mood add_note remember forget sort_stash].freeze

    # The ones that change what is HELD about the person, as opposed to how one
    # thread behaves. A turn that fires any of these gets a small mark on the
    # reply — writing to somebody's memory is otherwise completely silent, and
    # the whole point of these being silent tools is that they don't interrupt
    # the sentence. Silent is not the same as invisible.
    MEMORY_MARKERS = %i[remember forget sort_stash].freeze

    def handles?(name)
      NAMES.include?(name.to_sym)
    end

    # Dispatch one structured tool call. Failures are logged and swallowed: a
    # bad side effect must never cost the person the rest of a good reply.
    #
    # Returns whether this call CHANGED SOMETHING IN THE WORLD, which is a
    # different question from whether it succeeded. Silent is not the same as
    # inconsequential — `sort_stash` refiles an idea — and a reply that says so
    # is telling the truth. Until this reported anything, the retraction guard
    # in Turn could see no evidence for such a claim and stood ready to erase a
    # true sentence as unbacked.
    #
    # Only `sort_stash` answers it so far, because only it can answer honestly:
    # it knows whether the row actually moved. The rest return false meaning
    # NOT REPORTED rather than nothing-happened, and `remember`/`forget`/
    # `add_note` would each need to distinguish a write from a no-op before
    # they could join in. Under-reporting is the safe direction: it leaves
    # today's behaviour exactly as it was, where over-reporting would hand a
    # fabricated claim a free pass.
    def call(conversation, name, args)
      user = conversation.user
      args = (args || {}).transform_keys(&:to_sym)

      case name.to_sym
      when :sort_stash
        Buddy::Stash.apply_sort(user, args, conversation: conversation)
      else
        case name.to_sym
        when :set_mood then apply_mood(conversation, args[:expression])
        when :add_note then apply_note(conversation, args[:fact])
        when :remember then apply_remember(user, args[:fact], args[:expires_in])
        when :forget   then apply_forget(user, args[:match])
        end
        false
      end
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
          "File a JUST-DUMPED idea for the first time, or refine one. Pass category only when the " \
          "idea has no bucket yet; refiling one that is ALREADY in a bucket because they told you " \
          "it belongs somewhere else is `move_idea`, not this. Pass summary alone to sharpen an " \
          "existing note as the idea gets clearer. Pass drop when what they dumped wasn't a " \
          "thought to hold at all and you have ALREADY put it where it belongs - on a list, or as " \
          "a reminder - so it doesn't sit in two places. Silent.",
          {
            id:       { type: :integer, required: true,  description: "Idea id from stashed_ideas" },
            category: { type: :enum,    required: false, values: %i[me home work], description: "Which bucket it belongs in" },
            summary:  { type: :string,  required: false, description: "Short summary of the idea" },
            drop:     { type: :boolean, required: false, description: "True once you've filed it somewhere it can actually be acted on" },
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

      ttl = parse_duration(expires_in, user) || implied_ttl(fact, user)

      existing = find_similar_memory(user, fact)
      if existing
        existing.reinforce!
        attrs = {}
        # A re-mention that SPELLS OUT the one we hold replaces it. "Ryker plays
        # soccer" reinforced by "Ryker plays soccer Tuesdays at 4" should leave
        # us holding the useful one, not the stub plus a bumped counter.
        attrs[:content]    = fact.first(500) if elaborates?(fact, existing.content)
        attrs[:expires_at] = ttl if ttl
        existing.update_columns(attrs.merge(updated_at: Time.current)) if attrs.any?
        return
      end

      # `preference`, which is the kind that still ships inline in every prompt.
      #
      # An explicit `remember` is the model being TOLD to hold something — "10p
      # means ten pebbles", "drinks oat milk lattes" — and those have to be
      # present without being looked up, because the moment one applies is the
      # moment nobody thinks to search for it. Keeping this path inline is also
      # what makes the merge a no-op for existing behavior: everything that
      # reached the prompt before still reaches it.
      #
      # The widened capture (episodes, worries, things worth revisiting) does
      # NOT come through here. Buddy::Compile writes those in the background as
      # `concept` and `followup`, tagged, and they're reached by search.
      BuddyMemory.create!(
        user:         user,
        kind:         :preference,
        content:      fact.first(BuddyMemory::MAX_CONTENT),
        expires_at:   ttl,
        last_used_at: Time.current,
      )
    end

    # A fact that says "today" in it is about today, whatever expiry the model
    # forgot to pass. The prompt has always asked for `expires_in` on short-term
    # facts and it gets skipped anyway, which is how "doesn't want to do
    # anything after the ceremony ends at 8:30 PM today, wants everything
    # scheduled between 10 AM and shower time today" became a permanent fact
    # about someone — injected into every future turn, and already wrong by the
    # evening. A same-day word is unambiguous enough to act on without the model
    # agreeing, and the cost of being wrong is one re-mention.
    TODAY_BOUND_RX = /\b(?:today|tonight|this morning|this afternoon|this evening|right now)\b/i

    def implied_ttl(fact, user)
      return nil unless fact.match?(TODAY_BOUND_RX)

      end_of_local_day(user)
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

    # An active memory that's effectively the same fact. Three ways to be the
    # same: identical once normalized, one string containing the other, or the
    # two carrying essentially the same significant words.
    #
    # That third test is what makes reinforcement work on a person who thinks
    # out loud. Substring matching only ever fires on a near-verbatim repeat,
    # and nobody repeats themselves verbatim - "Ryker has soccer Tuesdays" and
    # "Roo's soccer is on a Tuesday" are one fact said twice, and under
    # containment alone they became two rows, each at priority zero, competing
    # for the same recall slots. The fact got said MORE and remembered LESS.
    def find_similar_memory(user, fact)
      return nil if normalize_fact(fact).length < 8

      # Facts only. Since the merge these share a table with the stash, and a
      # remembered fact must never dedupe against a thought the person handed
      # over to hold — reinforcing a stashed idea because it shares six words
      # with a preference would quietly rewrite the idea's text.
      BuddyMemory.where(user: user).where(kind: [:preference, :concept]).active.find { |m|
        same_fact?(fact, m.content)
      }
    end

    # Two texts saying the same thing: identical once normalized, one containing
    # the other, or the same significant words.
    #
    # Public because Buddy::Compile needs to ask the same question. It had its
    # own test that compared normalized strings for equality, so one fact
    # reworded between the inline write and the compile pass half an hour later
    # became two rows — "a good time for Eve to water outside" and "a good time
    # for her to water outside" (memories 79 and 83), and "told to check the
    # print at 3:16" against the same sentence with the follow-up appended
    # (76 and 80). Which scope to search is the caller's to decide; this only
    # answers whether two pieces of text are the same fact.
    def same_fact?(left, right)
      a = normalize_fact(left)
      b = normalize_fact(right)
      return true if a == b || a.include?(b) || b.include?(a)

      overlaps?(significant_words(a), significant_words(b))
    end

    def normalize_fact(text)
      text.to_s.downcase.gsub(/\s+/, " ").strip
    end

    # The new wording says everything the old one did and then some. Strict
    # containment only - a reworded fact of similar length is a re-mention, not
    # an upgrade, and swapping it in would churn the memory for nothing.
    def elaborates?(fact, held)
      fresh = normalize_fact(fact)
      prior = normalize_fact(held)
      fresh.length > prior.length && fresh.include?(prior)
    end

    # Words that carry the fact. Stripped of punctuation and of the connective
    # tissue two phrasings of one fact won't share anyway.
    STOP_WORDS = <<~WORDS.split.to_set.freeze
      a an and are as at be been but by does do for from get gets going had has have her
      him his how i if in into is it its like me my of on or our she that the their them
      they this to too up us was we were what when where which who will with you your
    WORDS

    def significant_words(norm)
      norm.scan(/[a-z0-9']+/).filter_map { |raw|
        word = stem(raw)
        word if word.length >= 3 && STOP_WORDS.exclude?(word) && STOP_WORDS.exclude?(raw)
      }.to_set
    end

    # Enough of a stemmer to survive the two ways one fact gets typed twice:
    # a possessive ("Ryker's soccer" vs "Ryker has soccer") and a plural
    # ("Tuesdays" vs "Tuesday"). Lossy, and knowingly so - it's applied to both
    # sides of every comparison, so a mangled stem still matches its own twin.
    # `ss` is left alone or "glass" and "glas" would be the same word.
    def stem(word)
      base = word.delete("'")
      base.length > 3 && base.end_with?("s") && !base.end_with?("ss") ? base[0..-2] : base
    end

    # Same fact if nearly all of the shorter one's meaningful words appear in
    # the longer. Measured against the SHORTER side so a terse re-mention still
    # matches the fuller original it's re-stating.
    #
    # 0.8 with a floor of two shared words: high enough that "Ryker plays
    # soccer" and "Ryker plays piano" stay separate facts, low enough to
    # absorb a rewording. When it does get it wrong the cost is asymmetric and
    # small - a reinforced near-miss keeps a true fact near the top of recall,
    # where a missed match silently buries one.
    OVERLAP_RATIO = 0.8
    MIN_SHARED    = 2

    def overlaps?(left, right)
      smaller = [left.size, right.size].min
      return false if smaller < MIN_SHARED

      shared = (left & right).size
      shared >= MIN_SHARED && shared >= (smaller * OVERLAP_RATIO)
    end

    # `[[forget: <substring or id>]]` — prunes matching memory rows. If
    # the body is a bare integer, deletes by id; otherwise deletes rows
    # whose content contains the substring (case-insensitive). Cap the
    # damage at 5 rows per marker so a stray "forget everything" can't
    # nuke the whole history.
    def apply_forget(user, body)
      needle = body.to_s.strip
      return if needle.empty?

      # Facts only, for the same reason find_similar_memory is: `drop_idea` is
      # how a held thought gets let go, and a substring "forget" that reached
      # the pile would delete something the person is still counting on.
      scope = BuddyMemory.where(user: user).where(kind: [:preference, :concept])
      matches = if needle.match?(/\A\d+\z/)
        scope.where(id: needle.to_i)
      else
        scope.where("LOWER(content) LIKE ?", "%#{needle.downcase}%")
      end
      matches.order(created_at: :desc).limit(5).destroy_all
    end
  end
end
