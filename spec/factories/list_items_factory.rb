# == Schema Information
#
# Table name: list_items
#
#  id             :integer          not null, primary key
#  amount         :integer
#  category       :string
#  deleted_at     :datetime
#  formatted_name :text
#  important      :boolean          default(FALSE)
#  name           :text
#  permanent      :boolean          default(FALSE)
#  sort_order     :integer
#  created_at     :datetime
#  updated_at     :datetime
#  list_id        :integer
#  section_id     :bigint
#
FactoryBot.define do
  factory :list_item do
    list
    sequence(:name) { |n| "Item #{n}" }
    important { false }
    permanent { false }
    category { "General" }
    sort_order { 0 }
  end
end
