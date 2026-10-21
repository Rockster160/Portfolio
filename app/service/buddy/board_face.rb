module Buddy
  # The face a board's pet is HOLDING — a condition that is true right now and
  # shows until it stops being true: a standing alert that names a face or a
  # mood (the laundry gate's "up to no good" look), or a mood a task holds with
  # no words at all. The board's own hero layers these over the mood
  # client-side (see buddy/hero.js holds); this is the same answer worked out on
  # the server, so a board opens already wearing it and the index card shows
  # it, instead of both painting the mood until the browser has caught up.
  #
  # Every face that wants the pet carries a strength (Buddy::FaceStrength), the
  # mood included, and the strongest shows - the same rule as the hero's. An
  # alert's outranks a real mood, and a dream's shows only over an idle one,
  # unless the alert or dream was raised with a strength of its own.
  module BoardFace
    module_function

    DREAM_FACE = :thinking

    # What the board's pet should show: the strongest face wanting it, mood
    # included.
    def for(board)
      showing(board) || board.buddy_expression
    end

    # The strongest standing condition's face, whatever the mood.
    def held(board)
      held_want(board)&.first
    end

    # The face that beats the mood, or nil when the mood is the strongest.
    # `chore_dream` is a hot chore the board itself is dreaming of (see
    # Buddy::BoardDream), which only the board's own page knows.
    def showing(board, chore_dream: false)
      top = [held_want(board), dream_want(board, chore_dream:)].compact.max_by(&:last)
      return nil if top.nil? || top.last < Buddy::FaceStrength.mood(board.buddy_expression)

      top.first
    end

    def idle?(expression)
      expression.blank? || expression.to_s == Buddy::Faces.default.to_s
    end

    # The face of the dream this board shows: the newest one aimed at it, else
    # thinking over a hot chore it is dreaming of.
    def dream_face(board, chore_dream: false)
      dream_want(board, chore_dream:)&.first
    end

    # [face, strength] for the strongest standing alert with a look. The one
    # standing longest wins a tie.
    def held_want(board)
      wants = aimed_alerts(board).filter_map { |alert|
        face = alert.face_for(board.buddy_theme) unless alert.dream?
        [face, alert.strength] if face.present?
      }
      wants.max_by.with_index { |(_, strength), i| [strength, -i] }
    end

    # [face, strength] for the dream the board shows. One raised before the pet
    # was last tapped has been put away (see Buddy::Pat).
    def dream_want(board, chore_dream: false)
      dismissed = board.dream_dismissed_at
      dream = Buddy::Alerts.dreams(board.user).find { |a|
        overlap?(a.groups, board.chore_tags) && (dismissed.nil? || a.last_raised_at > dismissed)
      }
      if dream
        # A dream that asks for a look gets it, or nothing on a pet without it;
        # one that asks for none thinks.
        asks = dream.mood || dream.expression
        face = asks ? dream.face_for(board.buddy_theme) : DREAM_FACE.to_s
        return face && [face, dream.strength]
      end

      [DREAM_FACE.to_s, Buddy::FaceStrength::DREAM] if chore_dream
    end

    def aimed_alerts(board)
      Buddy::Alerts.outstanding(board.user).select { |a| overlap?(a.groups, board.chore_tags) }
    end

    # Tell everyone who can see this owner's boards what each is holding now.
    # The index cards follow this; the board itself works it out live.
    def broadcast!(owner)
      ::ByteConversation.active.buddy.board.where(user_id: owner.id).find_each do |board|
        held  = held_want(board)
        dream = dream_want(board)
        data  = {
          kind:            :board_face,
          conversation_id: board.id,
          expression:      held&.first,
          strength:        held&.last,
          dream:           dream&.first,
          dream_strength:  dream&.last,
        }
        viewers = board.shared? ? owner.chore_household_user_ids : [owner.id]
        ::User.where(id: viewers).find_each do |viewer|
          ::MonitorChannel.broadcast_to(viewer, { id: :byte, channel: :byte, data: data })
        end
      end
    rescue StandardError => e
      Rails.logger.warn("[Buddy] board face broadcast failed: #{e.class}: #{e.message}")
    end

    # Any shared group, case-insensitive, like groupsOverlap in board_scope.js. A
    # feed's groups may arrive as a list or a comma string.
    def overlap?(groups, tags)
      groups = groups.split(",") if groups.is_a?(String)
      groups = Array(groups).map { |g| g.to_s.strip.downcase }
      tags = Array(tags).map { |t| t.to_s.downcase }
      groups.intersect?(tags)
    end
  end
end
