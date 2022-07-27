# == Schema Information
#
# Table name: banned_ips
#
#  id          :bigint           not null, primary key
#  ip          :inet
#  whitelisted :boolean          default(FALSE)
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#
class BannedIp < ApplicationRecord
end
