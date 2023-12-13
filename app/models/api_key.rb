# == Schema Information
#
# Table name: api_keys
#
#  id         :bigint           not null, primary key
#  key        :text
#  name       :text
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  user_id    :bigint
#
class ApiKey < ApplicationRecord
  belongs_to :user

  after_initialize { self.key ||= SecureRandom.hex.upcase }
end
