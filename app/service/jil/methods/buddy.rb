class Jil::Methods::Buddy < Jil::Methods::Base
  def cast(value)
    @jil.cast(value, :String)
  end

  # [Buddy]
  #   #say(Text)::Boolean
  #   #prompt(Text)::Boolean

  # Byte/Moss says the text verbatim — a fixed inbound message dropped into the
  # user's Buddy conversation, plus a push. Use when the wording is yours and
  # should land exactly as written.
  def say(message)
    text = message.to_s.strip
    return false if text.empty?

    conversation = ::Buddy::CompanionRelay.conversation_for(@jil.user)
    ::Buddy::CompanionDelivery.deliver_plain(
      user:         @jil.user,
      conversation: conversation,
      text:         text,
      metadata:     { kind: "buddy", source: "jil" },
      push_title:   text,
    )
    true
  end

  # Re-dispatches a fresh in-character Buddy turn seeded by the text, so the
  # reply reads like Byte/Moss talking rather than a canned string. `buddy_trigger`
  # is what marks the resulting reply self-initiated (see Buddy::GPT::Turn), so it
  # pushes even when the app is foregrounded.
  def prompt(seed)
    text = seed.to_s.strip
    return false if text.empty?

    conversation = ::Buddy::CompanionRelay.conversation_for(@jil.user)
    ::Buddy::CompanionDelivery.deliver_prompt(
      user:         @jil.user,
      conversation: conversation,
      seed:         text,
      metadata:     { kind: "buddy_trigger", hidden: true, source: "jil" },
    )
    true
  end
end
