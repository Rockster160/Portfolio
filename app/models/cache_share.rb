# == Schema Information
#
# Table name: cache_shares
#
#  id              :bigint           not null, primary key
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  jarvis_cache_id :bigint
#  user_id         :bigint
#
class CacheShare < ApplicationRecord
  belongs_to :jarvis_task
  belongs_to :user
end
