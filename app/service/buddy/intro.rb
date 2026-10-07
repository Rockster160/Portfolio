module Buddy
  # The first thing a companion says in a thread nobody has spoken in yet.
  #
  # An empty thread with a name on it tells somebody nothing about what to ask
  # for. The pet is the only thing on screen that knows what it can do, so it
  # says so once, on the way in, instead of waiting to be guessed at.
  #
  # Built the same way as the Today briefing: a hidden `buddy_trigger` seed
  # that the ordinary turn answers. That is what makes it the PET talking -
  # persona, tone profile and the Floor all apply, so Byte introduces itself as
  # Byte - rather than a canned paragraph that would have to be written five
  # times and would drift from the voice the moment either changed.
  #
  # The ground it may cover is Buddy::Features, per person. Offering somebody
  # the calendar when they do not hold `agenda` is a promise the tool layer
  # then refuses, and a first impression is the worst place to make one.
  module Intro
    module_function

    SOURCE = "new_conversation".freeze

    # Never withheld (Buddy::Features::CORE), so it is named here rather than
    # being derived from a list that deliberately leaves it out.
    ALWAYS = "timers and alarms, reminders and nudges, remembering things they tell you " \
             "so they do not have to, holding a thought for later, and the weather".freeze

    def seed(user)
      <<~TXT.strip
        [nothing was said to you - this thread was just opened and nobody has spoken in it]

        Introduce yourself.

        Somebody has a new, empty thread in front of them. They may have never met you, or they may just want a fresh start. Either way the useful thing is the same: who you are, and what they can hand over to you.

        #{ground_for(user)}

        Whatever else: #{ALWAYS}.

        How it should land:

        - This is you saying hello, so it is prose and it is short. No headings, no bulleted list of features, no manual. Somebody who wanted a feature list would be reading a settings page.
        - Group the ground above the way a person would say it out loud rather than itemizing it. They are getting a feel for what you are for, not an inventory they have to finish.
        - Nothing outside that ground. Offering something they do not have is a promise that gets refused the first time they take you up on it.
        - Open with a greeting, in your own words, matching the part of day.
        - Hand it back at the end - an opening for them to say what they need, in whatever way your own voice does that.
        - No tools and nothing looked up. You have not been asked anything yet, and reading their day at somebody who has just said nothing is a briefing nobody wanted.
      TXT
    end

    # What this person actually holds, in the words Buddy::Features already
    # uses to tell the model what is switched off - so the two halves of
    # "what can you do" are never phrased differently.
    def ground_for(user)
      held = ::Buddy::Features.enabled_for(user).map { |feature| ::Buddy::Features.label_for(feature) }
      return "You have no feature areas switched on for this person, so speak only to what follows." if held.empty?

      "What this person has switched on, and the only ground you may offer: #{held.to_sentence}."
    end

    # Post the seed and let the ordinary turn answer it. Returns the seed, or
    # nil when there is nothing to introduce - a thread somebody has already
    # spoken in is not a new one, whatever route got us here.
    def start!(conversation)
      return nil unless conversation&.buddy?
      return nil if conversation.byte_messages.exists?

      seed_message = conversation.byte_messages.create!(
        user:      conversation.user,
        direction: :outbound,
        state:     :pending,
        body:      seed(conversation.user),
        metadata:  { kind: :buddy_trigger, hidden: true, source: SOURCE, buddy_action: :intro },
      )
      # The seed is hidden, so without this the thread sits blank until the
      # round trip finishes and there is nothing on screen saying it is coming.
      ::Buddy::ExpressionState.transition!(conversation, :turn_started)
      ::BuddyDeliverWorker.perform_async(seed_message.id)
      seed_message
    end
  end
end
