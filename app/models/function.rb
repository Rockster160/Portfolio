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

# deprecated - Delete me when table gets dropped
class Function < ApplicationRecord
  def self.lookup(identifier)
    if identifier.to_s.to_i.to_s == identifier
      find(identifier)
    else
      find_by!(title: identifier)
    end
  end

  def run
    # RunFunction.run(self.id)
  end

  def split_args
    return {} if arguments.blank?

    arguments.split(",").each_with_object({}) { |arg, h|
      arg, default = arg.split("=").map(&:squish)

      h[arg] = default.to_s
    }
  end

  def line_count
    return 0 if proposed_code.blank?

    proposed_code.count("\n")
  end
end
