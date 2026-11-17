# == Schema Information
#
# Table name: sections
#
#  id         :bigint           not null, primary key
#  color      :text             not null
#  name       :text             not null
#  sort_order :integer          not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  list_id    :bigint           not null
#
FactoryBot.define do
  factory :section do
    list
    sequence(:name) { |n| "Section #{n}" }
    color { "#CCCCCC" }
    sort_order { 0 }
  end
end
