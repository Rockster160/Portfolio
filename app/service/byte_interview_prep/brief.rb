# Everything the pre-interview session is told, in one place.
#
# Separate from the run because they are two different jobs: ByteInterviewPrep
# owns the thread, the guards, and what happens to the answer; this owns what
# the session knows when it starts. This is the half that gets edited - a brief
# that came back thin is nearly always a question this file did not ask.
#
# Spelled out rather than left to be worked out, for the reason the standup
# prompt gives: a fresh session spends its first turns rediscovering where
# things are, and rediscovery inside an hour is where a run quietly decides to
# research the wrong company.
module ByteInterviewPrep
  module Brief
    module_function

    # How much of the timeline to hand over. An application with forty beats on
    # it has them because mail keeps arriving; the last dozen are the ones that
    # describe the conversation being prepared for.
    #
    # THE COUNT IS THE LIMIT, AND IT IS THE ONLY ONE. Each beat used to be cut
    # at 400 characters, which is a greeting and the first paragraph - so the
    # brief was written off the top of each mail and the interviewer's name, the
    # agenda and what the round is actually about all sat below the cut. Worse,
    # the session read the ellipsis as content and put it in the brief as a fact
    # about the conversation. A beat is a mail he was sent and it is capped at
    # `JobNote::MAX_BODY` where it is stored; twelve of those is a prompt worth
    # paying for, and the one thing a brief cannot do is be thin.
    MOST_NOTES = 12

    def stamp(time, user)
      return "(no time on the row)" if time.nil?

      time.in_time_zone(user.timezone).strftime("%A %B %-d, %Y at %-I:%M %p")
    end

    # The booking in its own words. The first line of the notes is dropped: it
    # is the link that got us here, and everything it points at is below.
    def event_block(item, user)
      return "There is no calendar row for this one - it was asked for by hand." if item.nil?

      said = item.notes.to_s.lines.drop(1).join.strip
      [
        "- On the calendar as: **#{item.name}**",
        "- Starts: #{stamp(item.start_at, user)}",
        ("- Ends: #{stamp(item.end_at, user)}" if item.end_at.present?),
        ("- Where: #{item.location}" if item.location.present?),
        ("- The row says:\n\n#{said.indent(2)}" if said.present?),
      ].compact.join("\n")
    end

    # THE POSTING IS FETCHED WITH A COMMAND, NOT A LINK.
    #
    # The board answers on localhost and a tool call cannot fetch a loopback
    # address at all, so the session has no way to open the page - and the
    # scraped posting is the one source for the role that outlives their
    # listing going dead. `jobhunt show <id>` prints the same row out of the
    # board's own database, which also means it answers whether or not the web
    # half of the board is running.
    def job_block(application)
      posting = (
        if application.jobhunt_job_id.present?
          "- The posting as it was scraped: run `jobhunt show #{application.jobhunt_job_id}`"
        end
      )

      [
        "- Company: **#{application.company}**",
        "- Role: #{application.role.presence || "(not recorded)"}",
        ("- Their listing: #{application.url}" if application.url.present?),
        ("- Found via: #{application.source}" if application.source.present?),
        posting,
      ].compact.join("\n")
    end

    # The timeline, newest first, which is the order it reads as a story
    # working backwards from "and now there is an interview".
    def timeline_block(application, user)
      notes = application.notes.recent.first(MOST_NOTES)
      return "Nothing is logged against this one yet." if notes.empty?

      notes.map { |note|
        head = [
          note.occurred_at.in_time_zone(user.timezone).strftime("%b %-d"),
          note.tag_label,
          ("with #{note.spoke_to}" if note.spoke_to.present?),
        ].compact.join(" - ")
        body = note.body.to_s.strip

        # Under its own line rather than run onto it. A beat carries the whole
        # mail now, and a mail on the same line as its date is a wall.
        body.empty? ? "- #{head}" : "- #{head}:\n\n#{body.indent(2)}"
      }.join("\n\n")
    end

    # Who he has already met, named. Both places it gets written down: the
    # `spoke_to` on a beat, and the speakers he named on a recording.
    def people(application)
      said = application.notes.filter_map { |note| note.spoke_to.presence }
      named = application.transcripts.flat_map { |transcript|
        transcript.labels.filter_map { |label|
          name = transcript.name_for(label)
          name unless transcript.mine?(label) || name == label
        }
      }

      (said + named).map(&:strip).uniq
    end

    def people_block(application)
      found = people(application)
      return "Nobody on this one is recorded by name yet." if found.empty?

      "Already spoken to, by name: #{found.join(", ")}. " \
        "Say what is known about them where it helps and skip them where it does not."
    end

    # THE CALLS THEMSELVES, not a list of them.
    #
    # This named the recordings and said they were on the application's page -
    # "you cannot open it from here" - which is the same failure as "Use #3".
    # What was said on the last call with these people is the single most useful
    # thing there is an hour before the next one, and it was being withheld from
    # the one session that had a reason to read it.
    #
    # Named speakers, because that is what makes it a conversation rather than a
    # wall: `mine?` is him, and a label nobody has named yet goes in as the
    # label so the session can see it has not been placed.
    def recordings_block(application)
      found = application.transcripts.to_a
      return nil if found.empty?

      found.map { |transcript|
        head = [transcript.label, transcript.occurred_at&.strftime("%b %-d")].compact_blank.join(", ")
        said = transcript.turns.map { |turn|
          label = turn["speaker"].to_s
          who = transcript.mine?(label) ? "ME" : transcript.name_for(label)
          "#{who}: #{turn["text"]}"
        }
        "#{head}:\n\n#{said.join("\n").indent(2)}"
      }.join("\n\n")
    end

    # Its own heading, and only when there is one. Left out entirely rather than
    # headed with "nothing recorded" - most applications have no call on them,
    # and an empty section is one more thing in a prompt that has to be read
    # before it can be dismissed.
    def recordings_section(application)
      said = recordings_block(application)
      return nil if said.blank?

      ["", "WHAT WAS SAID ON THE EARLIER CALLS", "What they actually told me, and what I actually said. `ME` is me.", "", said].join("\n")
    end

    def text(application, item, user: nil)
      user ||= application.user

      <<~TXT
        I have an interview in about an hour. Write me the brief.

        THE CONVERSATION
        #{event_block(item, user)}

        THE APPLICATION
        #{job_block(application)}

        #{people_block(application)}

        WHAT HAS HAPPENED SO FAR
        Newest first, and each beat is the message ITSELF rather than a summary of it - a confirmation mail carries the agenda and the interviewer's name, a rejection carries whatever reason they gave. Read them; this is the whole of what I have written down about them.

        #{timeline_block(application, user)}
        #{recordings_section(application)}

        WORK OUT WHAT KIND OF CONVERSATION THIS IS FIRST
        Everything else follows from it, and the material above is what decides it - the title on the row, who it is with, how long it is, and what the last beat on the timeline said. A 30 minute first call with a recruiter is not a technical screen, and a brief that prepares me for the wrong one is worse than no brief.

        - **A recruiter or screening call**: what the company does, in a sentence I could say back. Why the role exists. What they are likely to ask (notice period, salary, why them) and what I should ask back. No algorithms.
        - **A technical interview**: the stack it will be in, the two or three things in it I should go over before I sit down, and the shape of the exercise if the material says anything about it. Be specific - "brush up on X" is worth nothing without saying what about X.
        - **A hiring manager or behavioral round**: what this team owns, who I would be working for, and the questions that come with that seat. I keep written answers to the common behavioral ones - pick the ones that fit and carry them into the brief as they are written, rather than writing new ones.
        - **A panel or onsite**: who is in it and what each of them is likely to be probing.

        WHERE TO LOOK
        - **The web is the main source for the company.** Search for them, read their own site, and read their engineering blog and careers page if they have one. What they build, who they sell it to, how big they are, how old they are, who funds them, what they have shipped or announced lately, and anything that has been said about what it is like to work there. If the listing above is still up, read it.
        - **`jobhunt show <id>` is my own job board, on this machine.** The command named above prints the posting as it was scraped, which outlives their listing going dead - read it, it is the best single source for what the role actually is. Run it in this directory. Do NOT try to fetch `#{JOBHUNT_URL}` or any other localhost page: a tool call cannot reach a loopback address and the refusal is the only thing you will get.
        - **`#{CWD}/profile/profile.yml`** is me: what I do, what I am asking for, what I have said about my own background. Read it before you tell me what to brush up on.
        - **`#{RESUME_REPO}`** is the resume repo - `resume.html`, `accomplishments.md`, `experience.txt`, and `interview-answers.md`, which is where my behavioral answers are already written. It is on an external drive. If it is not mounted, say so in one line and write the brief without it rather than stopping.

        TWO RULES
        This session is READ ONLY and there is nobody to ask. Every tool call is answered by a hook against a fixed read-only list and anything else is refused on the spot - do not retry a refusal, and do not ask a question. If you could not find something out, say so in the brief in one line and move on.

        Nothing here is mine to write to. No commits, no edits, no files - the brief is what you reply with, and it is saved and linked for me automatically.

        WHAT TO WRITE
        Open with exactly two lines, in this order and nothing above them:

        ```
        # <a title: what this conversation is, and with whom>
        KIND: <one of recruiter, technical, behavioral, manager, panel, onsite - or unknown>
        ```

        Then the brief itself, in markdown, in this order:

        1. **The company** - what they do and who for, in two or three sentences I could say back out loud. Then the handful of facts worth having: size, age, funding or ownership, what they have shipped or announced lately.
        2. **This role, and why it exists** - what the team is for and where I would sit in it.
        3. **What to go over before it starts** - the specific things, named. This is the section I will actually act on, so put the most useful thing first and stop when you run out of real ones. Three good lines beat eight filler ones.
        4. **What they are likely to ask, each with its answer under it** - real questions, in the words they would use, and the answer to that question directly beneath it. Where one of my written answers fits, it goes there in full; where none does, two or three lines on how I would answer.
        5. **What I should ask them** - three or four, specific to this company and this team. Nothing that could be asked of anybody.
        6. **Anything odd** - a bad sign, a gap in what I know, something in the timeline worth raising. One line each, and leave the section out if there is nothing in it.

        WHATEVER THE BRIEF NAMES, THE BRIEF CARRIES
        Nothing in it may need a second page to be worth anything. If it names something I keep written down - a behavioral answer, a number, a line out of my own notes - the thing goes in, not a pointer to it. "Use #3" has sent me to another page to do the one job the brief exists to do, and at T-10 minutes on a phone I am not going to go and open `interview-answers.md` to find out what #3 was. That is the difference between a brief and an index.

        AN ANSWER SITS UNDER ITS QUESTION
        Not in a section of its own further down. The answers used to be collected at the end and named from section 4, so reading one meant scrolling between the question and the answer and losing my place in both. Every question in section 4 is followed by the answer to THAT question, whole, before the next question starts. If one written answer is honestly the answer to two of the questions, use it once: keep the question it fits best and drop the other, rather than printing the same story twice or sending me back up the page to find it.

        EVERY TERM IS EXPLAINED WHERE IT IS USED
        In brackets, at first use, in the sentence it appears in - not in a glossary at the top, which is the same scroll as the answers were. It applies to all of them and not only the exotic ones: the shorthand everybody in the industry is assumed to know is exactly the one that goes past me bare, and "IC" and "VC" both have. So would ARR, RIF, FTE, Series B, SOC 2, TS/SCI, IDIQ, and anything out of their own product line or their stack. Write "IC (individual contributor - hands-on, nobody reporting to me)" the first time and plain English after it. A word I have to go and look up in the ten minutes I do not have is a word the brief did not carry.

        For the written answers specifically:
        - **Verbatim, as the file has it.** They are already written to be spoken. Tightening one here is a second opinion on a sentence I have already said out loud.
        - **The cut that fits, not the whole entry.** Several of them have an alternate or a system-design cut; carry the one the question it is sitting under actually asks for, and say which it is.
        - **Only the part I would say.** The `Why it works`, `Backing`, `Use this one when` and `[need number]` notes are mine for maintaining the file. They are not the answer and they do not go in the brief.

        I am reading this in the ten minutes before I join the call, on a phone. Write it to be read standing up: short paragraphs, no preamble, no restating the question back at me, no telling me I will do great. A written answer is as long as it is written and that is not a reason to shorten it, nor licence for the sections around it to sprawl. Say where something is a guess rather than stating it flatly - a confident wrong fact about the company said out loud in the call is the one failure that is worse than a thin brief.
      TXT
    end
  end
end
