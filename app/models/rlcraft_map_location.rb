# == Schema Information
#
# Table name: rlcraft_map_locations
#
#  id          :integer          not null, primary key
#  x_coord     :integer
#  y_coord     :integer
#  title       :string
#  type        :string
#  description :string
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#

class RlcraftMapLocation < ApplicationRecord
end
