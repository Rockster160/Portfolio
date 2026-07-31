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
        chores_pending_today
        chores_done_today
        chores_hot_picks
        chores_scheduled_today
        chores_overdue_backlog
        chores_all
        recent_events
        lists
        active_proposals
        upcoming_reminders
        active_watches
        pending_relays
        pending_prompts
        stashed_ideas
        jil_triggers
        jil_functions
        routines
      ].freeze

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
      TXT

      def self.schema
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
                items:       { type: :string, enum: SECTIONS },
                description: "Which sections to fetch. Null or empty returns everything, " \
                             "which is only worth it for a full day orientation.",
              },
            },
            required:             [:sections],
            additionalProperties: false,
          },
        }
      end

      def initialize(user, conversation)
        @user         = user
        @conversation = conversation
      end

      # Returns the JSON string handed back as the function_call_output.
      def call(args)
        requested = requested_sections(args)
        payload   = requested.empty? ? context : context.slice(*requested)
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

      # Memoized per turn: Buddy::Context.build runs a lot of queries, and a
      # model that calls get_context twice in one turn must not pay for it
      # twice (or see two different snapshots mid-turn).
      def context
        @context ||= Buddy::Context.build(@user, @conversation)
      end

      JIL_SECTIONS = %i[jil_triggers jil_functions].freeze

      def requested_sections(args)
        raw = args.is_a?(Hash) ? (args["sections"] || args[:sections]) : nil
        sections = Array(raw).map { |s| s.to_s.to_sym } & SECTIONS
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
