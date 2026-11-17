# `/q <question>`: a quick Claude session on the Mini, for answering a question
# or putting data right with a production script. It runs read-only in the
# Portfolio checkout itself, with no worktree or branch to cut, so it's up as
# fast as the session is. A change that needs code is handed on as a `/feature`
# once its owner says yes (`bin/feature-build`).
#
# It's a FeatureBuild like any other, so the thread hears from it the same way:
# each turn's answer arrives as a plain message, and a reply to any message
# about it goes into the session. It never opens a PR and never asks for a
# review, so it isn't counted as waiting on anyone. One that has gone a while
# without a reply is closed by the daily sweep (QuickCloseWorker), and the
# Claude page can close one at any time.
module FeatureBuilder
  module Quick
    module_function

    USAGE = "usage: `/q WHAT TO ASK OR FIX`".freeze

    # The thread it was asked in, as far back as this, is handed over with it.
    CONTEXT = 30
    # How far up a chain of replies it follows from the message replied to.
    CHAIN = 10
    EXCERPT = 600

    # A session nobody has replied to for this long is closed.
    IDLE_AFTER = 6.hours
    IDLE_REASON = "no reply in 6 hours.".freeze

    # Returns the request as the person's own message, the way `/feature` does.
    # `reply_to_id` is the message the command was typed as a reply to.
    def start!(
      user:,
      conversation:,
      text:,
      typed: nil,
      local_id: nil,
      reply_to_id: nil,
      attachment_signed_ids: [])
      question = text.to_s.strip
      return FeatureBuilder.say(conversation, USAGE) if question.empty?

      replied = reply_to_id.present? ? conversation.byte_messages.find_by(id: reply_to_id) : nil
      posted = nil
      FeatureBuilder.launch!(
        user:                  user,
        conversation:          conversation,
        request:               brief(conversation, question, replied),
        title_from:            question,
        kind:                  :quick,
        attachment_signed_ids: attachment_signed_ids,
      ) { |build|
        said = typed.presence || "/q #{question}"
        posted = FeatureBuilder.post_request!(build, conversation, said, { local_id: local_id }.compact)
      }
      posted
    end

    def brief(conversation, question, replied=nil)
      chain = replied ? reply_chain(replied) : []
      thread = (
        if chain.any?
          "It was typed as a reply to this, oldest first:\n\n#{lines(chain)}\n\n"
        else
          ""
        end
      )
      <<~TXT
        Quick request: #{question}

        #{thread}The last #{CONTEXT} messages in the thread it was asked in (**#{conversation.display_name}**, conversation #{conversation.id}), oldest first, ids in brackets. Anything further back, or in other threads, is in production's `byte_messages`:

        #{lines(context(conversation))}
      TXT
    end

    # The thread's last messages before now, without the house's hidden seeds.
    def context(conversation)
      scope = conversation.byte_messages.not_hidden.order(created_at: :desc)
      scope.includes(:user).limit(CONTEXT).to_a.reverse
    end

    # The message replied to, and the ones it replied to in turn.
    def reply_chain(message)
      chain = [message]
      while chain.length < CHAIN
        id = message.metadata.to_h.dig("reply_to", "id")
        message = id.present? ? message.byte_conversation.byte_messages.find_by(id: id) : nil
        break if message.nil? || chain.include?(message)

        chain.unshift(message)
      end
      chain
    end

    def lines(messages)
      zone = messages.first&.user&.timezone
      messages.map { |message|
        at = message.created_at.in_time_zone(zone).strftime("%-m/%-d %-I:%M %p")
        "- [#{message.id}] #{at} #{author(message)}: #{message.body.to_s.squish.truncate(EXCERPT)}"
      }.join("\n")
    end

    def author(message)
      return message.user&.first_name.presence || "They" if message.outbound?

      message.byte_conversation.buddy_name
    end

    # ---- closing the quiet ones ----

    # The last time its owner said anything to it: the request, or a reply to
    # one of its messages.
    def last_heard_at(build)
      scope = ByteMessage.outbound.where("byte_messages.metadata->>'feature_build_id' = ?", build.id.to_s)
      [scope.maximum(:created_at), build.created_at].compact.max
    end

    # Every open `/q` its owner hasn't replied to for IDLE_AFTER. Returns the
    # ones it closed.
    def close_idle!(now: Time.current)
      FeatureBuild.kind_quick.unfinished.select { |build|
        last_heard_at(build) < now - IDLE_AFTER && FeatureBuilder.cancel!(build, reason: IDLE_REASON)
      }
    end
  end
end
