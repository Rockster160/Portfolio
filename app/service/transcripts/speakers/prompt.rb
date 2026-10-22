module Transcripts
  module Speakers
    # What the model is told. Out on its own because it is the half that gets
    # TUNED: everything in `sides.rb` is slicing text and counting characters,
    # and a bad split is nearly always a sentence missing from here.
    module Prompt
      module_function

      # The two sides, and the one thing that decides which is which. Written
      # as signals rather than as a definition because a transcript rarely says
      # "I am the candidate" - it says "thanks for making the time", and that is
      # the same sentence from either chair.
      RULES = <<~TEXT.freeze
        You are reading the transcript of a job interview that came back with no
        speaker labels at all. Your whole job is to work out which side of the
        conversation each stretch of talking is on.

        THERE ARE EXACTLY TWO SIDES.

        - `m` - the CANDIDATE. One person, the one being interviewed. Their side
          of it is answers: what they have built, where they worked, how they
          would approach something, what they want to know about the job.
        - `t` - THE EMPLOYER'S SIDE. Often more than one person - a recruiter and
          a hiring manager, or a panel of three - and they ALL count as `t`. Do
          not try to tell them apart and do not invent a third side for them.

        What usually settles it:

        - Questions about the candidate's experience, and the whole frame of
          running the conversation ("let's start with", "I'll hand over to", "we
          have about ten minutes left") are `t`.
        - Answers in the first person about their own work, and questions about
          the team, the stack, the process or next steps, are `m`.
        - "We" meaning the company, describing what the company does or wants, is
          `t`. "We" meaning a team the speaker used to be on, in the past tense,
          is usually `m`.
        - Someone being thanked or addressed by name is the OTHER side from
          whoever said the name.
        - The candidate talks for longer at a stretch than anyone else. A short
          "mm-hm", "right", "that makes sense" in the middle of a long answer is
          the employer's side acknowledging, not the candidate.

        A conversation hands back and forth constantly. Alternating is the normal
        shape, but it is not a rule: two of them asking in a row happens, and so
        does a candidate answering, pausing and carrying on.
      TEXT

      def context(transcript)
        job = transcript.job_application
        [
          "The candidate is #{job.user.first_name}.",
          "The company interviewing them is #{job.company}.",
          ("The role is #{job.role}." if job.role.present?),
          people(transcript),
          ("The conversation is a #{transcript.job_note.tag_label.downcase}." if transcript.job_note),
        ].compact.join(" ")
      end

      # Who is known to be on the employer's side, by name. Worth handing over
      # because "thanks, Dana" is one of the few sentences in a transcript that
      # settles a handover outright - but only as a hint, since the person named
      # may never speak.
      def people(transcript)
        named = transcript.job_application.notes.filter_map { |note| note.spoke_to.presence }
        return nil if named.empty?

        "People on the employer's side, where they have been written down: " \
          "#{named.map(&:strip).uniq.join(", ")}. Anyone else who speaks is still `t`."
      end

      # ---- the two shapes it is asked for --------------------------------------

      # Labels for turns that are already cut, which is the easy half: the
      # transcript came with timings, so WHERE the handovers are is already
      # known and only WHO is being asked for. One letter per turn, in order,
      # as a single string - the length is then checkable, and a miscount is
      # thrown away rather than shifting every turn after it onto the wrong
      # side.
      TURNS_OUTPUT = <<~TEXT.freeze
        Below are %<count>d numbered turns from the middle of this conversation.
        Reply with a single JSON object:

        {"sides": "<%<count>d letters, one per turn, in order, each m or t>"}

        Exactly %<count>d letters, nothing else in the string, no spaces, no
        commas. Every turn gets a letter even if you are unsure - pick the more
        likely side.
      TEXT

      # Where the handovers ARE, for a wall of text with no structure at all.
      #
      # The opening words of each turn are asked for VERBATIM, because they are
      # used to find the cut in the original text - the text itself is never
      # taken from the reply, so nothing the model rewrites, tidies or
      # paraphrases can reach the transcript. A quote that cannot be found is
      # dropped and the two turns stay joined.
      CUTS_OUTPUT = <<~TEXT.freeze
        Below is a stretch of the conversation as one unbroken wall of text.
        Break it into turns - one per stretch of one side talking - and reply
        with a single JSON object:

        {"turns": [{"who": "m", "starts": "<the first 8-12 words of this turn, copied EXACTLY>"}, ...]}

        Rules for `starts`:

        - Copy the words EXACTLY as they appear, including punctuation and any
          mistranscription. Do not correct, tidy, shorten or re-spell anything.
        - Long enough to be unique - eight words or so. A quote I cannot find
          in the text is thrown away, and the turn before it swallows it.
        - In order, from the start of the text to the end, and the first entry
          starts at the very beginning of the text.

        Cover the whole stretch. Expect dozens of turns in a passage this long,
        not three.
      TEXT

      # The file named people. Which of those labels is the candidate is the one
      # thing it cannot say for itself, and a name is only worth writing down
      # when somebody says it out loud - `Speakers.heard_name` throws away any
      # that is not in the words, so inventing one here buys nothing.
      LABELS_OUTPUT = <<~TEXT.freeze
        The transcript below is labelled, and the labels are fine - do not
        change them, do not merge them and do not invent one. Say which side
        each label is on, and give a name ONLY where the conversation itself
        says it (somebody introduces themselves, or is thanked or addressed by
        name). Reply with a single JSON object:

        {"labels": [{"label": "<exactly as it appears>", "side": "m", "name": "<a name actually said, or empty>"}, ...]}

        Exactly one label is `m` - there is one candidate. Every other label is
        `t`, however many of them there are. A name you are not sure was said
        goes in as an empty string; a wrong name on a quote is worse than none.
      TEXT

      # Enough of the conversation to tell who is who. The opening is where the
      # introductions are, so it is the part that answers this - and a cap,
      # because an hour of talking says nothing the first ten minutes did not.
      MOST_SAMPLE = 60
      MOST_WORDS_PER_TURN = 60

      def labels_input(transcript)
        said = transcript.turns.first(MOST_SAMPLE).map { |turn|
          "#{turn["speaker"]}: #{turn["text"].to_s.split.first(MOST_WORDS_PER_TURN).join(" ")}"
        }
        [
          RULES,
          context(transcript),
          "The labels in the file, in the order they first speak: " \
          "#{transcript.labels.join(", ")}.",
          LABELS_OUTPUT,
          said.join("\n\n"),
        ].join("\n\n")
      end

      def turns_input(turns, transcript, offset: 0)
        said = turns.each_with_index.map { |turn, index|
          clock = turn["at"].present? ? " [#{(turn["at"] / 60).to_i}m]" : ""
          "#{offset + index + 1}.#{clock} #{turn["text"]}"
        }
        [
          RULES,
          context(transcript),
          format(TURNS_OUTPUT, count: turns.size),
          said.join("\n\n"),
        ].join("\n\n")
      end

      def cuts_input(text, transcript)
        [RULES, context(transcript), CUTS_OUTPUT, text].join("\n\n")
      end
    end
  end
end
