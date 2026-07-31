module Buddy
  module GPT
    # Hands Buddy the listener syntax reference, plus every listener already
    # running on the person's own tasks.
    #
    # The examples are the point. The syntax doc explains the shape, but what
    # stops a listener from parsing cleanly and then never firing is using a key
    # that doesn't exist in that scope's payload - and the only reliable source
    # for real key paths is listeners that are already working. Seventy-odd of
    # them sit on `accessible_tasks`.
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

      DESCRIPTION = <<~TXT.freeze
        Read the Jil listener syntax, plus the listeners already running on this
        person's own automations as worked examples.

        Call this BEFORE writing a custom watch (`remind_when` with
        trigger="custom"), every time. A listener that names a key the payload
        doesn't have parses fine and then never fires, and they'd have no way to
        know - so guessing at the shape is the one thing you must not do. Their
        existing tasks are the reliable source for what a scope's payload
        actually contains.

        Pass `scope` when you already know which kind of event you're after
        ("item" for lists, "chore_completion", "email") to get that scope's
        examples first. Leave it null for the whole picture.
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
              scope: {
                type:        [:string, :null],
                description: "Jil scope to pull examples for (e.g. \"item\", \"chore_completion\"). Null for all.",
              },
            },
            required:             [:scope],
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
        scope = args.is_a?(Hash) ? (args["scope"] || args[:scope]).presence : nil

        JSON.generate({
          syntax:   guide,
          examples: examples(scope),
          next:     "Copy the key paths from an example on the same scope rather than " \
                    "inventing them. If nothing here uses the scope you need, say so and " \
                    "ask what the thing you're watching is called, instead of guessing.",
        })
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

      # Real listeners off the person's own tasks: `{ listener, does }`. A task's
      # description says what it's for, which is what makes an example readable
      # rather than a string of colons.
      def examples(scope)
        rows = @user.accessible_tasks.active.enabled.where.not(listener: [nil, ""])
        rows = rows.select(:id, :name, :listener, :description).to_a
        rows = rows.reject { |t| t.listener.to_s.match?(/\Afunction\(/i) }

        rows = prioritize(rows, scope)
        rows.first(MAX_EXAMPLES).map { |t|
          { listener: t.listener, does: t.description.presence || t.name }
        }
      end

      # Same-scope listeners first: they're the ones whose key paths transfer.
      def prioritize(rows, scope)
        return rows if scope.blank?

        wanted = scope.to_s.downcase
        rows.partition { |t| ::Jil::ListenerMatch.scope_of(t.listener) == wanted }.flatten
      end
    end
  end
end
