# == Schema Information
#
# Table name: agenda_notification_settings
#
#  id                       :bigint           not null, primary key
#  notify_event_oneoff      :boolean          default(TRUE), not null
#  notify_event_recurring   :boolean          default(TRUE), not null
#  notify_task_oneoff       :boolean          default(TRUE), not null
#  notify_task_recurring    :boolean          default(TRUE), not null
#  notify_trigger_oneoff    :boolean          default(FALSE), not null
#  notify_trigger_recurring :boolean          default(FALSE), not null
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#  agenda_id                :bigint           not null
#  user_id                  :bigint           not null
#
class AgendaNotificationSetting < ApplicationRecord
  belongs_to :user
  belongs_to :agenda

  validates :user_id, uniqueness: { scope: :agenda_id }

  # 2-axis defaults: kind × recurrence. Tasks + events on for both
  # recurrence types; triggers off (the trigger worker already fires the
  # underlying Jil/Jarvis action, so push is opt-in).
  DEFAULTS = {
    task_oneoff:        true,
    task_recurring:     true,
    event_oneoff:       true,
    event_recurring:    true,
    trigger_oneoff:     false,
    trigger_recurring:  false,
  }.freeze

  PERMITTED_KINDS = %w[task event trigger].freeze

  # Fetch the (user, agenda) row if persisted, otherwise return a
  # synthetic-defaults instance (NOT saved). Callers can call
  # `.notify_for?(item)` uniformly without checking presence.
  def self.for(user, agenda)
    return new(user: user, agenda: agenda) if user.blank? || agenda.blank?

    find_by(user_id: user.id, agenda_id: agenda.id) ||
      new(user: user, agenda: agenda)
  end

  # Pass the full item so we can branch on both kind AND .recurring? — the
  # user can mute "recurring events" while keeping "one-off events" on.
  def notify_for?(item)
    return false unless PERMITTED_KINDS.include?(item.kind.to_s)

    attr = "notify_#{item.kind}_#{item.recurring? ? 'recurring' : 'oneoff'}"
    public_send(attr)
  end

  after_initialize do
    DEFAULTS.each do |key, default|
      attr = "notify_#{key}"
      self[attr] = default if self[attr].nil?
    end
  end
end
