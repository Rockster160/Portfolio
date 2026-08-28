module Buddy
  module GPT
    # The one tool Buddy calls to READ live state (chores, agenda, events,
    # reminders, ideas, Jil automations).
    #
    # This replaces the old design where Rails shipped a context JSON inline to
    # the Mac, the Mac wrote it to local disk, and Buddy used Claude Code's
    # `Read` tool on it. Calling straight into Buddy::Context.build keeps the
    # same "only fetch when the message actually needs it" property while
    # removing the file, the disk write, and the Mac from the path entirely.
    #
    # Unlike the proposal tools this is a ROUND-TRIP tool: its output goes back
    # to the model so it can answer using what it read. See Buddy::GPT::Turn.
    class ContextTool
      NAME = :get_context

      # Mirrors the keys Buddy::Context.build returns. Listed explicitly rather
      # than derived so adding a context key is a deliberate decision about
      # whether Buddy should be able to ask for it.
      SECTIONS = %i[
        today_agenda
        upcoming_agenda
        today_notable
        upcoming_notable
        chores_due_today
        chores_pending_today
        chores_done_today
        chores_hot_picks
        chores_scheduled_today
        chores_overdue_backlog
        chores_all
        pebble_balance
        recent_events
        lists
        active_proposals
        recent_actions
        upcoming_reminders
        running_timers
        active_watches
        pending_relays
        pending_prompts
        stashed_ideas
        jil_triggers
        jil_functions
        device_states
        trigger_shapes
        record_links
        app_pages
        routines
      ].freeze

      # What a Today briefing does NOT get to see.
      #
      # A briefing exists to say what is different about this day. Everything
      # withheld here describes the ordinary week instead: the full chore
      # roster, the habits, and the calendar's standing repeats. It is taken
      # away rather than sorted, softened or capped, because every attempt to
      # describe the difference in words failed while both were in front of the
      # model - it read out whatever list it had, and the one unusual thing came
      # last or not at all.
      #
      # The briefing sees `chores_due_today`, `today_notable` and
      # `upcoming_notable`. Those are already only the exceptional rows, so
      # there is no filtering left for the model to get wrong and no count to
      # enforce.
      BRIEFING_WITHHELD = %i[
        today_agenda
        upcoming_agenda
        chores_pending_today
        chores_done_today
        chores_hot_picks
        chores_scheduled_today
        chores_overdue_backlog
        chores_all
      ].freeze

      # Sections a briefing gets whether or not it thought to ask.
      #
      # `upcoming_reminders` is on-demand like everything else, and the briefing
      # prompt only ever told the model how to FILTER it — which ones are stale,
      # which are switched off — never to go and fetch it. So a briefing that
      # didn't ask wrote the day without the half of it that lives in reminders.
      # Prod 3954, 19 Aug: "a very open day ahead, with nothing pressing" at
      # 8:30, against two reminders due at 9:00 and one at 10:00. All three rang
      # on time.
      #
      # Handed over rather than instructed, for the same reason the greeting is:
      # a rule the model has to remember to follow is one it can skip on the
      # morning it matters.
      BRIEFING_ALWAYS = %i[upcoming_reminders].freeze

      # The two sections a briefing gets that can carry somebody else's
      # calendar. See #without_uninvolved_partner_items.
      PARTNER_FILTERED = %i[today_notable upcoming_notable].freeze

      # Sections this turn may not have, for any reason: a feature the person
      # doesn't use, or a briefing that has no business with the full roster.
      def self.withheld(user, briefing: false)
        hidden = Buddy::Features.hidden_sections(user)
        briefing ? (hidden | BRIEFING_WITHHELD) : hidden
      end

      DESCRIPTION = <<~TXT.freeze
        Look up the person's live state. Call this when their message touches
        chores, the agenda/calendar, logged events, reminders, what you're
        watching for, prompts, stashed ideas, or their Jil automations - and
        when a bare greeting means "orient me to my day". Also call it before
        telling them you can't check something: what you can reach is listed
        here, not in your own memory.

        Ask for only the sections you need. Skip this call entirely on pure
        chit-chat that touches none of it; the at-a-glance summary in your
        prompt already covers your current face and today's counts.

        Notable sections:
        - chores_all: the COMPLETE roster of active chore names. This is the
          match roster - when the person says they DID something, match against
          this before ever considering log_event. A chore counts even if it
          isn't due today.
        - chores_pending_today: their intentional today list only, not
          everything that exists.
        - pebble_balance: how many pebbles they have to spend right now.
          Fetch it before answering "how many do I have" and before any
          withdrawal phrased as a share rather than a number ("cash out half",
          "take it all") - you can't work either out from memory.
        - lists: the person's lists, each with its SECTIONS. Check this before
          add_list_item so you can file an item under an existing section
          (produce, dairy, a store) instead of guessing.
        - jil_functions / jil_triggers: what you're allowed to fire, with
          signatures and a description of what each one does. Fuzzy-match on
          purpose, not name. These cover status QUESTIONS too, not just
          commands - a sensor, door, gate, light, or the car's state is
          answerable here, so check before saying you can't see something.
        - routines: sequences they named once so a single phrase runs the whole
          thing. Check here whenever a request sounds like a thing they'd have
          set up ("prep my printer", "wind down"), and run the match with
          run_routine rather than doing the steps yourself.
        - recent_actions: what you actually RAN in this thread, newest first.
          Request it the moment they say you didn't do something, or ask
          whether you did - your own words are not evidence, and this is. If
          the thing isn't listed, it didn't happen: say so and do it.
      TXT

      # Did a get_context call actually fetch the named section? An empty or
      # null list means "everything", which includes it.
      #
      # Buddy::GPT::Turn asks this to tell a turn that LOOKED from one that
      # answered off its own memory. Reading the arguments is the only way to
      # know: the output goes back to the model as a JSON string and nothing
      # downstream records which sections were in it.
      def self.serves?(args, section)
        named = args.is_a?(Hash) ? Array(args["sections"] || args[:sections]) : []
        named.empty? || named.map { |s| s.to_s.to_sym }.include?(section)
      end

      # `user:` narrows the enum to sections this person actually has, so a
      # feature that's switched off isn't even nameable — the model can't ask
      # for chores and then have to explain the empty answer.
      def self.schema(user: nil, briefing: false)
        offered = SECTIONS - withheld(user, briefing: briefing)
        {
          type:        :function,
          name:        NAME,
          description: DESCRIPTION.strip.gsub(/\s*\n\s*\n\s*/, " ").gsub(/\s+/, " "),
          strict:      true,
          parameters:  {
            type:                 :object,
            properties:           {
              sections: {
                type:        [:array, :null],
                items:       { type: :string, enum: offered },
                description: "Which sections to fetch. Null or empty returns everything, " \
                             "which is only worth it for a full day orientation.",
              },
            },
            required:             [:sections],
            additionalProperties: false,
          },
        }
      end

      def initialize(user, conversation, briefing: false)
        @user         = user
        @conversation = conversation
        @briefing     = briefing
        @served       = {}
      end

      # What the model was actually SHOWN, after every filter above. Kept so a
      # pre-send repair can check the reply against it without running the whole
      # context a second time - see Buddy::GPT::Turn#with_leave_times. Merged
      # across calls because a turn may ask for two different slices.
      attr_reader :served

      # Returns the JSON string handed back as the function_call_output.
      def call(args)
        # "Asked for nothing" and "asked only for things this turn can't have"
        # are different, and collapsing them answered a refused request with the
        # entire context: a briefing that asked for chores_all got every section
        # there is, which is the opposite of withholding one.
        payload = named_sections(args).empty? ? context : context.slice(*requested_sections(args))
        # Applied to the everything path too, which is the one a briefing takes.
        payload = payload.except(*self.class.withheld(@user, briefing: @briefing))
        payload = without_routine_reminders(payload)
        payload = without_settled_items(without_uninvolved_partner_items(without_own_reminder(payload)))
        @served = @served.merge(payload)
        JSON.generate(payload)
      rescue StandardError => e
        Buddy::Errors.report(
          section:   "gpt.context_tool",
          exception: e,
          user:      @user,
          extra:     { conversation_id: @conversation.id },
        )
        JSON.generate({ error: "context lookup failed" })
      end

      private

      # A briefing must not list the reminder that CAUSED it.
      #
      # Buddy::TodaySchedule's row is an ordinary recurring reminder on purpose,
      # so it sits in `upcoming_reminders` where Buddy can answer "when's the
      # next one due" — and it rolls forward to tomorrow the instant it fires,
      # which drops it right back inside the 48-hour window while the briefing
      # it just triggered is being written. Prod 3951 closed with "there's one
      # reminder in play already: Today briefing." All three companions carry
      # the row; the other two only happened not to mention it.
      #
      # A whole-section withhold would be wrong — half of somebody's day lives
      # in reminders — so this takes the one row, and only on a briefing turn.
      # Everywhere else it stays, marked `own_briefing`, because "move my morning
      # briefing to nine" needs the id: prod 4020 is what an UNMARKED row costs
      # on an ordinary turn, and removing it there would only trade one wrong
      # answer for another.
      def without_own_reminder(payload)
        return payload unless @briefing
        return payload unless payload[:upcoming_reminders].is_a?(Array)

        payload.merge(upcoming_reminders: payload[:upcoming_reminders].reject { |r| r[:own_briefing] })
      rescue StandardError => e
        Buddy::Errors.report(section: "gpt.context_tool.own_reminder", exception: e, user: @user)
        payload
      end

      # The standing daily nudges, on a briefing turn only.
      #
      # Rocco, 2026-08-28: "We don't want Byte to include all of the every-day
      # reminders in the briefing as it fills it with extra text that's not
      # needed." A reminder that goes off every single day is the shape of an
      # ordinary week, not news about this particular one — the same thing
      # `notable?` has always said about an agenda item, and the briefing
      # prompt has said out loud since it was written: "Everything that repeats
      # on an ordinary daily or weekday rhythm has already been taken out,
      # because I know my own standing schedule and hearing it read back is
      # what makes a briefing worthless." That was only ever true of the
      # calendar half. `upcoming_reminders` is the other half of the same day
      # and the filter had never been applied to it, so two Do Dishes and a
      # nightly bin nudge came back every morning.
      #
      # Same answer as the partner filter and the passed items below: what the
      # model can't see, it can't read out. The prompt asking for it in prose
      # has lost repeatedly on all three of those.
      #
      # Only `daily` and `every weekday` go (Buddy::Context::ROUTINE_CADENCES).
      # A weekly or monthly one is exactly the thing somebody doesn't have top
      # of mind, which is what makes it worth a line.
      def without_routine_reminders(payload)
        return payload unless @briefing
        return payload unless payload[:upcoming_reminders].is_a?(Array)

        kept = payload[:upcoming_reminders].reject { |r|
          Buddy::Context::ROUTINE_CADENCES.include?(r[:cadence])
        }
        payload.merge(upcoming_reminders: kept)
      rescue StandardError => e
        Buddy::Errors.report(section: "gpt.context_tool.routine_reminders", exception: e, user: @user)
        payload
      end

      # A partner's calendar is not the briefing, and on a briefing turn the
      # ones with no bearing on the day stop being shown at all.
      #
      # `today_briefing.rb` spends three paragraphs on this - NEVER the
      # briefing, default to leaving them out, a briefing that names one while
      # leaving out one of MINE is wrong - and prod 4482 opened "the calendar's
      # busy around you", named five of Chelsea's items, and left his own
      # Serenity out. Prod 4429 the morning before did the milder version. Same
      # answer as the chore roster and as `leave_by`: what the model can't see,
      # it can't read out.
      #
      # An overlap with something of theirs is what "an effect on my day" means
      # in data, so it is still what decides WHICH of a partner's items survive.
      # But the marker comes OFF the ones that do - two different people doing
      # two different things at the same hour is not a clash, and a tag naming
      # what it runs into is an invitation to write one. Prod 4524 read
      # Chelsea's yoga out as Rocco's own; the answer is that a partner's item
      # is background, and background has nothing to compare itself to.
      #
      # Briefing only. Ask "does her yoga run into my retro?" on an ordinary
      # turn and `collides_with` is right there naming the item, because that
      # time the comparison is the question.
      #
      # Briefing only. Ask "what's Chelsea got on today" on an ordinary turn and
      # you still get all of it, because that time you asked.
      def without_uninvolved_partner_items(payload)
        return payload unless @briefing

        PARTNER_FILTERED.each_with_object(payload.dup) { |key, out|
          next unless out[key].is_a?(Array)

          kept     = out[key].reject { |i| i[:mine] == false && i[:collides_with].blank? }
          out[key] = kept.map { |i| i[:mine] == false ? i.except(:collides_with) : i }
        }
      rescue StandardError => e
        Buddy::Errors.report(section: "gpt.context_tool.partner_items", exception: e, user: @user)
        payload
      end

      # Things that have already finished, on a briefing turn only.
      #
      # A briefing looks FORWARD. Both of these are named in `today_briefing.rb`
      # as the thing not to do - passed items "not as a summary, not as a count,
      # not as a passing note that the morning one already went", and a
      # switched-off reminder sitting in context "so you can ANSWER about them
      # when asked, and for no other reason" - and prose has now lost three
      # times across three companions in two days. Prod 4490 opened with "Yoga
      # already passed" and prod 4488 volunteered that a reminder cancelled six
      # days earlier "is not coming at you today". Same answer as the partner
      # filter above and as `leave_by`: what the model can't see, it can't read
      # out. Nobody is asking a question on a briefing turn, so nothing is lost.
      #
      # Two things deliberately STAY:
      # - a `cancelled` agenda item, which the prompt wants raised - a standing
      #   thing not happening today is real news.
      # - `already_rang`, which is history rather than a to-do. Prod 3255 is
      #   what its absence costs: the swimming-lesson reminder rang at 7pm and
      #   the next morning Buddy announced it as "set for this evening", read
      #   off the thread and re-dated a day forward. Taking it out here would
      #   hand the transcript back its only say, on the one turn that opens
      #   with a summary of the day.
      def without_settled_items(payload)
        return payload unless @briefing

        out = payload.dup
        out[:today_notable] = out[:today_notable].reject { |i| i[:passed] } if out[:today_notable].is_a?(Array)
        if out[:upcoming_reminders].is_a?(Array)
          out[:upcoming_reminders] = out[:upcoming_reminders].reject { |r| r[:status].to_s == "off" }
        end
        out
      rescue StandardError => e
        Buddy::Errors.report(section: "gpt.context_tool.settled_items", exception: e, user: @user)
        payload
      end

      # Memoized per turn: Buddy::Context.build runs a lot of queries, and a
      # model that calls get_context twice in one turn must not pay for it
      # twice (or see two different snapshots mid-turn).
      def context
        @context ||= Buddy::Context.build(@user, @conversation)
      end

      JIL_SECTIONS = %i[jil_triggers jil_functions].freeze

      # Whatever the model actually named, before any filtering.
      def named_sections(args)
        raw = args.is_a?(Hash) ? (args["sections"] || args[:sections]) : nil
        Array(raw).map { |s| s.to_s.to_sym }
      end

      def requested_sections(args)
        sections = named_sections(args)
        sections |= BRIEFING_ALWAYS if @briefing
        sections &= (SECTIONS - self.class.withheld(@user, briefing: @briefing))
        # Whether an automation is a trigger or a function is OUR filing system,
        # not something the person's request tells you. Asked to "turn the fan to
        # low", the model looked in jil_triggers, found only "Fan High", and said
        # it couldn't - while "Great Fan" (off/low/mid/high) sat in jil_functions
        # the whole time. Asking for either now returns both, because the model
        # has no way to know which shelf a capability was put on.
        sections |= JIL_SECTIONS if sections.intersect?(JIL_SECTIONS)
        sections
      end
    end
  end
end
