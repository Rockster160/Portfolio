# == Schema Information
#
# Table name: board_task_buttons
#
#  id         :bigint           not null, primary key
#  color      :text
#  icon       :text
#  label      :text             not null
#  sort_order :integer
#  tags       :text             default([]), not null, is an Array
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  task_id    :bigint           not null
#  user_id    :bigint           not null
#

# A custom board button that, on a press, RUNS a Jil task — the way the old
# Whisper PWA buttons worked: "she was fed", "quiet mode", "play the nap sound",
# "she's gone". The task is run exactly as tapping it on its own page does, with
# `execute: true` in its input, so a button task that branches on that flag does
# its thing (and a plain one just runs).
#
# Its own kind rather than a BuddyRoutine, because a routine fires a trigger
# SCOPE and these tasks listen on `monitor::…`, which a scope can't reach; and
# its own thing rather than a Buddy tool, because it is a board control a person
# presses, never something the model reaches for. Grouped by `tag` like the
# chores and credit buttons beside it, so it sits on any board watching its
# group, and carries an `icon` the board draws (see Buddy::BoardIcon).
#
# Owned by the person whose board it is (their tasks, their board), and the task
# runs as its own owner on a press, so a shared task still runs with the right
# account's reach.
class BoardTaskButton < ApplicationRecord
  belongs_to :user
  belongs_to :task

  validates :label, presence: true

  # Grouping: `tagged`, `tag_names` and write-time normalization of the `tags`
  # array all come from the concern.
  include GroupTaggable

  # A board's buttons: those in ANY of its groups, in the order they were added.
  scope :for_board, ->(tags) { tagged(tags).order(Arel.sql("sort_order ASC NULLS LAST, id ASC")) }

  # How the board draws it: a stateless "tap to run" circle, with its own icon
  # and colour. `short_name` mirrors the field a chore cell reads for its title
  # and first-letter fallback, so the client paints it the same way. `monitor`
  # is the tile its task answers on, when it has one: the board listens there
  # and wears the `icon` and `label` the task says it has right now (a toggle
  # showing what pressing it will do), the way the PWA's tile does.
  def board_item
    {
      kind:       :task,
      id:         id,
      name:       label,
      short_name: label,
      color:      color.presence,
      icon:       icon.presence,
      icon_kind:  Buddy::BoardIcon.kind_for(icon),
      monitor:    monitor_channel,
    }
  end

  # `monitor::whisper-btn-home-toggle` answers on `whisper-btn-home-toggle`.
  def monitor_channel
    task&.listener.to_s[/\Amonitor::?([\w-]+)\z/, 1]
  end
end
