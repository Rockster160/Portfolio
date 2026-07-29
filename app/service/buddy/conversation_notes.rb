module Buddy
  # Small, per-conversation notes block Buddy manages itself via `[[note:]]`.
  # These are thread-scoped preferences/context ("keep this convo strictly
  # work", "they're prepping for a talk") — NOT durable global facts, which go
  # to BuddyMemory via `[[remember:]]`. Stored as newline-joined lines on
  # byte_conversations.buddy_memories.
  module ConversationNotes
    module_function

    # Keep the block small — it rides in the system prompt every turn. When it
    # grows past the cap we drop the OLDEST lines (compact) rather than reject
    # the new one, so the freshest thread context always survives.
    MAX_CHARS = 2_000

    def append(conversation, text)
      line = text.to_s.strip
      return if line.empty?

      lines = existing_lines(conversation)
      lines << line
      lines = compact(lines)

      conversation.update_column(:buddy_memories, lines.join("\n"))
    end

    def existing_lines(conversation)
      conversation.buddy_memories.to_s.split("\n").map(&:strip).reject(&:empty?)
    end

    # Drop oldest lines until the joined block fits under the cap. Always keeps
    # at least the most recent line, even if it alone exceeds the cap.
    def compact(lines)
      lines = lines.dup
      lines.shift while lines.size > 1 && lines.join("\n").length > MAX_CHARS
      lines
    end
  end
end
