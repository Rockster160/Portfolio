# == Schema Information
#
# Table name: lists
#
#  id                 :integer          not null, primary key
#  description        :text
#  icon               :string
#  icon_color         :string
#  icon_png           :binary
#  important          :boolean          default(FALSE)
#  name               :string(255)
#  parameterized_name :text
#  show_deleted       :boolean
#  created_at         :datetime
#  updated_at         :datetime
#
FactoryBot.define do
  factory :list do
    sequence(:name) { |n| "List #{n}" }
    description { "A test list." }
    important { false }
    show_deleted { false }

    transient do
      user { nil }
    end

    after(:create) do |list, evaluator|
      FactoryBot.create(:user_list, user: evaluator.user, list: list) if evaluator.user
    end
  end
end
