# == Schema Information
#
# Table name: jarvis_caches
#
#  id         :bigint           not null, primary key
#  data       :jsonb
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  user_id    :bigint
#
class JarvisCache < ApplicationRecord
  belongs_to :user
end
