# == Schema Information
#
# Table name: jil_trigger_shapes
#
#  id              :bigint           not null, primary key
#  keys            :jsonb            not null
#  last_seen_at    :datetime
#  observed_values :jsonb            not null
#  sample          :jsonb            not null
#  scope           :text             not null
#  seen_count      :integer          default(0), not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  user_id         :bigint           not null
#
class JilTriggerShape < ApplicationRecord
  belongs_to :user

  validates :scope, presence: true

  scope :ordered, -> { order(Arel.sql("last_seen_at DESC NULLS LAST")) }

  # Scopes whose payload shape is worth reporting. Everything on the bus gets
  # observed, but a scope nobody can write a watch against is noise in a prompt.
  def interesting?
    keys.present?
  end
end
