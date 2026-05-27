# == Schema Information
#
# Table name: agenda_preferences
#
#  id                :bigint           not null, primary key
#  hidden_agenda_ids :jsonb            not null
#  hide_completed    :jsonb            not null
#  hide_tentative    :boolean          default(FALSE), not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  user_id           :bigint           not null
#
class AgendaPreference < ApplicationRecord
  KIND_KEYS = %w[task event trigger].freeze

  belongs_to :user

  validates :user_id, uniqueness: true

  def self.for(user)
    find_or_initialize_by(user: user).tap { |pref|
      pref.hide_completed ||= {}
      pref.hidden_agenda_ids ||= []
    }
  end

  def hidden_agenda_ids=(value)
    super(Array(value).map(&:to_i).uniq)
  end

  def hide_completed_for?(kind)
    !!hide_completed[kind.to_s]
  end

  def hide_completed=(value)
    cleaned = (value || {}).to_h.slice(*KIND_KEYS).transform_values { |v| !!v }
    super(cleaned)
  end

  def serialize_for_client
    {
      hidden_agenda_ids: hidden_agenda_ids.map(&:to_i),
      hide_completed:    KIND_KEYS.index_with { |k| hide_completed_for?(k) },
      hide_tentative:    !!hide_tentative,
    }
  end

  # Push the latest snapshot to every connected client for this user, so a
  # filter change on phone is reflected on laptop immediately. Reuses the
  # `:agenda` channel — clients already listen for that and re-apply filters
  # on any payload that carries `preferences`.
  def broadcast!
    MonitorChannel.broadcast_to(user, {
      id:        :agenda,
      channel:   :agenda,
      timestamp: Time.current.to_i,
      data:      { preferences: serialize_for_client },
    })
  end
end
