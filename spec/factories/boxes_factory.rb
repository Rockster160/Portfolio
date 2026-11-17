# == Schema Information
#
# Table name: boxes
#
#  id             :bigint           not null
#  data           :jsonb            not null
#  description    :text
#  empty          :boolean          default(TRUE), not null
#  hierarchy      :text
#  hierarchy_data :jsonb            not null
#  hierarchy_ids  :jsonb            not null
#  name           :text             not null
#  notes          :text
#  param_key      :text             primary key
#  parent_key     :text
#  sort_order     :integer          not null
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#  user_id        :bigint           not null
#
FactoryBot.define do
  factory :box do
    user
    sequence(:name) { |n| "Box #{n}" }
  end
end
