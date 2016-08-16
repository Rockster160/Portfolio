# == Schema Information
#
# Table name: litter_text_reminders
#
#  id         :integer          not null, primary key
#  turn       :integer          default(0)
#  created_at :datetime
#  updated_at :datetime
#

class LitterTextReminder < ActiveRecord::Base

  enum turn: {
    "3852599640" => 0,
    "8019317892" => 1
  }

  def toggle!
    if turn == LitterTextReminder.turns[0]
      update(turn: "8019317892")
    else
      update(turn: "3852599640")
    end
    first.turn
  end

end
