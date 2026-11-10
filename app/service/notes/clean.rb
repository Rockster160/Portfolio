module Notes
  # A readable version of a note he typed, kept beside the one he typed.
  #
  # The notes taken during a call are shorthand, and they are shorthand on
  # purpose: he is listening, not writing. "WWhen given prompt, do NOT just
  # jump in", "MOST SIMPLISITIC DESIGN POSSIBLE", a line of indented fragments
  # under a heading that is itself a fragment. Read back a week later that
  # costs a pass of the eye per line to work out what it meant.
  #
  # THIS IS THE OPPOSITE PROBLEM TO `Transcripts::Clean`, and the guards are
  # upside down because of it. There, the words were SPOKEN and the whole risk
  # was a model improving them into an answer he never gave - so the cleaned
  # turn has to stay nearly as long and keep nearly all of his words. Here the
  # words were typed in a hurry and the job genuinely is to rewrite them:
  # finish the fragments, fix the typing, group what belongs together. A
  # cleaned note is ALLOWED to be longer than what it came from, and usually
  # is.
  #
  # So the risk moves. What can go wrong here is INVENTION - a model handed
  # four fragments about an interview writing a fifth point that sounds right,
  # or turning "2 prong" into a confident paragraph about two prongs it made
  # up. The guards below are shaped at that: every number survives, every link
  # survives, and a version that grew past `MOST_OF_IT` is refused on the
  # grounds that notes do not double in length by being made readable.
  #
  # WHAT HE TYPED IS NEVER TOUCHED. `body` stays exactly as he wrote it and
  # the readable one goes beside it in `clean_body`, so the page can show
  # either and a cleaning that went wrong costs nothing. It is also the one
  # he can EDIT: the model's version is a draft of his own note, and the
  # person who was in the room is the authority on what was said in it.
  module Clean
    module_function

    MODEL = "gpt-5.4-mini".freeze

    # Notes long enough to be worth the call. A one-line beat - "Thanked
    # Clarissa for the confirmation" - is already readable, and a cleaned
    # version of it is the same sentence with a comma moved.
    LEAST_WORTH_IT = 120

    # How much the readable version may differ in size. The floor is low
    # because shorthand really does compress: four words standing in for a
    # sentence is normal in these, and a note that cleans to two thirds of its
    # length has lost a point rather than tightened one. The ceiling is the
    # invention guard - expanding fragments into sentences costs a half again,
    # and anything past double is a model writing an essay about his notes.
    LEAST_OF_IT = 0.6
    MOST_OF_IT = 2.0

    Result = Struct.new(:ok, :chars, :error, keyword_init: true)

    # Reads the note he typed and writes a readable one beside it. `again` is
    # the second pass: a note is cleaned once when it lands, and asking twice
    # costs the same call to be handed the same text, so it has to be asked
    # for rather than assumed.
    #
    # A press of `again` OVERWRITES a version he has edited by hand. That is
    # the honest behavior for a button that says clean it up again, and it is
    # why nothing calls this with `again` on his behalf.
    def call(note, again: false)
      said = note.body.to_s.strip
      return Result.new(ok: false, chars: 0, error: :empty) if said.empty?
      return Result.new(ok: false, chars: 0, error: :short) if said.length < LEAST_WORTH_IT
      return Result.new(ok: false, chars: 0, error: :done) if done?(note, again)

      written = ask(Prompt.input(note, said))
      return Result.new(ok: false, chars: 0, error: :unanswered) if written.blank?
      return Result.new(ok: false, chars: 0, error: :refused) unless worth?(said, written)

      note.update!(clean_body: written, cleaned_at: Time.current)
      Result.new(ok: true, chars: written.length)
    end

    def done?(note, again)
      note.cleaned_at.present? && !again
    end

    # Is this his note made readable, or a piece of writing about it?
    def worth?(said, written)
      return false if written.strip.empty?
      return false if written.strip == said
      return false unless sized?(said, written)
      return false unless numbers_kept?(said, written)

      links_kept?(said, written)
    end

    def sized?(said, written)
      share = written.strip.length.to_f / said.length
      share.between?(LEAST_OF_IT, MOST_OF_IT)
    end

    # Every number he wrote down is still there. The cheapest guard and the one
    # that matters most on these: a note's numbers are the times, the round
    # count, the headcount and the money, they are the first thing a rewritten
    # sentence rounds off, and a changed one is invisible in readable prose.
    def numbers_kept?(said, written)
      said.scan(/\d+/).uniq.all? { |number| written.include?(number) }
    end

    # And every link, whole. A note taken during a call is where the CoderPad
    # and the Zoom room get written down, and a URL is the one thing in here
    # that is worthless if a single character of it is tidied.
    def links_kept?(said, written)
      said.scan(%r{https?://\S+}).uniq.all? { |link| written.include?(link.sub(/[.,)]+\z/, "")) }
    end

    def ask(input)
      result = Buddy::GPT::Client.new(model: MODEL).stream(
        instructions: input,
        input:        [{ role: :user, content: [{ type: :input_text, text: "Write these up." }] }],
      )
      return nil unless result[:ok]

      strip_fence(result[:text].to_s).strip
    end

    # Asked for markdown and occasionally given it inside a fence anyway. The
    # fence is the ordinary failure and worth surviving; everything else comes
    # through as it was written.
    def strip_fence(said)
      said.strip.sub(/\A```(?:markdown|md|text)?\s*\n/i, "").sub(/\n?```\s*\z/, "")
    end
  end
end
