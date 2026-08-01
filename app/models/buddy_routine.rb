# == Schema Information
#
# Table name: buddy_routines
#
#  id          :bigint           not null, primary key
#  description :string
#  enabled     :boolean          default(TRUE), not null
#  last_run_at :datetime
#  metadata    :jsonb            not null
#  name        :string           not null
#  position    :integer
#  run_count   :integer          default(0), not null
#  steps       :jsonb            not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  user_id     :bigint           not null
#

# A named sequence of Buddy tool calls the person can trigger by saying its
# name. `steps` is the same [{ tool_name:, payload: }] shape Buddy::GPT::Turn
# hands Buddy::ProposalBuilder, so running one is a replay through the ordinary
# proposal path - including the wait gate, which is what makes "power the
# printer on, wait a minute, then preheat" a single word.
class BuddyRoutine < ApplicationRecord
  belongs_to :user

  MAX_STEPS = 12

  scope :enabled,  -> { where(enabled: true) }
  scope :ordered,  -> { order(Arel.sql("LOWER(name) ASC")) }
  # On the Quick grid in the hero, in the order they put them. Alphabetical is
  # right for the drawer, where you're looking something up; a grid you tap is
  # ordered by how often you reach for it, which only they know.
  scope :pinned,   -> { where.not(position: nil).order(:position, :id) }

  def pinned?
    position.present?
  end

  validates :name, presence: true, length: { maximum: 80 }
  validates :description, length: { maximum: 300 }
  validate  :steps_are_runnable

  # Steps carry the ARGUMENTS the person's request became, never the ids a
  # tool's confirm resolved them to. Buddy::Routines.sanitize_steps strips the
  # resolved keys on the way in; this is the guard that they stayed off.
  def self.step(tool_name, payload)
    { "tool_name" => tool_name.to_s, "payload" => (payload || {}).transform_keys(&:to_s) }
  end

  # The markers ProposalBuilder.create takes. Symbol keys because that's the
  # shape Turn#build_proposals produces for a live call.
  def markers
    Array(steps).filter_map { |raw|
      tool = Buddy::Tools[raw["tool_name"]]
      next nil if tool.nil?

      { tool_name: raw["tool_name"].to_sym, payload: (raw["payload"] || {}).transform_keys(&:to_sym) }
    }
  end

  # One line per step, for the routines index Buddy reads and for the panel.
  # Deliberately the tool name plus its most identifying argument rather than a
  # rendered label: labels call into `confirm`, which hits the database, and
  # this runs for every routine on every context build.
  def summary
    Array(steps).map { |raw| self.class.step_phrase(raw) }
  end

  def self.step_phrase(raw)
    tool = raw["tool_name"].to_s
    args = raw["payload"] || {}
    # A wait is the one step whose tool name says nothing useful, and it's the
    # step people most want to see in a list - "wait 1 min" is the difference
    # between reading a routine and decoding it.
    return wait_phrase(args) if tool == "set_timer"

    detail = args["name"] || args["chore"] || args["item"] || args["command"] || args["message"] || args["title"]
    detail.present? ? "#{tool.tr("_", " ")}: #{detail}" : tool.tr("_", " ")
  end

  def self.wait_phrase(args)
    secs  = args["seconds"].to_i
    spell = secs >= 60 && (secs % 60).zero? ? "#{secs / 60} min" : "#{secs} sec"
    args["then_continue"] ? "wait #{spell}" : "set a #{spell} timer"
  end

  def touch_run!
    update_columns(run_count: run_count + 1, last_run_at: Time.current, updated_at: Time.current)
  end

  def serialize_for_client
    {
      id:          id,
      name:        name,
      description: description,
      enabled:     enabled,
      steps:       Array(steps),
      summary:     summary,
      run_count:   run_count,
      last_run_at: last_run_at&.iso8601,
      position:    position,
    }
  end

  private

  # A routine that can't run is worse than no routine: it fails silently at the
  # moment they're relying on it. So every step is validated against the live
  # registry when it's SAVED, and a routine that survives this is runnable.
  def steps_are_runnable
    rows = Array(steps)
    return errors.add(:steps, "needs at least one step") if rows.empty?
    return errors.add(:steps, "is limited to #{MAX_STEPS} steps") if rows.length > MAX_STEPS

    rows.each_with_index { |raw, i| validate_step(raw, i + 1) }
    # Repeated here rather than left to Buddy::Routines.sanitize, because a
    # dangling `{{name}}` is a routine that stops halfway through and this is
    # the last gate before it's stored - whichever path it arrived by.
    Buddy::Routines.check_var_flow!(rows) if errors.empty?
  rescue StandardError => e
    errors.add(:steps, e.message)
  end

  def validate_step(raw, position)
    return errors.add(:steps, "step #{position} is malformed") unless raw.is_a?(Hash)

    tool = Buddy::Tools[raw["tool_name"].to_s.presence || "-"]
    return errors.add(:steps, "step #{position}: no tool named #{raw["tool_name"].inspect}") if tool.nil?

    unless Buddy::Tools.routinable?(tool)
      return errors.add(:steps, "step #{position}: #{tool[:name]} can't be saved in a routine")
    end

    payload = (raw["payload"] || {}).transform_keys(&:to_sym)
    _, problems = Buddy::Tools.validate_payload(tool, payload)
    errors.add(:steps, "step #{position} (#{tool[:name]}): #{problems.join("; ")}") if problems.any?
  end
end
