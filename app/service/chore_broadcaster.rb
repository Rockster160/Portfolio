# Fans out chore-change signals over MonitorChannel so all other devices
# refresh. We don't pack the full state here — clients re-fetch from
# their endpoint when they see the signal land.
class ChoreBroadcaster
  def self.broadcast_changes!(user, chore = nil, **opts)
    return if user.blank?

    recipients = [user]
    recipients.concat(ChoreShare.where(user_id: user.id).includes(:shared_with_user).map(&:shared_with_user))
    if chore
      # `:assigned` chores: only the assignee + creator should hear about
      # changes — nobody else in the share group can see the chore.
      if chore.respond_to?(:share_assigned?) && chore.share_assigned?
        recipients = [User.find_by(id: chore.assigned_to_user_id)].compact
        recipients << User.find_by(id: chore.created_by_user_id) if chore.created_by_user_id != chore.assigned_to_user_id
      else
        owner_user = User.find_by(id: chore.created_by_user_id)
        recipients << owner_user if owner_user
        ChoreShare.where(user_id: chore.created_by_user_id).each do |share|
          recipients << share.shared_with_user
        end
      end
    end

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

    recipients.compact.uniq.each do |r|
      MonitorChannel.broadcast_to(r, payload)
    end
  end
end
