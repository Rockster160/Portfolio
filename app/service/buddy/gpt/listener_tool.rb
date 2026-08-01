module Buddy
  module GPT
    # Hands Buddy the listener syntax reference, plus every listener already
    # running on the person's own tasks.
    #
    # The examples are the point, and they answer two different questions.
    #
    # WHAT EXISTS. The trigger surface is much wider than the app: `/jil/webhook`
    # takes the scope off the request, so Home Assistant sensors, buttons,
    # cameras and doorbells all arrive as ordinary Jil triggers under scopes no
    # app code declares. Nothing else Buddy can read mentions them - the
    # `jil_triggers` context section only carries `buddy_visible` tasks, which is
    # 20 of 411 here - so without searching these listeners, an integration is
    # invisible and gets answered with "I don't have that wired" (prod 1479).
    #
    # HOW TO WRITE ONE. What stops a listener from parsing cleanly and then
    # never firing is using a key that doesn't exist in that scope's payload,
    # and the only reliable source for real key paths is listeners that are
    # already working.
    #
    # A ROUND-TRIP tool like ContextTool and PromptTool. Deliberately not in the
    # always-on prompt: the guide is a few thousand tokens and matters on the
    # rare turn where someone wants to watch something unusual.
    class ListenerTool
      NAME = :read_listener_guide

      GUIDE_PATH = Rails.root.join("docs/jil_listener_syntax.md").freeze

      # Enough examples to see the patterns without spending the turn budget on
      # a listing. Scoped ones come first when a scope is named.
      MAX_EXAMPLES = 40

      # Search hits are the answer to a question, not background, so they get
      # their own smaller budget and sit apart from the general sample.
      MAX_MATCHES = 12

      # Words that match everything and therefore mean nothing as search terms.
      STOPWORDS = %w[the a an my our is are was when if of at on in to for and or me].freeze

      COPY_KEYS = "Copy the key paths from an example on the same scope rather than inventing " \
                  "them - a listener with a made-up key parses fine and never fires.".freeze

      UNSEARCHED = "If nothing here uses the scope you need, ask what the thing you're watching " \
                   "is called instead of guessing.".freeze

      # Spelling out how to read an empty vs non-empty `matches`, because the
      # failure this tool exists to fix is the model deciding for itself that
      # something isn't wired.
      SEARCHED = "`matches` is what mentions what you searched for: if it has anything in it, " \
                 "that thing IS watchable and its listener shows you the scope and keys to build " \
                 "on - say yes and build the watch. Only an EMPTY `matches` means nothing here " \
                 "knows about it, and then say that plainly and ask what it's called.".freeze

      DESCRIPTION = <<~TXT.freeze
        The Jil listener syntax, an index of every kind of event that fires
        here, and the listeners already running on this person's automations as
        worked examples.

        Two jobs:

        1. **Finding out whether something is watchable at all.** Pass `about`
           with what they described - "doorbell", "front door", "camera",
           "printer", "kennel" - and you get back the real automations whose
           name, description or listener mentions it. Far more than app data
           fires through here: house sensors, buttons, cameras, doorbells and
           anything else an integration posts in all arrive as Jil triggers, and
           none of it is listed anywhere else you can see. **So call this before
           telling anyone you can't watch something.** "I don't have a doorbell
           watch to hook into" was wrong - there are three.
        2. **Writing the listener once you know it's there.** A listener naming
           a key the payload doesn't have parses fine and then never fires, and
           they'd have no way to know, so copy key paths from a real example on
           the same scope instead of guessing. Call this before every
           `remind_when` with trigger="custom".

        `scope` pulls one kind of event's examples to the front when you already
        know which you want ("item" for lists, "hass-sensor" for house sensors).
        Both arguments are optional - null for the whole picture.
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
              about: {
                type:        [:string, :null],
                description: "What they described, in their words (\"doorbell\", \"front door camera\"). " \
                             "Searches automation names, descriptions and listeners. Null to skip the search.",
              },
              scope: {
                type:        [:string, :null],
                description: "Jil scope to pull examples for (e.g. \"item\", \"hass-sensor\"). Null for all.",
              },
            },
            required:             [:about, :scope],
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
        args  = {} unless args.is_a?(Hash)
        scope = (args["scope"] || args[:scope]).to_s.strip.presence
        about = (args["about"] || args[:about]).to_s.strip.presence
        rows  = candidates

        JSON.generate({
          syntax:   guide,
          scopes:   scope_index(rows),
          matches:  (matches(rows, about) if about),
          examples: examples(rows, scope),
          next:     next_step(about),
        }.compact)
      rescue StandardError => e
        Buddy::Errors.report(
          section:   "gpt.listener_tool",
          exception: e,
          user:      @user,
          extra:     { conversation_id: @conversation&.id },
        )
        JSON.generate(error: "couldn't read the listener guide")
      end

      private

      def guide
        File.read(GUIDE_PATH)
      rescue StandardError
        "Listener syntax: scope:key:value, whitespace-separated terms all match, " \
        "values are case-insensitive substrings, /regex/ and ANY(a b) supported."
      end

      # Every listening task the person can reach. Function tasks are dropped -
      # their "listener" is a type signature, not an event pattern.
      def candidates
        rows = @user.accessible_tasks.active.enabled.where.not(listener: [nil, ""])
        rows.select(:id, :name, :listener, :description).to_a
          .reject { |t| t.listener.to_s.match?(/\Afunction\(/i) }
      end

      # What kinds of event fire here at all, and how much is already listening
      # to each. This is the only place the integration-fed scopes show up -
      # `hass-sensor` and friends exist because Home Assistant posts them, so
      # nothing in the app declares them and no other context section can name
      # them. Without this the model can only search for scopes it's already
      # heard of.
      def scope_index(rows)
        rows.filter_map { |t| ::Jil::ListenerMatch.scope_of(t.listener) }
          .tally
          .sort_by { |scope, count| [-count, scope] }
          .to_h
      end

      # Automations whose name, description or listener mentions what they
      # described. The bridge between "the doorbell" and `hass-sensor:location:
      # doorbell` - a scope name alone is unguessable from the outside.
      def matches(rows, about)
        needles = about.downcase.scan(/[a-z0-9]+/).reject { |w| STOPWORDS.include?(w) }
        return [] if needles.empty?

        scored = rows.filter_map { |t|
          haystack = "#{t.name} #{t.description} #{t.listener}".downcase
          hits     = needles.count { |n| haystack.include?(n) }
          [hits, t] if hits.positive?
        }
        scored.sort_by { |hits, t| [-hits, t.name.to_s] }.first(MAX_MATCHES).map { |_, t| describe(t) }
      end

      # Real listeners off the person's own tasks. A task's description says
      # what it's for, which is what makes an example readable rather than a
      # string of colons.
      def examples(rows, scope)
        prioritize(rows, scope).first(MAX_EXAMPLES).map { |t| describe(t) }
      end

      def describe(task)
        { listener: task.listener, does: task.description.presence || task.name }
      end

      # Same-scope listeners first: they're the ones whose key paths transfer.
      def prioritize(rows, scope)
        return rows if scope.blank?

        wanted = scope.to_s.downcase
        rows.partition { |t| ::Jil::ListenerMatch.scope_of(t.listener) == wanted }.flatten
      end

      def next_step(about)
        "#{COPY_KEYS} #{about.blank? ? UNSEARCHED : SEARCHED}"
      end
    end
  end
end
