# Fans out chore-change signals over MonitorChannel so all other devices
# refresh. We don't pack the full state here — clients re-fetch from
# their endpoint when they see the signal land.
class ChoreBroadcaster
  def self.broadcast_changes!(user, chore = nil, **opts)
    return if user.blank?

    # Default fanout: actor + everyone in their household (symmetric on
    # ChoreShare, so one row reaches both sides).
    recipient_ids = Chore.household_user_ids_for(user.id)

    if chore
      # `:assigned` chores: only the assignee + creator should hear about
      # changes — nobody else in the share group can see the chore.
      if chore.respond_to?(:share_assigned?) && chore.share_assigned?
        recipient_ids = [chore.assigned_to_user_id, chore.created_by_user_id].compact.uniq
      else
        # Anyone in the chore-creator's household can see this chore, so
        # signal all of them (not just the actor's household — the creator
        # may belong to a different pair than the actor).
        recipient_ids = Chore.household_user_ids_for(chore.created_by_user_id)
      end
    end

    recipients = User.where(id: recipient_ids).to_a

    payload = {
      id: :chores,
      channel: :chores,
      timestamp: Time.current.to_i,
      data: {
        chore_id: chore&.id,
        actor_user_id: user.id,
        actor_tab_id: opts[:actor_tab_id],
        server_ts: Time.current.iso8601(3),
      },
    }

    recipients.each do |r|
      MonitorChannel.broadcast_to(r, payload)
    end
  end
end
