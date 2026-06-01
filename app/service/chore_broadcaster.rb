# Fans out chore-change signals over MonitorChannel so all other devices
# refresh. We don't pack the full state here — clients re-fetch from
# their endpoint when they see the signal land.
class ChoreBroadcaster
  def self.broadcast_changes!(user, chore=nil, **opts)
    return if user.blank?

    # Default fanout: actor + everyone in their household (symmetric on
    # ChoreShare, so one row reaches both sides).
    recipient_ids = Chore.household_user_ids_for(user.id)

    if chore
      # Personal + assigned: only the assignee + creator can see the chore,
      # so nobody else needs the signal. Everything else (personal w/o
      # assignee, household w/ or w/o assignee) is grid-visible to the
      # full household and gets the broadcast.
      if chore.respond_to?(:assigned?) && chore.assigned? && chore.share_personal?
        recipient_ids = [chore.assigned_to_user_id, chore.created_by_user_id].compact.uniq
      else
        recipient_ids = Chore.household_user_ids_for(chore.created_by_user_id)
      end
    end

    recipients = User.where(id: recipient_ids).to_a

    payload = {
      id:        :chores,
      channel:   :chores,
      timestamp: Time.current.to_i,
      data:      {
        chore_id:      chore&.id,
        actor_user_id: user.id,
        actor_tab_id:  opts[:actor_tab_id],
        server_ts:     Time.current.iso8601(3),
      },
    }

    recipients.each do |r|
      MonitorChannel.broadcast_to(r, payload)
    end
  end
end
