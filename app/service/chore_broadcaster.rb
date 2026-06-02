# Fans out chore-change signals over MonitorChannel so all other devices
# refresh. We don't pack the full state here — clients re-fetch from
# their endpoint when they see the signal land.
class ChoreBroadcaster
  def self.broadcast_changes!(user, chore=nil, **opts)
    return if user.blank?

    recipient_ids = recipients_for(user, chore)
    return if recipient_ids.empty?

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

    User.where(id: recipient_ids).find_each do |r|
      MonitorChannel.broadcast_to(r, payload)
    end
  end

  # Personal-cooldown + assigned narrows visibility to the assignee
  # alone, so the fan-out skips everyone else. Every other shape stays
  # grid-visible to the household.
  def self.recipients_for(user, chore)
    if chore && chore.assigned? && chore.share_personal?
      return [chore.assigned_to_user_id].compact
    end

    household_id = chore&.chore_household_id || user.chore_household_id
    return [user.id] if household_id.nil?

    User.where(chore_household_id: household_id).pluck(:id)
  end
end
