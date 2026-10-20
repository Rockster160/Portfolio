module Buddy
  # The face a board's pet is HOLDING — a condition that is true right now and
  # shows until it stops being true: Whisper asleep or gone, a standing alert
  # that names a face (the laundry gate's "up to no good" look). The board's own
  # hero layers these over the mood client-side (see buddy/hero.js holds); this
  # is the same answer worked out on the server, so a board opens already
  # wearing it and the index card shows it, instead of both painting the mood
  # until the browser has caught up.
  #
  # Every face that wants the pet carries a strength (Buddy::FaceStrength), the
  # mood included, and the strongest shows - the same rule as the hero's.
  # Whisper's state outranks an alert's face by default, an alert's outranks a
  # real mood, and a dream's shows only over an idle one, unless the alert or
  # dream was raised with a strength of its own.
  module BoardFace
    module_function

    WHISPER_CHANNEL = :"whisper-durations"
    WHISPER_CACHE = :board_whisper
    WHISPER_FACES = { asleep: :sleeping, gone: :hiding }.freeze
    DREAM_FACE = :thinking

    # What the board's pet should show: the strongest face wanting it, mood
    # included.
    def for(board)
      showing(board) || board.buddy_expression
    end

    # The strongest standing condition's face (Whisper's state or an alert's),
    # whatever the mood.
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

    # [face, strength] for Whisper's state or the strongest alert naming a face.
    # Whisper wins a tie: it's the board's own subject.
    def held_want(board)
      whisper = whisper_face(board)
      wants = whisper ? [[whisper, Buddy::FaceStrength::WHISPER]] : []
      aimed_alerts(board).each { |alert|
        wants << [alert.expression, alert.strength] if !alert.dream? && alert.expression.present?
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
      return [dream.expression || DREAM_FACE.to_s, dream.strength] if dream

      [DREAM_FACE.to_s, Buddy::FaceStrength::DREAM] if chore_dream
    end

    def aimed_alerts(board)
      Buddy::Alerts.outstanding(board.user).select { |a| overlap?(a.groups, board.chore_tags) }
    end

    # Whisper's state as this board should wear it, or nil when the feed isn't
    # aimed at a group the board watches. The feed's last status lives on its
    # owner, which is also the only owner whose boards it may land on.
    def whisper_state(board)
      cached = board.user.caches.get(WHISPER_CACHE).to_h.with_indifferent_access
      return unless overlap?(cached[:groups], board.chore_tags)

      parse_whisper_status(cached[:status])
    end

    def whisper_face(board)
      WHISPER_FACES[whisper_state(board)]&.to_s
    end

    # Mirrors whisperState in buddy/durations.js — the status is the sentence the
    # Whisper task broadcasts ("Napping 💤", "Gone 👋").
    def parse_whisper_status(status)
      text = status.to_s.downcase
      return :gone if text.include?("gone")
      return :asleep if text.match?(/sleep|nap/)
      return :awake if text.include?("awake")

      nil
    end

    # The Whisper feed broadcast. Keeps the last status and groups (a broadcast
    # may carry either alone) and, when the state actually moved, tells every
    # board of this owner's what it should now be wearing.
    def record_whisper!(owner, payload)
      return if owner.nil?

      payload = payload.to_h.with_indifferent_access
      return unless payload.key?(:status) || payload.key?(:groups)

      before = owner.caches.get(WHISPER_CACHE).to_h.with_indifferent_access
      after = before.merge(payload.slice(:status, :groups))
      return if after == before

      owner.caches.set(WHISPER_CACHE, after.to_h)
      broadcast!(owner)
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
