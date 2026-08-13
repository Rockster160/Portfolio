module Buddy
  # Tapbacks on a relayed message — the small gesture that answers something
  # without being a reply. A 👍 on "dinner's ready", a ❤️ on the answer that
  # came back.
  #
  # A relayed message exists TWICE (see CompanionRelay#bridge!): the recipient's
  # copy in their thread and the sender's record in theirs. A reaction is one
  # act by one person and has to be visible to both of them, so it is written to
  # BOTH rows and each owner is broadcast their own. The two are linked by
  # `metadata["relay_twin"]`, a plain message id — set at bridge time going
  # forward, backfilled for the ones already sent.
  #
  # Reactions live in the message's jsonb envelope alongside everything else it
  # carries (buttons, action state, peer identity). Nothing ever queries FOR a
  # reaction; it is only ever read as part of the message it sits on.
  module Reactions
    # What the picker row starts as, before anyone has reacted to anything.
    # Replaced one at a time by whatever they actually reach for.
    DEFAULTS = ["👍", "❤️", "😂", "‼️", "❓", "👎"].freeze

    # How many the row shows, and so how many are worth keeping.
    RECENT_LIMIT = 6

    class << self
      # A reaction is an ICON REFERENCE, the same three shapes the picker hands
      # back everywhere else in the app: an emoji character, a `ti-*` class, or
      # `hicon:<id>` for one of the household's own uploads.
      #
      # Validated by asking the pool whether it could have produced this, rather
      # than by a regex guessing at what an emoji looks like. The picker only
      # ever offers a pool row, so anything that fails here was hand-crafted —
      # and it also guarantees `name_for` can always name what it accepted.
      def allowed?(value, user: nil)
        v = value.to_s
        return false if v.blank?
        return household_icon(v, user).present? if v.start_with?("hicon:")

        ::IconPool.known?(v)
      end

      # The six on the picker row: what this person reached for most recently,
      # padded with the defaults until they've used six of their own.
      def recents_for(user)
        (user.byte_reaction_recents + DEFAULTS).uniq.first(RECENT_LIMIT)
      end

      # What to call a reaction where the thing itself can't be shown. An emoji
      # is its own best label; a Tabler icon or an upload only has a name.
      def label_for(value, user: nil)
        v = value.to_s
        return "\"#{household_icon(v, user)&.name}\"" if v.start_with?("hicon:")
        return v unless v.start_with?("ti-")

        "\"#{::IconPool.name_for(v) || v}\""
      end

      # Only messages that passed between two people. Buddy's own replies, tool
      # receipts and action cards are not conversation with anybody.
      def reactable?(message)
        message.is_a?(ByteMessage) && message.metadata.to_h["kind"].to_s == "buddy_relay"
      end

      def of(message)
        list = message.metadata.to_h["reactions"]
        list.is_a?(Array) ? list : []
      end

      # Add, swap or remove this person's reaction, and return the resulting
      # list. One reaction per person per message: tapping the same one again
      # takes it off, tapping a different one replaces it.
      def react!(message:, user:, emoji:)
        raise ArgumentError, "#{emoji} isn't something you can react with" unless allowed?(emoji, user: user)
        raise ArgumentError, "that message can't be reacted to" unless reactable?(message)

        added = false
        list  = nil
        # Both people can tap at the same moment, and the whole array is
        # rewritten each time — without the lock the second write drops the
        # first person's reaction on the floor.
        message.with_lock {
          mine    = of(message).find { |r| r["user_id"] == user.id }
          without = of(message).reject { |r| r["user_id"] == user.id }
          added   = mine.nil? || mine["emoji"] != emoji
          list    = added ? without + [entry(user, emoji)] : without
          write!(message, list)
        }

        twin = twin_of(message)
        # The same array on both copies, so neither side is looking at a
        # different set of reactions from the other.
        twin&.with_lock { write!(twin, list) }

        broadcast(message)
        if added
          # Only on ADD. Taking one back off isn't reaching for it.
          user.remember_byte_reaction!(emoji)
          notify(twin, user, emoji) if twin
        end
        broadcast(twin) if twin
        list
      end

      # The other copy of the same bridged message. Nil for a relay sent before
      # the copies were linked and never backfilled — the reaction still lands
      # on the row in front of the person, it just doesn't reach the other side.
      def twin_of(message)
        id = message.metadata.to_h["relay_twin"]
        return nil if id.blank?

        ByteMessage.find_by(id: id)
      end

      private

      # `hicon:<id>` only resolves inside the household that owns it — which is
      # also the authorization check, since the two people in a relay are
      # household partners and nobody else's uploads are reachable.
      def household_icon(value, user)
        household = user&.chore_household
        return nil if household.nil?

        household.icons.find_by(id: value.delete_prefix("hicon:"))
      end

      def entry(user, emoji)
        {
          "user_id" => user.id,
          "name"    => user.first_name,
          "emoji"   => emoji.to_s,
          "at"      => Time.current.iso8601,
        }
      end

      def write!(message, list)
        message.update!(metadata: message.metadata.to_h.merge("reactions" => list))
      end

      def broadcast(message)
        MonitorChannel.broadcast_to(message.user, {
          id:      :byte,
          channel: :byte,
          data:    { kind: :message, message: message.reload.as_wire },
        })
      end

      # The point of reacting to someone is that they see it. Same rule as the
      # relay itself: nothing goes to the wall.
      def notify(twin, user, emoji)
        return if twin.byte_conversation&.kiosk?
        return if twin.user_id == user.id

        WebPushNotifications.send_to_byte(
          title: "#{user.first_name} reacted #{label_for(emoji, user: user)} to \"#{twin.body.to_s.truncate(80)}\"",
          tag:   "byte-reaction-#{twin.id}-#{Time.current.to_i}",
          users: [twin.user],
        )
      rescue StandardError => e
        Buddy::Errors.report(section: "reactions.notify", exception: e, user: twin.user)
      end
    end
  end
end
