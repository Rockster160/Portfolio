module Buddy
  # Is a message JUST a hello or a goodbye - the kind of turn the pet opens on
  # with a wave (see the greeting rule in Buddy::Personality) rather than an
  # answer to something? Deliberately tight: it matches a message that is ONLY a
  # greeting, so "hi, add milk to the list" is a request and gets no wave in
  # front of it. The word sets track the openers the persona treats as a bare
  # greeting, plus their farewell mirrors.
  module Greeting
    module_function

    HELLO = %w[
      hi hiya hey heya hello hullo yo sup howdy gday morning afternoon evening
    ].freeze

    # Multi-word openers, matched whole so a stray first word can't trip them.
    HELLO_PHRASES = [
      "good morning",
      "good afternoon",
      "good evening",
      "whats up",
      "what's up",
      "wassup",
      "how are things",
      "hows things",
      "how's things",
      "how are you",
      "how are you doing",
      "hows it going",
      "how's it going",
    ].freeze

    BYE = %w[
      bye goodbye night goodnight cya ciao adios laters later peace farewell
    ].freeze

    BYE_PHRASES = [
      "good night",
      "see you",
      "see ya",
      "see you later",
      "see ya later",
      "talk later",
      "talk soon",
      "ttyl",
      "catch you later",
      "take care",
      "bye bye",
    ].freeze

    # The address that can trail a greeting - "hey there", "hi buddy". Only these
    # and the pet's own name are peeled off, never an arbitrary word, or "hi add"
    # would read as a greeting aimed at "add".
    VOCATIVES = %w[there buddy bud friend mate pal you].freeze

    def bare?(text, name: nil)
      core = normalize(text)
      return false if core.blank?
      return true if greeting?(core) || farewell?(core)

      # Only peel a vocative when the whole thing isn't already a greeting, or
      # "see you" loses its "you" and stops being one.
      stripped = strip_vocative(core, name: name)
      stripped != core && (greeting?(stripped) || farewell?(stripped))
    end

    def greeting?(core)
      HELLO.include?(core) || HELLO_PHRASES.include?(core)
    end

    def farewell?(core)
      BYE.include?(core) || BYE_PHRASES.include?(core)
    end

    # Downcase, collapse inner whitespace, and drop any run of non-letters off
    # each end - so "Hey!!", "hey", and "hey 👋" are one thing. Inner marks (the
    # apostrophe in "what's up", the comma in "hey, there") are left for the
    # phrase sets and the vocative strip to handle.
    def normalize(text)
      text.to_s.downcase.strip.gsub(/\s+/, " ").sub(/\A[^a-z]+/, "").sub(/[^a-z]+\z/, "")
    end

    # Peel one trailing address off the end so the core is just the greeting.
    def strip_vocative(core, name: nil)
      names = (VOCATIVES + [name.to_s.downcase]).compact_blank.uniq
      core.sub(/[,\s]+(?:#{names.map { |n| Regexp.escape(n) }.join("|")})\z/, "").strip
    end
  end
end
