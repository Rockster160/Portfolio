FactoryBot.define do
  factory :user do
    sequence(:email) { |n| "user#{n}@example.com" }
    sequence(:username) { |n| "user#{n}" }
    password { "password123" }
    password_confirmation { "password123" }
    role { :standard }
    sequence(:phone) { |n| "555%07d" % n }
    dark_mode { false }
  end
end
