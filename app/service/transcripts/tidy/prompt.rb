module Transcripts
  module Tidy
    # What the model is told. Out on its own for the reason the split pass's
    # prompt is: everything in `tidy.rb` is windowing text and refusing
    # replacements, and a pass that corrected something it should have left
    # alone is nearly always a sentence missing from here.
    module Prompt
      module_function

      # The job, and then the whole of what must not happen. The refusals are
      # the longer half on purpose: asked to improve a transcript a model will
      # improve it - tidy the grammar, drop the stammers, join two sentences
      # that belong together - and every one of those is the transcript no
      # longer being what was said.
      RULES = <<~TEXT.freeze
        You are reading a machine transcription of a real conversation - a job
        interview that was recorded and typed up automatically. The machine
        heard sounds and wrote the likeliest words for them, and it got some of
        them wrong: it writes a word that SOUNDS like the one that was said.
        It goes wrong most often on technical terms, on company and product
        names, and on anything said quickly.

        Your whole job is to say which words those are and what was actually
        said. You work it out from the conversation around them - the sentence
        it is in, what was being talked about, what the other side just asked.

        THIS IS NOT AN EDIT. The words that were said stay as they were said:

        - Do not reword anything, reorder anything, or join or split sentences.
        - Do not correct grammar, tense or agreement. People speak like that.
        - Do not remove "um", "uh", "like", "you know", a false start, a
          repeated word or a stammer. They were said and they stay.
        - Do not add, move or remove punctuation, and do not change
          capitalisation except where the word itself changes.
        - Do not shorten anything, summarise anything, or make any sentence
          read better.

        A sentence that reads badly reads badly because that is how it came out
        of somebody's mouth, and this transcript is read back later to find out
        what was actually said. A sentence improved here is a sentence I will
        later believe I said.

        WHAT TO FIX, AND NOTHING ELSE:

        - A word the machine misheard as a different, ordinary word that sounds
          like it, where the conversation makes the intended term unmistakable.
        - Two words the machine ran together or cut in the wrong place, where
          that is plainly what happened.
        - A name - a person, a company, a product, a tool - spelled as it
          sounds instead of as it is, where the conversation says what it is.
        - A short word the machine DROPPED, where the sentence cannot be read
          without it. Putting back a missing "the" or "we" is a fix; writing
          the sentence you think was meant is not.

        WHEN YOU CANNOT TELL, LEAVE IT ALONE. A garbled stretch left garbled
        reads as a garbled stretch, which is the truth about the recording. A
        confident wrong word reads as something that was said. The second is
        much worse than the first, and most of a transcript needs nothing done
        to it - a window with two fixes in it is a normal window.
      TEXT

      # The world these conversations are in, because the mishearings that
      # matter are concentrated in it: a term the model is not expecting is a
      # term it reads as the ordinary word that sounds like it. No list of
      # terms: a fixed vocabulary is one muddy stretch of audio gets "corrected"
      # toward, whether or not anybody in this conversation said it.
      WORDS = <<~TEXT.freeze
        These are software engineering conversations, so technical terms and
        the names of companies and their products are the words most often
        misheard. Only a term the conversation itself makes unmistakable is a
        fix.
      TEXT

      BEFORE_SAID = <<~TEXT.freeze
        WHAT WAS SAID JUST BEFORE THIS STRETCH, for context only. Do not
        correct it and do not mention it in your reply - it is here so the
        first turn below is not read cold.
      TEXT

      OUTPUT = <<~TEXT.freeze
        Reply with a single JSON object, and nothing else:

        {"fixes": [{"turn": <number>, "was": "<the words exactly as they appear above>", "now": "<what was actually said>"}]}

        - `turn` is the number at the front of the line the words are in.
        - `was` is copied EXACTLY out of that line, with its own punctuation
          and capitalisation, and covers A WORD OR A FEW - never a whole
          sentence. A `was` I cannot find in that line is thrown away.
        - `now` is that same stretch with the misheard words put right and
          nothing else touched. It is about as long as `was`, because it is the
          same words heard properly.
        - Nothing to fix is a correct answer: {"fixes": []}
      TEXT

      # Who said it rides along with each line, because it is half of what
      # places a word: the stack somebody describes in the first person is
      # theirs, and the terms their side uses are the terms to expect back.
      def who(transcript, turn)
        label = turn["speaker"].to_s
        return "the candidate" if transcript.mine?(label)
        return "unplaced" if label == JobTranscript::UNKNOWN

        transcript.name_for(label)
      end

      def before_block(before)
        rows = Array(before).map(&:to_s).reject(&:empty?)
        return nil if rows.empty?

        [BEFORE_SAID, rows.join("\n\n")].join("\n\n")
      end

      # Numbered by where the turn is in the whole conversation rather than in
      # the window, so a number means one thing across every call and the same
      # thing as the page's own numbering.
      def input(turns, window, transcript, before: [])
        said = window.map { |at|
          "#{at + 1}. [#{who(transcript, turns[at])}] #{turns[at]["text"]}"
        }
        [
          RULES,
          Speakers::Prompt.context(transcript),
          WORDS,
          before_block(before),
          OUTPUT,
          said.join("\n\n"),
        ].compact.join("\n\n")
      end
    end
  end
end
