# == Schema Information
#
# Table name: users
#
#  id                 :integer          not null, primary key
#  buddy_features     :jsonb            not null
#  byte_prefs         :jsonb            not null
#  chore_notify_prefs :jsonb            not null
#  dark_mode          :boolean
#  email              :string
#  hot_links          :jsonb            not null
#  invitation_token   :string
#  password_digest    :string
#  phone              :string
#  role               :integer          default("standard")
#  username           :string
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  chore_household_id :bigint
#
FactoryBot.define do
  factory :user do
    sequence(:email) { |n| "user#{n}@example.com" }
    sequence(:username) { |n| "user#{n}" }
    password { "password123" }
    password_confirmation { "password123" }
    role { :standard }
    # Its own band. The old `555%07d` started at 5550000001 and walked straight
    # through the numbers specs hand-write for a second user (5550000999,
    # 5550001000, 5550009999...), so the suite carried a landmine: adding
    # factory users anywhere eventually marched the counter onto a literal and
    # failed an unrelated spec on "Phone has already been taken". Nothing
    # hardcodes a 5551 number, and nothing asserts on a generated one.
    sequence(:phone) { |n| "5551%06d" % n }
    dark_mode { false }
  end
end
