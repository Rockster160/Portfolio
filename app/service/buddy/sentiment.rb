module Buddy
  # What kind of moment this conversation is in, as four numbers.
  #
  # **This is the whole mood system.** The pet's face is chosen here, on every
  # buddy turn, by reading the conversation and taking the nearest face to what
  # was read (Buddy::Faces::PROFILES). One small model call, off the turn.
  #
  # Two things used to do this job and both are gone. The model led its reply
  # with a `[[mood:]]` marker that Turn parsed off the front, or called a
  # `set_mood` tool - and when it did neither, which was often, a `.sample` from
  # a three-item "pleased" list fired the moment a tool succeeded. Prod 5759 is
  # what that bought: the reply said "*sad*" about a rejection from the job he'd
  # been most excited about, and the pet put its glasses on, because the toss
  # came up `nerd`.
  #
  # Asking the model to also be its own mood ring cost 4kb of face vocabulary in
  # every prompt, a tool call it spent a round on, a regex on the front of every
  # reply, and it still missed. Reading the conversation afterwards is a smaller
  # question asked of a smaller prompt, and it is asked every time.
  #
  # ---- why a model call rather than a lexicon ------------------------------
  #
  # Because the thing being measured is what a stretch of conversation MEANS,
  # and every word-list version of this gets "Corporate Tools rejected me" and
  # "I rejected the null hypothesis" the same. It is also the cheapest call in
  # the app by a distance - eight trimmed messages and four numbers back, next
  # to the ~80k-token turns beside it - and it is asynchronous, so nothing
  # waits on it. The reply has already landed by the time this runs; the face
  # arriving a moment later is how an ambient thing should arrive anyway.
  module Sentiment
    module_function

    MODEL = "gpt-5.4-mini".freeze

    # Enough to have a shape rather than a single sentence. A run of one-word
    # logging messages says almost nothing on its own, and the turn that
    # actually set the tone is usually a few back.
    WINDOW = 8

    # A long message contributes its opening, not its whole self: the mood of a
    # paragraph is in how it starts, and carrying all of it would make the
    # cheapest call in the app one of the more expensive ones.
    MAX_CHARS = 320

    # What the ACTION does to the reading. A tool call is its own small event
    # with its own place on these axes, and the answer is the room BLENDED
    # toward it - not the room plus a constant.
    #
    # The difference matters and cost a rewrite to notice. As deltas, a failed
    # call added to `weight`, so a miss during an already-heavy conversation
    # pushed the reading past `sad` and into `crying`: the pet wept because a
    # camera didn't return a frame. A blend pulls toward the event instead, so
    # a failure lands where a failure belongs however heavy the room is.
    #
    # ACTED is where "I did the thing for you" sits: warm, light, low stakes.
    # Doing something for someone is the most expressive moment there is and a
    # pet that just did it and looks blank is the flat-faced machine this whole
    # system exists to avoid.
    #
    # **It does not touch `weight` AT ALL, and that is the load-bearing zero.**
    # Having successfully written a row does not change how much is at stake
    # for the person. Pulling weight down toward "this was a small favour" is
    # what put `surprised` on a rejection - the reading slid off `sad` into the
    # mid-weight faces because the errand was small, which is an opinion about
    # the errand being applied to their news. Weak on the rest for the same
    # reason: it should colour a flat moment, never argue with a heavy one.
    ACTED_POINT = { warmth: 0.85, play: 0.45, weight: 0.20, strain: 0.05 }.freeze
    ACTED_PULL  = { warmth: 0.25, play: 0.25, weight: 0.0, strain: 0.3 }.freeze

    # MISSED is "that didn't work": mildly bad, a bit frustrating, and NOT a
    # big deal. Here `weight` DOES move, and toward the middle, because that is
    # the honest size of a failed tool call - it is also what keeps a miss
    # during a heavy conversation out of the grieving faces. As a delta this
    # ADDED to weight and the pet wept because a camera didn't return a frame.
    #
    # Strong on every axis, because a failure is the loudest thing that
    # happened in the turn. Prod 4594 was a gleeful laugh over "I couldn't get
    # a frame from the backyard camera".
    MISSED_POINT = { warmth: 0.25, play: 0.15, weight: 0.40, strain: 0.65 }.freeze
    MISSED_PULL  = { warmth: 0.6, play: 0.5, weight: 0.5, strain: 0.7 }.freeze

    PROMPT = <<~TXT.freeze
      You read the mood of a conversation and answer with four numbers. Nothing else.

      Each is 0.0 to 1.0, one decimal place:

        warmth - how good this moment is FOR THEM. 0 is bleak, 0.5 is flat or
                 ordinary, 1 is delighted. News they are receiving counts:
                 being turned down for something they wanted is low warmth even
                 when they are calm about it.
        play   - how light it is. 0 is dead earnest, 0.5 is ordinary chat, 1 is
                 mucking about, jokes, silliness.
        weight - how much is at stake for them. 0 is trivial admin (a list, a
                 timer, a light on). 1 is something that genuinely matters -
                 work, health, money, family, a loss.
        strain - how much friction is in the room. 0 is none. 1 is fed up,
                 snapping, repeating themselves because they weren't heard.

      Read the whole stretch but weight the END of it: the last thing they said
      is the moment being described. Judge the PERSON's state, not the
      companion's - the companion's lines are context for what they were
      responding to.

      warmth and weight are independent. A calm sentence about a hard thing is
      low warmth and high weight. An excited sentence about nothing much is high
      warmth and low weight.

      Answer with only this object, no prose, no code fence:
      {"warmth":0.0,"play":0.0,"weight":0.0,"strain":0.0}
    TXT

    # nil means "couldn't read it" and is a real answer - the caller falls back
    # rather than inventing a mood off a failed call.
    def read(conversation)
      transcript = transcript_for(conversation)
      return nil if transcript.blank?

      result = ::Buddy::GPT::Client.new(model: MODEL).stream(
        instructions: PROMPT,
        input:        [{ role: :user, content: [{ type: :input_text, text: transcript }] }],
      )
      record_usage(result, conversation)
      return nil unless result[:ok]

      parse(result[:text])
    rescue StandardError => e
      Rails.logger.warn("[Buddy::Sentiment] read failed: #{e.class}: #{e.message}")
      nil
    end

    # How much closer the new face has to be before the pet actually changes it.
    #
    # This runs every turn now, so without a margin the face twitches: two
    # readings a sentence apart land 0.05 either side of a boundary and the pet
    # flips between two nearly-identical expressions for no reason anybody
    # watching could name. A face that changes unprompted reads as a glitch -
    # that is the lesson of the old cycler job, and running on every turn is
    # exactly the condition that brought it back.
    #
    # Compared against where the CURRENT face sits rather than against the last
    # reading, because the current face is the thing on screen and the only
    # thing a change is visible against.
    STICKY_MARGIN = 0.02

    def later(conversation, acted: false, landed: true)
      return unless readable?(conversation)

      ::BuddySentimentWorker.perform_async(conversation.id, acted, landed)
    end

    # Runs in the worker, on every buddy turn.
    def settle!(conversation, acted: false, landed: true)
      return unless readable?(conversation)

      reading = read(conversation)
      # Nothing came back. The pet keeps the face it has, which is the honest
      # answer: the last reading is the most recent thing anybody knew.
      return if reading.nil?

      reading = blended(reading, landed) if acted
      skip    = skipped(acted, landed)
      face    = ::Buddy::Faces.nearest(conversation.buddy_theme, reading, skip: skip)
      return if face.nil? || !worth_changing?(conversation, face, reading, skip)

      ::Buddy::ExpressionState.set(conversation, face)
    end

    def readable?(conversation)
      return false if conversation.nil?

      conversation.mode.to_s == "buddy"
    end

    # A different face, and enough better to be worth the change.
    def worth_changing?(conversation, face, reading, skip)
      current = conversation.buddy_expression.to_s
      return false if current == face.to_s

      # Nothing to hold on to: no face, or one with no profile to measure.
      return true if current.blank?
      return true if ::Buddy::Faces.profile(current).nil?
      # `skip` is a face the pet must NOT be wearing, so holding on to it is not
      # one of the options and the margin doesn't get a vote. Without this the
      # two rules cancelled: "an action never leaves the pet resting" picked
      # `neutral_blush` over `neutral`, and the margin - correctly, on the
      # numbers alone - said the change wasn't worth making, so the pet rested
      # after every small favour exactly as before.
      return true if skip.map(&:to_s).include?(current)

      here  = ::Buddy::Faces.distance(::Buddy::Faces.profile(current), reading)
      there = ::Buddy::Faces.distance(::Buddy::Faces.profile(face), reading)
      here - there > STICKY_MARGIN
    end

    # ---- the transcript -----------------------------------------------------

    # Both sides. `readable` is inbound-only because it answers "what is there
    # left to look at", and what the PERSON said is the larger half of what
    # this is trying to measure.
    def transcript_for(conversation)
      rows = conversation.byte_messages.where(
        state: ::ByteMessage::SETTLED_STATES,
      ).where(
        "byte_messages.metadata ->> 'kind' IS NULL OR byte_messages.metadata ->> 'kind' NOT IN (?)",
        ::ByteMessage::SILENT_KINDS,
      ).where(
        "byte_messages.metadata ->> 'hidden' IS DISTINCT FROM 'true'",
      ).recent.limit(WINDOW).to_a.reverse

      rows.filter_map { |message| line_for(message) }.join("\n")
    end

    def line_for(message)
      body = message.body.to_s.gsub(/\[\[[^\]]*\]\]/, "").squish
      return nil if body.blank?

      who = message.direction.to_s == "outbound" ? "Them" : "Companion"
      "#{who}: #{body.truncate(MAX_CHARS)}"
    end

    # ---- the answer ---------------------------------------------------------

    def parse(text)
      json = text.to_s[/\{.*\}/m]
      return nil if json.nil?

      parsed = ::JSON.parse(json)
      reading = ::Buddy::Faces::AXES.index_with { |axis| clamp(parsed[axis.to_s]) }
      # A reply that carried none of the four is a reply about something else.
      return nil if ::Buddy::Faces::AXES.none? { |axis| parsed.key?(axis.to_s) }

      reading
    rescue ::JSON::ParserError
      nil
    end

    # A turn that DID something for them and managed it never leaves the pet on
    # its resting face - that was the whole point of the reaction this replaced,
    # and it is a rule about the pet rather than a reading of the room, so it
    # belongs here and not in the numbers. Nothing is skipped on a turn that
    # only talked: a flat conversation is allowed to look flat.
    def skipped(acted, landed)
      acted && landed ? [::Buddy::Faces.default] : []
    end

    def blended(reading, landed)
      point, pull = landed ? [ACTED_POINT, ACTED_PULL] : [MISSED_POINT, MISSED_PULL]

      reading.to_h { |axis, value|
        toward = pull[axis].to_f
        [axis, clamp((value * (1 - toward)) + (point[axis].to_f * toward))]
      }
    end

    def clamp(value)
      value.to_f.clamp(0.0, 1.0)
    end

    def record_usage(result, conversation)
      ::BuddyUsage.record!(result, user: conversation.user, kind: :sentiment, conversation: conversation)
    rescue StandardError => e
      Rails.logger.warn("[Buddy::Sentiment] usage record failed: #{e.class}: #{e.message}")
    end
  end
end
