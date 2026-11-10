module Notes
  module Clean
    # What the model is told. Out on its own for the same reason every pass
    # keeps its prose out here: `clean.rb` is guards and sizes, and a version
    # that came back invented rather than tidied is nearly always a sentence
    # missing from this file.
    module Prompt
      module_function

      # THE JOB IS TYPING, NOT THINKING. A model handed four fragments about an
      # interview will happily write the fifth one that ought to be there, and
      # it reads better than the four it was given - which is exactly why it
      # has to be refused. He will read this version back in a week and believe
      # every line of it was said in the room.
      RULES = <<~TEXT.freeze
        These are notes somebody typed DURING a phone call, fast, while
        listening. They are shorthand: fragments, dropped words, doubled
        letters, headings that are themselves fragments, inconsistent
        indentation, words in capitals for emphasis.

        Write them up so they can be read later. Same notes, same points, in
        the same order - just finished.

        WHAT TO DO:

        - Finish the fragments into sentences. "2 prong: 1 Conversation 2
          Design" becomes "Two prongs: a conversation and a design."
        - Fix the typing. Doubled letters, a misspelling, a missing word, a
          capital left on.
        - Keep the structure he gave it. If he grouped things under a heading,
          they stay under that heading. If he numbered a list, it stays
          numbered and in his order.
        - Keep emphasis where he put it, but say it in words rather than in
          capitals. "MOST SIMPLISITIC DESIGN POSSIBLE" becomes "The most
          simplistic design possible" - and if he wrote it in capitals or
          repeated it, it is clearly important, so it may be bolded.
        - Expand an abbreviation only where it is unambiguous from the note
          itself.

        WHAT MUST NOT HAPPEN:

        - Do not add a point, an example, a reason or a conclusion that is not
          in the notes. If a list has four things in it, your version has four
          things in it. This is the one failure that matters.
        - Do not add advice. These are a record of what somebody said, not a
          plan for what to do about it.
        - Do not change a number, a time, a name, a company or a link. Copy
          every one of them exactly, including links in full.
        - Do not soften or strengthen anything. If a note says "do NOT jump
          in", the written version says do not jump in - not "it may be
          advisable to pause".
        - Do not reorder, merge or drop anything, including a point made twice.
        - Do not resolve something the notes left unclear. A fragment you
          genuinely cannot read gets copied through as it stands. Guessing
          reads as a fact.
        - Do not write an introduction, a summary, a conclusion or a title.
          Start with the first note and stop after the last.

        The test: he reads it and recognises his own notes, finished. Not a
        write-up of the call.
      TEXT

      OUTPUT = <<~TEXT.freeze
        Reply with the written-up notes as markdown, and nothing else. No
        preamble, no fence, no closing remark.

        Headings in the notes become bold lines or `##` headings. A list in the
        notes stays a list. Keep the paragraph breaks he made.
      TEXT

      # The little the model needs about which beat this is. Who he spoke to
      # and what kind of conversation it was, because both decide how a
      # fragment reads: "Garrett is interviewing" is a fact about next week in
      # notes from a recruiter call, and a fact about the room in notes from an
      # interview.
      def context(note)
        rows = [
          ("These notes are from a #{note.tag_label.downcase}." if note.tag_label.present?),
          ("The other person was #{note.spoke_to}." if note.spoke_to.present?),
          ("It was about the #{note.job_application.company} application." if company?(note)),
        ].compact
        return nil if rows.empty?

        rows.join(" ")
      end

      def company?(note)
        note.job_application&.company.present?
      end

      def input(note, said)
        [
          RULES,
          context(note),
          OUTPUT,
          "THE NOTES:\n\n#{said}",
        ].compact.join("\n\n")
      end
    end
  end
end
