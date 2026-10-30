module Transcripts
  module Debrief
    # What the model is told. Out on its own for the same reason the other two
    # passes keep theirs out here: everything in `debrief.rb` is budgeting text
    # and refusing notes that point at nothing, and a debrief that came back
    # useless is nearly always a sentence missing from this file.
    module Prompt
      module_function

      # The job, and then the whole of what makes a debrief worth reading.
      #
      # THE REFUSALS ARE THE LONGER HALF, and they are not the same refusals as
      # the words pass. That one is stopping a model from improving a sentence;
      # this one is stopping it from being KIND. Asked how an interview went, a
      # model writes four generous paragraphs and one gentle suggestion, and
      # that is worse than no debrief at all: it is the same reading I already
      # have of my own call, handed back with a stamp on it, an hour after the
      # two rejections that said the opposite.
      RULES = <<~TEXT.freeze
        You are reading the transcript of a real job interview that has already
        happened. The candidate recorded it. He is asking you how he did.

        Your job is to tell him, and then to tell him what to say instead.

        BE HONEST BEFORE YOU ARE KIND. He is not deciding whether to feel good
        about this; he is deciding what to do differently in the next one, and a
        debrief that tells him it went well is worth nothing to him. If an
        answer was vague, say which answer and what was missing from it. If he
        talked for four minutes on a question that wanted thirty seconds, say
        so. If he never actually answered something, name the question. If he
        gave them a reason to pass on him, say what it was in plain words.

        - Do not open by saying it went well, or by thanking him, or by
          softening what comes next.
        - Do not pad the good with the bad to make the balance look fair. Two
          real strengths and four real problems is a normal honest reading.
        - Do not write anything that would be true of any interview. "Be more
          concise", "show more enthusiasm" and "research the company" are
          worthless to him. Every note is about THIS conversation.
        - Do not tell him what he already said. He was there. A note that
          summarises his answer back at him is a wasted note.

        EVERY NOTE POINTS AT A NUMBERED TURN. That is the whole discipline
        here: a judgment you cannot attach to something he actually said is a
        judgment about an interview you have imagined. If you believe an answer
        was weak, the note goes on the turn the answer is in.

        THIS TRANSCRIPT CAME OFF A MACHINE. It heard sounds and wrote the
        likeliest words for them, so it is wrong in places. Where a sentence
        reads as nonsense or a word is plainly the wrong one, that is the
        recorder mishearing him and NOT him speaking badly. Never make a note
        about phrasing, grammar or a garbled stretch that could be a
        mishearing, and never note "um", "uh", "like" or a repeated word: the
        recorder writes those in, they are how everybody speaks out loud, and
        they are not what loses an interview.
      TEXT

      # What actually goes wrong in these, named. Here rather than left to be
      # worked out because a model reaching for interview advice reaches for
      # the generic article - pace, posture, enthusiasm - and the things that
      # decide these conversations are much more specific and all of them are
      # visible in a transcript.
      LOOK_FOR = <<~TEXT.freeze
        WHAT TO LOOK FOR, in roughly the order it costs him the job:

        - A question he did not answer. He answered a nearby one, or told the
          story he wanted to tell, and the thing they asked went by. This is
          the most expensive one and it is the easiest to miss on the way out
          of a call, because it feels like the answer was given.
        - A story told without the thing that made it hard. The mechanism, the
          number, the scale, the constraint, the tool. He has these; they drop
          out when he is talking. If a story would land twice as hard with one
          figure in it, say which figure is missing.
        - Himself undercut. "Just", "only", "a little side thing", "I'm not
          really a X", volunteering a weakness nobody asked about, apologising
          for something that needs no apology, agreeing with a wrong premise
          about his own experience to be agreeable.
        - A wrong assumption about him left standing. They said or implied
          something inaccurate about his background, his level, or what he has
          done, and he let it go past.
        - An answer that ran long past its point, or one that was too thin for
          the question asked.
        - Money, notice, availability or the gap handled awkwardly - named
          first when he should have asked what their range was, a number given
          away, an apology attached to it.
        - Nothing asked back, or questions asked that could have been asked of
          any company. What he asks them is read as how seriously he is taking
          it.
        - A signal from them he did not pick up. They told him what they care
          about, or what the hard problem on the team is, and the next answer
          did not use it.
        - The close. Whether he found out what happens next and when, and
          whether he said plainly that he wants it.

        AND WHAT ACTUALLY WORKED. Not to balance the page - so he does it
        again. The strongest two or three moments, and what made them strong,
        in a way he could repeat on purpose.
      TEXT

      # The replacement sentence, which is the half he asked for and the half a
      # model skips. "You could have been more specific here" is a diagnosis;
      # what he needs is the sentence to say next time, short enough to say out
      # loud under pressure, in words he would actually use.
      INSTEAD = <<~TEXT.freeze
        WHEN SOMETHING COST HIM, WRITE THE SENTENCE HE SHOULD HAVE SAID.

        Not advice about the sentence. The sentence. One or two lines, the way
        a person talks, short enough to say out loud while being looked at.

        It has to be sayable BY HIM, so build it out of what the transcript
        shows he knows - his own work, his own words elsewhere in the call, the
        terms he uses. Do not put a claim in his mouth that the conversation
        does not support, and do not write it in a register he never speaks in.
        If the honest answer is that the words were fine and what was missing
        was a fact he has not got, say that instead of inventing the fact.
      TEXT

      OUTPUT = <<~TEXT.freeze
        Reply with a single JSON object, and nothing else:

        {
          "read": "<how it actually went, three or four sentences, no hedging>",
          "strongest": [{"turn": 18, "why": "<what made this land, in one or two lines>"}],
          "cost": [{"turn": 34, "what": "<what went wrong here and what it cost>", "instead": "<the sentence he should have said>"}],
          "missed": [{"what": "<something he should have said or asked and never did>", "where": "<when in the conversation it belonged>"}],
          "next": ["<one thing to do differently in the next interview, specific enough to act on>"]
        }

        - `turn` is the number at the front of a line, and it must be one of
          HIS lines - the ones marked `ME`. A note on their line is thrown
          away, because every note here is about how he did.
        - `read` is the honest reading. It is the first thing he will see and
          it is not an introduction to the rest; say how it went and why.
        - `strongest` holds at most three. If there is honestly only one, send
          one. Do not fill it.
        - `cost` holds the moments that hurt him, each with the sentence to say
          instead. At most four, worst first.
        - `missed` is for what is not in any single turn - a thing never said,
          a question never asked, a close that never happened. `where` is in
          words, not a number.
        - `next` is what he carries into the next conversation. Three or four,
          and each one has to be something he could actually do.
        - An honestly good interview is a short `cost` list, not an empty one
          dressed up. An honestly bad one is a `read` that says so.
      TEXT

      # Who is who, and what the conversation was. `ME` for his turns, because
      # it is what every other prompt in this area calls him and because the
      # whole reply is judgments about which lines are his.
      def who(transcript, turn)
        label = turn["speaker"].to_s
        return "ME" if transcript.mine?(label)
        return "unplaced" if label == JobTranscript::UNKNOWN

        transcript.name_for(label)
      end

      def context(transcript)
        job = transcript.job_application
        [
          Speakers::Prompt.context(transcript),
          ("The recording is #{transcript.spoken_minutes} minutes long." if transcript.spoken_minutes),
          ("What the listing said it pays: #{job.pay}." if job&.pay.present?),
        ].compact.join(" ")
      end

      # What he is going for, in his own words, where there is anything written
      # down. A debrief is a reading against what he was trying to do, and the
      # answers he keeps written are the closest thing to that there is here.
      AIMING = <<~TEXT.freeze
        WHAT WAS WRITTEN DOWN ABOUT THIS ROUND BEFORE IT HAPPENED, so you can
        read the conversation against what it was meant to be - a screen, a
        technical round, a conversation with the manager. It is context only.
        Do not make notes about it and do not quote it back.
      TEXT

      MOST_AIMING = 1_200

      def aiming(transcript)
        notes = transcript.job_application&.notes
        note = transcript.job_note || notes&.recent&.first
        return nil if note.nil?

        said = note.body.to_s.strip
        return nil if said.blank?

        [AIMING, said.truncate(MOST_AIMING)].join("\n")
      end

      def input(transcript, said)
        [
          RULES,
          context(transcript),
          LOOK_FOR,
          INSTEAD,
          aiming(transcript),
          OUTPUT,
          "THE CONVERSATION",
          said.join("\n\n"),
        ].compact.join("\n\n")
      end
    end
  end
end
