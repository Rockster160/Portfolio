module Buddy
  # Replying to ONE message in the thread, instead of to whatever was said last.
  #
  # Two different things wear the same gesture, and which one it is depends
  # entirely on what was long-pressed:
  #
  #   a relayed message - the reply goes to the PERSON it came from, verbatim,
  #                       through Buddy::CompanionRelay. Buddy is not asked and
  #                       does not answer; it was never the one talking.
  #   anything else     - an ordinary turn, with the quoted message named in
  #                       history so Buddy answers THAT rather than the last
  #                       thing on screen.
  #
  # Either way the reply is one row carrying a `reply_to` block - the id, an
  # excerpt, who said it. Stamped at send time rather than resolved on read,
  # because the excerpt has to outlive a compaction that drops the message it
  # points at, and because history is rebuilt from these rows every turn: a
  # lookup per quoted message would be a query per turn.
  module ThreadReply
    module_function

    EXCERPT_LIMIT = 140

    # The message being replied to, or nil. Scoped to the thread the reply was
    # typed in - the id comes from the client, and nothing may quote a message
    # out of a conversation the person isn't in. A shared photo counts: it is
    # one row shown in two threads, and it is genuinely on screen here.
    def target(conversation, id)
      return nil if conversation.nil? || id.blank?

      conversation.byte_messages.find_by(id: id) || conversation.shared_messages.find_by(id: id)
    end

    # The durable quote block that rides on the reply.
    def quote(message)
      { "id" => message.id, "excerpt" => excerpt(message), "author" => author(message), "role" => role(message) }
    end

    # The relay this message belongs to, when replying to it means replying to a
    # PERSON. Nil for anything else, which is the ordinary-turn path.
    #
    # `relay_id` is stamped by CompanionRelay#bridge!, so messages bridged before
    # that existed answer nil and fall through to a normal reply. That's the
    # honest outcome: without the row there is nobody to send it to, and guessing
    # the peer from a household of two would be right until the day it wasn't.
    def relay_for(user, message)
      return nil unless metadata(message)["kind"].to_s == "buddy_relay"

      relay = BuddyRelay.find_by(id: metadata(message)["relay_id"])
      return nil if relay.nil? || [relay.from_user_id, relay.to_user_id].exclude?(user.id)

      relay
    end

    def peer_for(relay, user)
      relay.from_user_id == user.id ? relay.to_user : relay.from_user
    end

    # Send the typed reply back across. An open question they were asked gets
    # ANSWERED - that closes the relay, hands the answer to the asker, and lets
    # any sequence parked on it carry on - and anything else is a fresh note to
    # the same person.
    #
    # `from_message:` is the row they already typed, so their own words appear
    # once, on their own side of the thread, wearing the attribution that says
    # where they went.
    def send_back!(user:, message:, relay:)
      text = message.body.to_s
      return Buddy::CompanionRelay.record_answer!(relay, text, from_message: message) if answerable?(relay, user)

      Buddy::CompanionRelay.pass_along!(
        from:         user,
        to:           peer_for(relay, user),
        text:         text,
        from_message: message,
      )
    end

    def answerable?(relay, user)
      relay.delivered? && relay.question? && relay.to_user_id == user.id
    end

    def excerpt(message)
      # Icon references become their names. A quote is a reminder of what was
      # said, and "[hicon:24] again?" is the reminder arriving as source code.
      text = ::IconPool.refs_to_text(message.body.to_s, user: message.user).squish
      return text.truncate(EXCERPT_LIMIT) if text.present?

      message.files.attached? ? "a picture" : ""
    end

    # Whose words these were, as the quote chip says it.
    def author(message)
      case source(message)
      when "relay_copy" then "You"
      when "relay"      then metadata(message).dig("relay_peer", "name").presence || "them"
      else
        message.direction == "outbound" ? "You" : message.byte_conversation.buddy_name
      end
    end

    # What History phrases the quote as. Kept apart from `author` because the
    # name and the relationship answer different questions - a relay you SENT is
    # authored by "You" and is still a relay.
    def role(message)
      case source(message)
      when "relay_copy" then :relay_out
      when "relay"      then :relay_in
      else
        message.direction == "outbound" ? :self : :buddy
      end.to_s
    end

    def source(message)
      return nil unless metadata(message)["kind"].to_s == "buddy_relay"

      metadata(message)["source"].to_s
    end

    def metadata(message)
      message.metadata.is_a?(Hash) ? message.metadata : {}
    end
  end
end
