module Buddy
  # Asking WHICH ONE, with the answers already on screen.
  #
  # Before this, a resolver that couldn't tell two records apart raised a
  # sentence, the model read it, and the person got a question in prose - so
  # answering meant typing the name back, and the whole thing cost a second
  # turn to say something the system already knew. Prod 4495 is the cost of NOT
  # asking (Moss marked `Unload Dishwasher` for "Log load dishwasher", the
  # opposite job), and the fix for that was to stop guessing - which turns every
  # near miss into that extra exchange unless the candidates come with it.
  #
  # A tap runs the ORIGINAL call with the chosen record and no model turn at
  # all: the answer was decided the moment they pressed it, and spending a round
  # trip to have the model re-say it costs money and invites a different answer.
  module Disambiguation
    module_function

    TOOL_NAME = "buddy_pick".freeze

    # More than a handful is a list, not a choice, and a resolver offering
    # eight candidates has not narrowed anything down.
    MAX_OPTIONS = 4

    # ONE is a card too. "I couldn't find anything called X - did you mean Y?"
    # with a button under it is a single tap; the same sentence in prose is a
    # whole corrected message they have to type. The button is optional either
    # way - the words still say what happened, so nothing is hidden behind it.
    MIN_OPTIONS = 1

    # Long enough to walk back to the phone and answer. The default
    # ten-minute action TTL is for something a blocked process is waiting on;
    # nothing is waiting on this, and an expired question that silently stops
    # working is worse than one still sitting there an hour later.
    TTL = 6.hours

    # What the MODEL is told once the buttons are up. It must not ask the same
    # question again in prose - that is the extra exchange this exists to
    # remove - and it must not pick one itself.
    ASKED_NOTE = "Several records match and the choice is now in front of them as buttons - " \
                 "they tap one and it runs. Do NOT ask which one, do not list them, and do " \
                 "not call this again with a guess. Say only that you have put the options up.".freeze

    # Returns true when the card went up, false when it couldn't - a turn with
    # no conversation behind it (a routine, an eval sweep) has nowhere to put
    # buttons, and then the sentence is still the best available answer.
    def ask!(user:, conversation:, tool:, payload:, error:)
      options = Array(error.options).first(MAX_OPTIONS)
      return false if conversation.nil? || payload.nil? || options.length < MIN_OPTIONS

      ByteAction.create_request!(
        user:            user,
        conversation:    conversation,
        kind:            :question,
        tool_name:       TOOL_NAME,
        title:           options.length == 1 ? "Did you mean..." : "Which one?",
        # The PERSON'S sentence, never the model's - `error.message` carries
        # instructions for the model about what to call next, which is not
        # something to put on screen.
        body:            error.prompt.to_s,
        buttons:         buttons_for(options),
        # `value` is what the argument wants, and the client posts it back
        # verbatim; everything needed to rebuild the call is here so a tap
        # never has to reconstruct what was being asked for.
        tool_input:      {
          "tool"    => tool[:name].to_s,
          "arg"     => error.arg.to_s,
          "payload" => payload.deep_stringify_keys,
        },
        multi_select:    false,
        timeout_seconds: TTL,
      )
      true
    rescue StandardError => e
      Buddy::Errors.report(section: "disambiguation.ask", exception: e, user: user)
      false
    end

    def buttons_for(options)
      options.each_with_index.map { |option, i|
        {
          "id"          => i + 1,
          "label"       => option[:label].to_s,
          "value"       => option[:value].to_s,
          "description" => option[:description].to_s.presence,
        }.compact
      }
    end

    # They tapped one. Rebuild the call that was being made, with the record
    # they chose in place of the name that matched too many things, and run it
    # the way any other proposal runs.
    def chose!(action, button)
      input   = action.tool_input || {}
      arg     = input["arg"].to_s
      payload = (input["payload"] || {}).merge(arg => button["value"])

      Buddy::ProposalBuilder.reissue(
        user:         action.user,
        conversation: action.byte_conversation,
        button:       { "tool_name" => input["tool"], "payload" => payload },
        body:         "#{button["label"]} it is:",
      )
    end
  end
end
