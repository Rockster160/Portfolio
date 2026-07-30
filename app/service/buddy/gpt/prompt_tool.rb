module Buddy
  module GPT
    # Opens one of the app's pending Prompts the way the page opens it, so Buddy
    # can see the real fields instead of the skeleton stored on the row.
    #
    # A ROUND-TRIP tool, like ContextTool: the output goes back to the model,
    # which then either fills the gaps from what the person said and calls
    # `answer_prompt`, or asks about them in prose. Deliberately NOT in
    # Buddy::Tools — Turn treats every registry tool as a checklist row, and
    # reading a form should never put a checkbox in front of anyone.
    class PromptTool
      NAME = :read_prompt

      DESCRIPTION = <<~TXT.freeze
        Open one of the app's pending prompts and see its real fields - every
        question, its type, its choices, and whatever value it already loads
        with. Call this BEFORE answer_prompt, always: several prompts build
        their fields when they're opened, so the question list you saw in
        `pending_prompts` can be incomplete or stale, and answer_prompt will
        refuse a field it doesn't recognise.

        Pass the prompt's `id`. Leave it null if they have only one pending and
        they just said "that prompt" or "the survey".
      TXT

      # What to do with what came back. Lives on the output rather than in the
      # description because it's about the STATE of this particular form.
      GUIDANCE = <<~TXT.freeze
        Fill this in and send it. They get the whole form, editable, before
        anything is submitted - so a wrong guess costs them one tap to fix, and
        stopping to ask costs them a whole extra exchange. Guess.

        1. `needs_value` is empty. Fill each from what they told you, from the
        prompt's own title, or from a reasonable inference. Only leave one blank
        if you genuinely have nothing to go on - a survey of 0-100 mood scales
        wants their real numbers, not invented ones.

        2. `defaulted` holds a value the FORM supplied rather than one they gave
        you. Read each and correct any that doesn't match what they said - a
        computed Duration is wrong if they told you it was quick. Having a value
        is not the same as being correct.

        3. TIMESTAMPS are not on that list on purpose. When? / Timestamp /
        Started records when the thing actually happened and is already right.
        Leave it alone unless they specifically give you a different time.

        Then call answer_prompt with `answers` keyed by these exact question
        texts. Do NOT ask about gaps first - the form is the ask. If something
        is a genuine coin flip, say so in your reply and let them fix it in the
        field.
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
              id: {
                type:        [:integer, :null],
                description: "Prompt id from pending_prompts. Null picks the only pending one.",
              },
            },
            required:             [:id],
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
        prompt = resolve(args)
        return JSON.generate(prompt) if prompt.is_a?(Hash) # an error or a pick-one list

        form = Buddy::PromptForm.hydrate(prompt, user: @user)
        return JSON.generate(unanswerable(prompt)) unless form.answerable?

        JSON.generate({
          id:          prompt.id,
          title:       form.title,
          fields:      form.fields,
          needs_value: form.needs_value,
          defaulted:   form.defaulted,
          next:        GUIDANCE.strip.gsub(/\s*\n\s*\n\s*/, " ").gsub(/\s+/, " "),
        })
      rescue StandardError => e
        Buddy::Errors.report(
          section:   "gpt.prompt_tool",
          exception: e,
          user:      @user,
          extra:     { conversation_id: @conversation.id },
        )
        JSON.generate({ error: "couldn't open that prompt" })
      end

      private

      def resolve(args)
        id = args.is_a?(Hash) ? (args["id"] || args[:id]) : nil
        return find(id) if id.present?

        pending = @user.prompts.unanswered.order(created_at: :desc).limit(10).to_a
        return { error: "nothing pending right now" } if pending.empty?
        return pending.first if pending.one?

        {
          choose: pending.map { |p| { id: p.id, title: p.question } },
          next:   "More than one is pending. Ask which they mean, or call read_prompt again with the id.",
        }
      end

      def find(id)
        @user.prompts.unanswered.find_by(id: id) ||
          { error: "no pending prompt ##{id} - it may already be answered" }
      end

      def unanswerable(prompt)
        {
          id:    prompt.id,
          title: prompt.question,
          error: "this one has no fillable fields - tell them to open it in the app",
        }
      end
    end
  end
end
