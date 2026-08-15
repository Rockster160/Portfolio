module Buddy
  # Tapbacks — the small gesture that answers something without being a reply.
  # A 👍 on "dinner's ready", a ❤️ on the answer that came back, a 😂 on
  # something Byte said.
  #
  # ANY message can take one: what the other person relayed, what you sent, what
  # Buddy replied, a tool receipt, an action card. Reacting to Buddy is a note
  # to yourself as much as anything — it needs no answer, and it deliberately
  # gets none. This writes metadata and broadcasts; it never enters
  # ByteMessageIntake or GPT::Turn, so nothing runs a turn off the back of it.
  # The model can't see one either: Buddy::GPT::History reads named keys
  # (`buddy_action`, `buddy_mood`, `kind`) and never the whole envelope.
  #
  # A RELAYED message is the one case that exists TWICE (see
  # CompanionRelay#bridge!): the recipient's copy in their thread and the
  # sender's record in theirs. A reaction is one act by one person and has to be
  # visible to both of them, so it is written to BOTH rows and each owner is
  # broadcast their own. The two are linked by `metadata["relay_twin"]`, a plain
  # message id — set at bridge time going forward, backfilled for the ones
  # already sent. Everything else has no twin and simply doesn't take that path.
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

      def of(message)
        list = message.metadata.to_h["reactions"]
        list.is_a?(Array) ? list : []
      end

      # Add, swap or remove this person's reaction, and return the resulting
      # list. One reaction per person per message: tapping the same one again
      # takes it off, tapping a different one replaces it.
      def react!(message:, user:, emoji:)
        raise ArgumentError, "#{emoji} isn't something you can react with" unless allowed?(emoji, user: user)

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

        detail = { by: user.id, name: user.first_name, value: emoji.to_s, added: added }
        broadcast(message, detail)
        if added
          # Only on ADD. Taking one back off isn't reaching for it.
          user.remember_byte_reaction!(emoji)
          notify(twin, user, emoji) if twin
        end
        broadcast(twin, detail) if twin
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

      # `update: true` says this message ALREADY ARRIVED and only its metadata
      # moved. The client repaints the bubble and stops there — no unread count,
      # no "new message" notice, no re-triggering the pet's mood off an old
      # reply, no popping that old bubble back up on the kiosk. Nothing was
      # said; something was marked.
      #
      # `reaction` is who did it and what with, so the client can raise a notice
      # naming them instead of diffing the list against its own cached copy. The
      # reactor's own copy carries it too and they filter themselves out — one
      # payload, one rule, rather than two shapes to keep in step.
      def broadcast(message, detail)
        message.reload
        push_reaction(message.user, message.as_wire, detail)
        # A SHARED message is one row on two screens (ByteMessageShare), so the
        # reaction is already on the other person's copy the moment it's
        # written — there is nothing to mirror, only someone to tell. Addressed
        # to THEIR thread, since the client routes by the conversation a frame
        # names and this row names its home.
        message.byte_message_shares.includes(:user).find_each { |share|
          wire = message.as_wire(conversation_id: share.byte_conversation_id)
          push_reaction(share.user, wire, detail)
        }
      end

      def push_reaction(user, wire, detail)
        MonitorChannel.broadcast_to(user, {
          id:      :byte,
          channel: :byte,
          data:    {
            kind:     :message,
            message:  wire,
            update:   true,
            reaction: detail,
          },
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
          # The CURRENT unread total, which a reaction doesn't change — so the
          # home-screen badge is left exactly as it was. Sent rather than
          # omitted because `byte_worker.js` reads a missing count as zero and
          # CLEARS the badge, which would wipe real unread messages off the icon
          # every time somebody left a 👍.
          data:  { count: ByteConversation.unread_total_for(twin.user) },
        )
      rescue StandardError => e
        Buddy::Errors.report(section: "reactions.notify", exception: e, user: twin.user)
      end
    end
  end
end
