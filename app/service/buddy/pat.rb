module Buddy
  # Somebody tapped the pet. It flashes something fun (Faces::TAPPED) for a
  # moment, its mood eases a little lighter underneath, and on a board whatever
  # dream it was showing is put away until the next draw or a newer dream.
  #
  # The lighter mood is a nudge of the reading the current face stands for,
  # kept beside it so taps in a row add up: the first one off neutral rarely
  # changes the face, a few more land somewhere happier. Once anything else
  # moves the mood, the kept reading no longer matches and the next tap starts
  # from the new face.
  module Pat
    module_function

    LIGHT = { warmth: 0.85, play: 0.6, weight: 0.15, strain: 0.0 }.freeze
    PULL = 0.2
    READING = "pat_reading".freeze

    # { expression:, flash:, dream_dismissed_at: } as broadcast to every screen
    # showing the conversation.
    def call(conversation, at: Time.current)
      theme = conversation.buddy_theme
      mood = lighter(conversation)
      meta = conversation.metadata.to_h
      meta = meta.merge(READING => mood && { "face" => mood[:face].to_s, "reading" => mood[:reading] })
      meta = meta.merge("dream_dismissed_at" => at.iso8601(3)) if conversation.board?
      conversation.update!(metadata: meta)
      ::Buddy::ExpressionState.set(conversation, mood[:face]) if mood && mood[:face].to_s != conversation.buddy_expression.to_s

      result = {
        expression:         conversation.buddy_expression.to_s,
        flash:              (::Buddy::Faces::TAPPED & ::Buddy::Faces.selectable(theme)).sample&.to_s,
        dream_dismissed_at: conversation.dream_dismissed_at&.iso8601(3),
      }
      broadcast(conversation, result)
      result
    end

    # The face a little lighter than the current one, and the reading it was
    # chosen from. Nil when the pet is wearing something that isn't a mood
    # (asleep), which a tap doesn't talk it out of.
    def lighter(conversation)
      theme = conversation.buddy_theme
      current = conversation.buddy_expression.presence || ::Buddy::Faces.default
      kept = conversation.metadata.to_h[READING].to_h
      reading = kept["reading"].to_h.symbolize_keys if kept["face"].to_s == current.to_s
      reading ||= ::Buddy::Faces.profile(current, theme)&.slice(*::Buddy::Faces::AXES)
      return nil if reading.blank?

      lighter = ::Buddy::Faces::AXES.to_h { |axis|
        value = reading[axis].to_f
        [axis, (value + ((LIGHT[axis] - value) * PULL)).round(3)]
      }
      skip = ::Buddy::Faces::IRRITATED + ::Buddy::Faces::TENDER
      face = ::Buddy::Faces.nearest(theme, lighter, skip:)
      face && { face:, reading: lighter }
    end

    # Everyone who can see the conversation: a shared board's whole household,
    # else its owner.
    def broadcast(conversation, result)
      owner = conversation.user
      viewers = conversation.board? && conversation.shared? ? owner.chore_household_user_ids : [owner.id]
      data = { kind: :buddy_pat, conversation_id: conversation.id, **result }
      ::User.where(id: viewers).find_each do |viewer|
        ::MonitorChannel.broadcast_to(viewer, { id: :byte, channel: :byte, data: })
      end
    rescue StandardError => e
      Rails.logger.warn("[Buddy] pat broadcast failed: #{e.class}: #{e.message}")
    end
  end
end
