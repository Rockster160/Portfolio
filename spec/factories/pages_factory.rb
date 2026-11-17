# == Schema Information
#
# Table name: pages
#
#  id                 :bigint           not null, primary key
#  content            :text
#  name               :string
#  parameterized_name :text
#  short_key          :text
#  sort_order         :integer
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  folder_id          :bigint
#  user_id            :bigint           not null
#
FactoryBot.define do
  factory :page do
    sequence(:name) { |n| "Page #{n}" }
    content { "hello" }
    user
  end
end
