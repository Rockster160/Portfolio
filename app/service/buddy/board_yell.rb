module Buddy
  # A yell on a board: the pet shouting something in its thought bubble,
  # flipping between playful and surprised, the same as it does for a very high
  # item on the board's list - only set straight on a board BY NAME, with no
  # list behind it.
  #
  # It lives on the board itself (`metadata.yells`, keyed by the caller's key)
  # rather than on anyone's alerts, so every screen showing the board shows it,
  # whoever is signed in there. It stands until a `resolve!` on its key, its
  # `minutes` running out, or somebody tapping the pet (see Buddy::Pat).
  module BoardYell
    module_function

    KEY = "yells".freeze
    ALL = "all".freeze
    SOUNDS = %i[chime alarm nap wake birthday].freeze

    # The boards `name` points at among the ones `user` may open: the one so
    # named (case aside), or every one of them for "all". Blank names none.
    def boards_for(user, name)
      name = name.to_s.strip.downcase
      return [] if name.empty?

      boards = ::ByteConversation.accessible_boards_for(user).to_a
      return boards if name == ALL

      boards.select { |board| board.display_name.to_s.strip.downcase == name }
    end

    # The names `user` can aim a yell at.
    def board_names(user)
      ::ByteConversation.accessible_boards_for(user).map(&:display_name).sort
    end

    # Yells on every board `name` points at. A leading emoji in `body` becomes
    # the icon when no `icon` is given. Saying it again under a standing key
    # replaces its words and starts it over. Returns the boards it reached.
    def yell!(user:, board:, key:, body:, icon: nil, sound: nil, minutes: nil)
      key = key.to_s.strip
      glyph, text = ::Buddy::BoardList.split_glyph(body.to_s.strip)
      return [] if key.empty? || text.blank?

      icon = icon.to_s.strip.presence || glyph
      now = Time.current
      expires_at = now + minutes.to_f.minutes if minutes.to_f.positive?
      entry = {
        "body"       => text,
        "icon"       => icon,
        "sound"      => sound_key(sound),
        "raised_at"  => now.iso8601(3),
        "expires_at" => expires_at&.iso8601(3),
      }.compact

      boards_for(user, board).each do |target|
        write!(target) { |yells| yells.merge(key => entry) }
        BuddyBoardYellExpireWorker.perform_at(expires_at, target.id, key, entry["raised_at"]) if expires_at
      end
    end

    # Stops the yell under `key` on every board `user` may open. Returns the
    # boards it was standing on.
    def resolve!(user:, key:)
      key = key.to_s.strip
      return [] if key.empty?

      standing = ::ByteConversation.accessible_boards_for(user).select { |board| yells(board).key?(key) }
      standing.each do |board|
        clear!(board, key)
      end
    end

    # Stops the yell under `key` on this board, or every yell on it when `key`
    # is nil. `raised_at` stops it only if it is still that same yell, so a
    # timer set for an earlier telling leaves a newer one standing.
    def clear!(board, key=nil, raised_at: nil)
      write!(board) { |yells|
        next {} if key.nil?
        next yells if raised_at && yells.dig(key, "raised_at") != raised_at

        yells.except(key)
      }
    end

    # The standing yells, keyed, with any whose time has run out left off.
    def yells(board)
      now = Time.current
      board.metadata.to_h[KEY].to_h.reject { |_key, yell|
        expires = yell["expires_at"].presence && Time.zone.parse(yell["expires_at"])
        expires && expires <= now
      }
    end

    # Newest first, as the board draws them.
    def wire(board)
      yells(board).map { |key, yell| yell.merge("key" => key) }.sort_by { |yell| yell["raised_at"].to_s }.reverse
    end

    def sound_key(sound)
      sound = sound.to_s.strip.downcase.to_sym
      SOUNDS.include?(sound) ? sound.to_s : nil
    end

    # Rewrites the board's yells under a row lock and tells its screens, only
    # when something changed.
    def write!(board)
      changed = false
      board.with_lock do
        after = yield(yells(board))
        next if after == board.metadata.to_h[KEY].to_h

        meta = board.metadata.to_h
        meta = after.empty? ? meta.except(KEY) : meta.merge(KEY => after)
        board.update!(metadata: meta)
        changed = true
      end
      broadcast!(board) if changed
      board
    end

    # Everyone who can see the board: a shared board's whole household, else
    # its owner.
    def broadcast!(board)
      owner = board.user
      viewers = board.shared? ? owner.chore_household_user_ids : [owner.id]
      data = { kind: :board_yells, conversation_id: board.id, yells: wire(board) }
      ::User.where(id: viewers).find_each do |viewer|
        ::MonitorChannel.broadcast_to(viewer, { id: :byte, channel: :byte, data: data })
      end
    end
  end
end
