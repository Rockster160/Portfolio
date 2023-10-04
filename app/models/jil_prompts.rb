# == Schema Information
#
# Table name: jil_prompts
#
#  id          :bigint           not null, primary key
#  answer_type :integer
#  options     :jsonb
#  params      :jsonb
#  question    :text
#  response    :jsonb
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  task_id     :bigint
#  user_id     :bigint
#
class JilPrompts < ApplicationRecord
  belongs_to :user
  belongs_to :task, class_name: "JarvisTask"

  enum answer_type: {
    single: 0,
    many:   1,
  }
end
