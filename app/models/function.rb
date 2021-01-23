# == Schema Information
#
# Table name: functions
#
#  id               :integer          not null, primary key
#  arguments        :text
#  deploy_begin_at  :datetime
#  deploy_finish_at :datetime
#  description      :text
#  proposed_code    :text
#  results          :text
#  title            :text
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#

class Function < ApplicationRecord
end
