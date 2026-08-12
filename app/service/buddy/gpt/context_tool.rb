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
      end

      # Returns the JSON string handed back as the function_call_output.
      def call(args)
        # "Asked for nothing" and "asked only for things this turn can't have"
        # are different, and collapsing them answered a refused request with the
        # entire context: a briefing that asked for chores_all got every section
        # there is, which is the opposite of withholding one.
        payload = named_sections(args).empty? ? context : context.slice(*requested_sections(args))
        # Applied to the everything path too, which is the one a briefing takes.
        JSON.generate(payload.except(*self.class.withheld(@user, briefing: @briefing)))
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
        sections = named_sections(args) & (SECTIONS - self.class.withheld(@user, briefing: @briefing))
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
