module Buddy
  # The face a board's pet is HOLDING — a condition that is true right now and
  # shows until it stops being true: Whisper asleep or gone, a standing alert
  # that names a face (the laundry gate's "up to no good" look). The board's own
  # hero layers these over the mood client-side (see buddy/hero.js holds); this
  # is the same answer worked out on the server, so a board opens already
  # wearing it and the index card shows it, instead of both painting the mood
  # until the browser has caught up.
  #
  # Priority matches the hero's HOLD_PRIORITY: Whisper's state over an alert's.
  # A dream's face is the weakest of all: it shows only while the pet would
  # otherwise be resting on its idle face.
  module BoardFace
    module_function

    WHISPER_CHANNEL = :"whisper-durations"
    WHISPER_CACHE = :board_whisper
    WHISPER_FACES = { asleep: :sleeping, gone: :hiding }.freeze
    DREAM_FACE = :thinking

    # What the board's pet should show: the held face, else a dream's over an
    # idle mood, else its mood.
    def for(board)
      showing(board) || board.buddy_expression
    end

    def held(board)
      whisper_face(board) || alert_face(board)
    end

    # The held face, or a dream's when nothing is held and the mood is idle.
    # `chore_dream` is a hot chore the board itself is dreaming of (see
    # Buddy::BoardDream), which only the board's own page knows.
    def showing(board, chore_dream: false)
      held(board) || (idle?(board.buddy_expression) ? dream_face(board, chore_dream:) : nil)
    end

    def idle?(expression)
      expression.blank? || expression.to_s == Buddy::Faces.default.to_s
    end

    # The face of the dream this board shows: the newest one aimed at it, else
    # thinking over a hot chore it is dreaming of.
    def dream_face(board, chore_dream: false)
      dream = Buddy::Alerts.dreams(board.user).find { |a| overlap?(a.groups, board.chore_tags) }
      return dream.expression || DREAM_FACE.to_s if dream

      DREAM_FACE.to_s if chore_dream
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

    # The first standing alert aimed at this board that names a face — the one
    # the board's bubble opens on.
    def alert_face(board)
      alert = Buddy::Alerts.outstanding(board.user).find { |a|
        !a.dream? && a.expression.present? && overlap?(a.groups, board.chore_tags)
      }
      alert&.expression
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
        data = {
          kind:            :board_face,
          conversation_id: board.id,
          expression:      held(board),
          dream:           dream_face(board),
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
