module Buddy
  module GPT
    # A request sent again word for word is a retry: whatever came back the
    # first time didn't settle it. Left in, the earlier answers are the closest
    # worked example there is, and the reply copies them - the same "I need a
    # place for that" in the same words, however the tool it was missing has
    # changed since.
    #
    # From the first copy on, the earlier copies go and so does every reply that
    # only talked - no buttons, nothing run. What the person said in between
    # stays, because what they added is still true; so do notifications and
    # replies that did something, which are part of the thread whatever happens
    # to this request.
    module RetriedRequest
      module_function

      # Short enough to be "again" or "yes", which repeat without being retries.
      MIN_LENGTH = 20
      ACTED_KEYS = ["buttons", "action_request_id", "tool_name"].freeze
      TALK_SOURCES = ["", "deferred_skipped"].freeze

      def without_old_answers(rows, upto)
        return rows unless upto&.direction == "outbound"

        asked = comparable(upto.body)
        return rows if asked.length < MIN_LENGTH

        first = rows.index { |msg| msg.id != upto.id && msg.direction == "outbound" && comparable(msg.body) == asked }
        return rows if first.nil?

        rows.each_with_index.reject { |msg, i|
          next false if i < first || msg.id == upto.id

          msg.direction == "outbound" ? comparable(msg.body) == asked : only_talked?(msg)
        }.map(&:first)
      end

      def comparable(body)
        body.to_s.squish.downcase
      end

      def only_talked?(message)
        meta = message.metadata.is_a?(Hash) ? message.metadata : {}
        return false unless History::PROSE_KINDS.include?(meta["kind"].to_s)
        return false unless TALK_SOURCES.include?(meta["source"].to_s)

        ACTED_KEYS.none? { |key| meta[key].present? }
      end
    end
  end
end
