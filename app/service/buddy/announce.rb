module Buddy
  # Tell somebody in the house something, in their own companion's voice, from
  # the console.
  #
  #     Buddy::Announce.call(:chels, "The reminders panel can edit recurrence now")
  #
  # Prints a draft, then asks. `s` sends it, `r` regenerates, `n` regenerates
  # with an extra note ("shorter", "mention it's opt-in"), `q` walks away.
  #
  # This exists because the alternative is writing the message yourself and
  # pasting it in, which arrives in a voice that isn't the one that person's
  # companion has been using all week. Suki telling Eve about a new feature
  # should sound like Suki. The briefing is what you know; the draft is how that
  # companion would say it.
  #
  # Nothing is sent until you say so, and a regenerate costs one model call.
  #
  # `say` is the other door, for when you already have the words:
  #
  #     Buddy::Announce.say(:chels, "Heads up, the server's down for an hour")
  #
  # No model, no draft, no confirming - it goes straight into the thread.
  module Announce
    module_function

    # Who you can reach, by whatever you'd actually type. `me` and `rocco` are
    # the same person; `mom` is Eve, because that's what she gets called.
    WHO = {
      me:           1,
      rocco:        1,
      chels:        58_128,
      chelsea:      58_128,
      alchemibluum: 58_128,
      eve:          4,
      mom:          4,
    }.freeze

    MAX_WORDS = 90

    def call(who, briefing, io: $stdout, input: $stdin)
      user, convo = target(who, io: io)
      return if user.nil?

      pet = ByteConversation.display_name_for(convo.buddy_theme.presence || Buddy::Themes::DEFAULT)
      io.puts("\n#{pet} → #{user.first_name}")

      notes = []
      loop do
        draft = generate(user, convo, briefing, notes, io: io)
        return io.puts("Nothing to send.") if draft.blank?

        io.puts("\n#{"─" * 60}\n#{draft}\n#{"─" * 60}")
        io.print("[s]end  [r]egenerate  [n]ote+regenerate  [q]uit > ")
        answer = input.gets.to_s.strip.downcase

        case answer
        when "s", "send", "y", "yes"
          message = deliver!(user, convo, draft)
          return io.puts("Sent to #{user.first_name}. (message ##{message.id})")
        when "n", "note"
          io.print("What should change? > ")
          note = input.gets.to_s.strip
          notes << note if note.present?
        when "q", "quit", "c", "cancel", ""
          return io.puts("Cancelled. Nothing sent.")
        end
        # "r" and anything unrecognised fall through and regenerate, which is
        # the harmless option to land on when you fat-finger the prompt.
      end
    end

    # Straight into their thread, word for word, no model in the middle.
    #
    # It still arrives under their companion's name, because that name is the
    # only voice that thread has - so a line written flat lands as something
    # Suki said flatly. Worth a beat on the wording, or use `call` and let her
    # say it herself.
    def say(who, text, io: $stdout)
      body = text.to_s.strip
      return io.puts("Nothing to send.") if body.blank?

      user, convo = target(who, io: io)
      return if user.nil?

      message = deliver!(user, convo, body)
      io.puts("Sent to #{user.first_name}. (message ##{message.id})")
      message
    end

    # Both doors need the same two things, and have the same nothing to offer
    # when either one is missing.
    def target(who, io: $stdout)
      user = resolve(who)
      if user.nil?
        io.puts("Don't know who #{who.inspect} is. Try: #{WHO.keys.join(", ")}")
        return nil
      end

      convo = conversation_for(user)
      if convo.nil?
        io.puts("#{user.first_name} has no Buddy conversation to write into.")
        return nil
      end

      [user, convo]
    end

    def resolve(who)
      id = WHO[who.to_s.downcase.to_sym]
      return ::User.find_by(id: id) if id

      # A bare username or first name also works — there's no reason to make
      # somebody look up the symbol for a person they can name.
      ::User.find_by(username: who.to_s) ||
        ::User.all.detect { |u| u.first_name.to_s.casecmp(who.to_s).zero? }
    end

    # Their newest Buddy thread, which is the one they're actually reading. A
    # notification into an archived thread is a notification nobody sees, and
    # one onto the wall tablet is one only the kitchen sees.
    def conversation_for(user)
      ByteConversation.for_self_initiated(user) || ByteConversation.default_for(user)
    end

    def generate(user, convo, briefing, notes, io: $stdout)
      io.puts("  …writing#{" (#{notes.length} note#{"s" if notes.length > 1})" if notes.any?}")
      result = Buddy::GPT::Client.new.stream(
        instructions: Buddy::Personality.for(user, conversation: convo),
        input:        [{ role: :user, content: [{ type: :input_text, text: seed(user, briefing, notes) }] }],
      )
      return nil unless result[:ok]

      # Strip the mood marker — this goes out as a plain message, and the face
      # isn't moving for it.
      result[:text].to_s.gsub(/\[\[mood:[^\]]+\]\]/, "").strip
    rescue StandardError => e
      io.puts("  model call failed: #{e.class}: #{e.message}")
      nil
    end

    def seed(user, briefing, notes)
      extra = notes.any? ? "\n\nRevise it: #{notes.join("; ")}." : ""
      <<~SEED.strip
        [nothing was said to you - this is an announcement the app is asking you to pass on, and your reply IS the message #{user.first_name} will read]

        Tell them about this, in your own voice, as though you'd just noticed it and thought they'd want to know:

        #{briefing.to_s.strip}

        Keep it under #{MAX_WORDS} words. No preamble about being asked to say this, no sign-off, no bullet list unless there are genuinely several separate things. Say what it is and why they'd care. Don't call any tools.#{extra}
      SEED
    end

    def deliver!(user, convo, text)
      Buddy::CompanionDelivery.deliver_plain(
        user:         user,
        conversation: convo,
        text:         text,
        metadata:     { "kind" => "buddy", "source" => "announce" },
        push_title:   text,
      )
    end
  end
end
