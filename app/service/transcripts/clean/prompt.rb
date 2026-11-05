module Transcripts
  module Clean
    # What the model is told. Out on its own for the same reason the other
    # passes keep theirs out here: everything in `clean.rb` is windowing text
    # and refusing replacements, and a version that came back rewritten rather
    # than cleaned is nearly always a sentence missing from this file.
    module Prompt
      module_function

      # The job, and then the line this pass has to walk.
      #
      # THIS IS THE ONLY PASS THAT IS ALLOWED TO EDIT, and that makes it the
      # one that needs the tightest instructions. `Tidy` refuses every rewrite
      # outright, so its whole defence is a list of things not to do. Here the
      # rewrite IS the job, and the failure is one step further on: asked to
      # clean a spoken answer, a model tightens the argument, merges the three
      # sentences that circled the same point into the good one, and hands back
      # the answer he wishes he had given. That version is useful to nobody. He
      # cannot practise it, because it is not what he says; he cannot learn
      # from it, because the circling is the thing to fix; and he would read it
      # later believing he had been that fluent in the room.
      RULES = <<~TEXT.freeze
        You are reading the transcript of a real job interview, typed up
        automatically off a recording. The candidate wants a version he can
        read: the same conversation with the noise of speech taken out.

        Your job is to write each turn again with the audio quirks removed and
        NOTHING ELSE CHANGED.

        WHAT COMES OUT:

        - "um", "uh", "er", "mm", "hmm", "like" used as filler, "you know",
          "I mean" used as filler, "kind of" and "sort of" where they are
          padding.
        - A stammer, a repeated word, a false start - "my, my biggest thing",
          "we had to, we had to go back", "the co-, the front end".
        - A sentence abandoned halfway and started again. Keep the version he
          finished and drop the one he abandoned.
        - Hunting for a word out loud: "what's that word", "I can't think of
          the right word", "is that the word?", "what is that called".
        - Checking whether the answer landed: "does that answer your
          question?", "I don't know if that fully answers it", "I kind of went
          on a tangent there".
        - An apology for nothing - a cough, a pause, taking too long.
        - "basically", "essentially", "actually", "obviously", "honestly",
          "really" and "literally" where they carry nothing.

        WHAT STAYS, ALL OF IT:

        - Every sentence he actually finished, in the order he said it. Same
          sentence boundaries, same clauses, same words.
        - His grammar and his register. If a sentence is loose, it stays loose.
          You are not improving it.
        - Every number, exactly as the transcript writes it. If it says "5 or 6
          times", write "5 or 6 times" and not "five or six times".
        - Every name, product, company and technical term, spelled as the
          transcript spells it.
        - Uncertainty about a FACT. "I think it took six or seven iterations"
          and "I don't remember exactly what his plan was" are things he does
          not know, and they stay. Only uncertainty about whether he is
          ANSWERING WELL comes out.
        - Every point he made, including the ones he made twice. If he circled
          the same idea in three sentences, there are three sentences in your
          version. Do not merge them and do not pick the best one.

        WHAT MUST NOT HAPPEN:

        - Do not summarise, shorten or tighten. A cleaned turn is almost as
          long as the one it came from, because only the noise is gone.
        - Do not reorder anything, and do not move a sentence to where it
          would read better.
        - Do not add a word that carries meaning. You may put back a dropped
          "the" or "are" where the sentence cannot be read without it.
        - Do not make an argument better than he made it, finish a thought he
          left unfinished, or supply a fact he did not say.
        - Do not change a garbled stretch you cannot read. Copy it through as
          it stands. The recorder mishears things, and a confident guess reads
          as something that was said.

        The test for every turn: he reads it and recognises it as the thing he
        said, with the stumbling taken out. Not as a better answer.
      TEXT

      BEFORE_SAID = <<~TEXT.freeze
        WHAT WAS SAID JUST BEFORE THIS STRETCH, for context only. Do not write
        it out again - it is here so the first turn below is not read cold.
      TEXT

      OUTPUT = <<~TEXT.freeze
        Reply with a single JSON object, and nothing else:

        {"clean": [{"turn": <number>, "text": "<the turn with the noise gone>"}]}

        - `turn` is the number at the front of the line.
        - One entry for every turn you were given, in order.
        - `text` is the WHOLE turn written again, not a fragment of it and not
          a note about it.
        - A turn with no noise in it still gets an entry, with its text
          unchanged.
        - A turn that was nothing but filler - "Um...", "Ooh. Uh." - gets an
          entry with `text` as an empty string.
      TEXT

      # Who said it rides along, because it is half of what makes a false start
      # recognisable: his turns are where the stumbling is, and a short line
      # from the other side is usually a question asked cleanly.
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
          before_block(before),
          OUTPUT,
          said.join("\n\n"),
        ].compact.join("\n\n")
      end
    end
  end
end
