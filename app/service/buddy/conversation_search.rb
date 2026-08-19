module Buddy
  # Search back through what was actually SAID, across one thread or all of a
  # person's threads.
  #
  # Distinct from Buddy::MemorySearch, which searches what Buddy chose to keep.
  # This searches the transcript itself, for the case where nothing was kept
  # because at the time it wasn't worth keeping: "I told you I need to pick my
  # cousins up from the airport — what day was that?", "what was I talking to
  # Moss about earlier?"
  #
  # Plain ILIKE, deliberately. There is no pg_trgm or tsvector on this database
  # (only uuid-ossp and pg_stat_statements), the table is small, and
  # `index_byte_messages_on_user_id_and_created_at` already covers the shape of
  # every query here. Adding an extension for a few thousand rows would be a
  # migration and an operational dependency bought for nothing.
  module ConversationSearch
    module_function

    LIMIT = 15

    # How much of each hit to hand back. Enough to answer from without pulling
    # the whole thread into the turn.
    SNIPPET = 240

    # Kinds that are not somebody talking: the hidden prompt behind a quick
    # action, the receipt chip that renders one, a watch firing on its own.
    # Searching these is how "what did I say about the airport" comes back with
    # quick-action seeds nobody wrote.
    SKIP_KINDS = %w[action_chip buddy_activity buddy_trigger].freeze

    # `scope: :thread` for this conversation only, `:all` for every Buddy thread
    # this person has. Never anyone else's — the user filter is applied to
    # byte_conversations rather than byte_messages because a bridged relay
    # message can carry a partner's words while belonging to this person's
    # thread, and the owner of the THREAD is what decides whose it is.
    def call(user:, query:, conversation: nil, scope: :thread, limit: LIMIT, days: nil)
      words = query.to_s.split(/\s+/).map(&:strip).compact_blank
      return { messages: [], total: 0 } if words.empty?

      rows = base_scope(user, conversation, scope)
      rows = rows.where(byte_messages: { created_at: days.to_i.days.ago.. }) if days.to_i.positive?
      rows = words.reduce(rows) { |acc, word|
        acc.where("byte_messages.body ILIKE ?", "%#{sanitize_like(word)}%")
      }

      found = rows.order(created_at: :desc).limit(limit * 3).to_a.reject { |m| skip?(m) }
      { messages: found.first(limit), total: found.size }
    end

    def base_scope(user, conversation, scope)
      threads = ByteConversation.where(user_id: user.id, mode: :buddy)
      threads = threads.where(id: conversation.id) if scope.to_sym == :thread && conversation

      ByteMessage.joins(:byte_conversation).where(byte_conversation_id: threads.select(:id))
    end

    def skip?(message)
      meta = message.metadata.is_a?(Hash) ? message.metadata : {}
      return true if meta["hidden"]
      return true if meta["source"] == "watch"
      return true if SKIP_KINDS.include?(meta["kind"].to_s)

      message.body.to_s.strip.empty?
    end

    def sanitize_like(word)
      word.gsub(/[\\%_]/) { |c| "\\#{c}" }
    end

    # One line per hit: who said it, when, which thread, and the words. The
    # thread's own name matters when searching across all of them — "what was I
    # talking to Moss about" is answered by the thread as much as the text.
    def rows(messages, user, now=Time.current)
      names = thread_names(messages)
      messages.map { |m|
        who = m.direction == "outbound" ? user.first_name : names.dig(m.byte_conversation_id, :pet)
        when_ = ago(m.created_at, now)
        "[#{when_}, #{names.dig(m.byte_conversation_id, :name)}] #{who}: #{m.body.to_s.strip.truncate(SNIPPET)}"
      }
    end

    def thread_names(messages)
      ids = messages.map(&:byte_conversation_id).uniq
      # Keyed by id, not by record — `index_with` would key on the
      # ByteConversation itself and every lookup by id would miss silently,
      # leaving the thread name blank instead of raising.
      ByteConversation.where(id: ids).to_h { |c|
        [c.id, { name: c.name.presence || "thread ##{c.id}", pet: c.buddy_name }]
      }
    end

    def ago(at, now)
      days = (now.to_date - at.to_date).to_i
      case days
      when ..0   then at.strftime("today %-I:%M %p")
      when 1     then at.strftime("yesterday %-I:%M %p")
      when 2..13 then "#{days}d ago"
      when 14..60 then "#{days / 7}w ago"
      else at.strftime("%b %-d")
      end
    end
  end
end
