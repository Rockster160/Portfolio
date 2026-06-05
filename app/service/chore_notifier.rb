# Web Push for the Chores PWA. Wraps WebPushNotifications.send_to to
# enforce per-user opt-out (User#wants_chore_notification?) and a single
# routing target — every entry point is a class method named for the
# event, so adding a kind is "add a method + a CHORE_NOTIFY_KINDS entry".
class ChoreNotifier
  ICON = "/favicon/android-chrome-192x192.png".freeze

  def self.transfer_received!(transfer)
    return if transfer.from_user_id == transfer.to_user_id

    push(transfer.to_user, :transfer_received, {
      title: "+#{transfer.amount_pebbles}p from #{transfer.from_user&.username}",
      body:  transfer.note.presence || "Transfer received",
      tag:   "chore-transfer-#{transfer.id}",
      data:  { url: "/chores/balance" },
    })
  end

  def self.goal_achieved!(goal)
    push(goal.user, :own_goal_achieved, {
      title: "Goal complete: #{goal.name}",
      body:  goal.awarded_pebbles.to_i.positive? ? "+#{goal.awarded_pebbles}p" : "",
      tag:   "chore-goal-#{goal.id}",
      data:  { url: "/chores/balance" },
    })
    household_peers(goal.user).each do |peer|
      push(peer, :other_goal_achieved, {
        title: "#{goal.user.username} hit a goal",
        body:  goal.name,
        tag:   "chore-goal-#{goal.id}-peer-#{peer.id}",
        data:  { url: "/chores/balance" },
      })
    end
  end

  def self.chore_assigned!(chore, actor:)
    assignee_id = chore.assigned_to_user_id
    return if assignee_id.blank?
    return if actor.present? && assignee_id == actor.id

    assignee = User.find_by(id: assignee_id)
    actor_label = actor&.username.presence || "Someone"
    push(assignee, :chore_assigned, {
      title: "#{actor_label} assigned you a chore",
      body:  chore.display_short_name,
      tag:   "chore-assigned-#{chore.id}",
      data:  { url: "/chores/today" },
    })
  end

  def self.household_peers(user)
    return User.none if user.chore_household_id.blank?

    User.where(chore_household_id: user.chore_household_id).where.not(id: user.id)
  end

  def self.push(user, kind, payload)
    return if user.blank?
    return unless user.wants_chore_notification?(kind)

    payload = payload.merge(icon: ICON).compact_blank
    WebPushNotifications.send_to(user, payload, channel: :chores)
  end
end
