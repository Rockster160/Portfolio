# == Schema Information
#
# Table name: litter_text_reminders
#
#  id         :integer          not null, primary key
#  turn       :integer          default(0)
#  created_at :datetime
#  updated_at :datetime
#  regex      :string(255)
#  message    :string(255)
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

  def done_by(number, msg)
    turn_idx = LitterTextReminder.turns[number.to_s.last(10)]
    return false if turn_idx.nil?
    new_idx = (turn_idx + 1) % LitterTextReminder.turns.count
    update(turn: LitterTextReminder.turns.keys[new_idx], updated_at: stripped_text.include?("yesterday") ? 12.hours.ago : 1.minute.ago)
  end

end
