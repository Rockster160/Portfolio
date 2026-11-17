# == Schema Information
#
# Table name: buddy_commands
#
#  id          :bigint           not null, primary key
#  last_run_at :datetime
#  name        :string           not null
#  run_count   :integer          default(0), not null
#  say         :text
#  steps       :jsonb            not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  user_id     :bigint           not null
#

# What a Jil task's `Buddy.command("Key")` runs, set by telling Buddy "set
# <key> to <something>".
#
# Exactly one of two things is stored:
# - `steps`, the same [{ tool_name:, payload: }] markers a routine holds, which
#   replay through ProposalBuilder with no model turn, or
# - `say`, words that are handed back to Buddy as a fresh request each time,
#   for anything that can't be written down as tool calls ahead of time.
#
# Unlike a routine it has no name a person says: it is reached only through
# the task that names its key, so it never appears in the routines list, the
# Quick grid or on a board.
class BuddyCommand < ApplicationRecord
  belongs_to :user

  validates :name, presence: true, length: { maximum: 80 }
  validates :say, length: { maximum: 500 }
  validate :steps_or_words

  def self.named(user, key)
    wanted = key.to_s.strip.downcase
    return nil if wanted.empty?

    where(user: user).find_by("LOWER(name) = ?", wanted)
  end

  def runs_steps?
    Array(steps).any?
  end

  def markers
    BuddyRoutine.new(steps: steps).markers
  end

  # One line per step, or the words in quotes, for the receipt and the roster.
  def summary
    return ["say to Buddy: \"#{say}\""] unless runs_steps?

    Array(steps).map { |raw| BuddyRoutine.step_phrase(raw) }
  end

  def touch_run!
    update_columns(run_count: run_count + 1, last_run_at: Time.current, updated_at: Time.current)
  end

  private

  def steps_or_words
    has_steps = Array(steps).any?
    has_words = say.to_s.strip.present?
    return errors.add(:base, "needs either steps or words for Buddy") if !has_steps && !has_words
    return errors.add(:base, "holds steps or words for Buddy, not both") if has_steps && has_words
    return unless has_steps

    probe = BuddyRoutine.new(name: name, steps: steps)
    probe.validate
    probe.errors[:steps].each { |message| errors.add(:steps, message) }
  end
end
