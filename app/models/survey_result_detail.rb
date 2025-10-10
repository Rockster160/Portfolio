# == Schema Information
#
# Table name: survey_result_details
#
#  id               :integer          not null, primary key
#  conditional      :integer
#  description      :text
#  value            :integer
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  survey_id        :integer
#  survey_result_id :integer
#

class SurveyResultDetail < ApplicationRecord
  belongs_to :survey
  belongs_to :survey_result

  enum :conditional, {
    full:          0,
    equal:         1,
    greater:       2,
    lesser:        3,
    greater_equal: 4,
    lesser_equal:  5,
  }
end
