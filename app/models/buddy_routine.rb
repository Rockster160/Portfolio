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
  scope :pinned,   -> { where.not(position: nil).order(:position, :id) }

  # What the Quick grid and the wall tablet show: everything that's switched on,
  # pinned ones first in the order they were dragged into, then the rest by name.
  #
  # Pinning PROMOTES rather than admits. It used to be the gate, and that made
  # saving a routine two steps — you'd save one, go looking for it in Quick, and
  # find an empty panel telling you to go star it somewhere you weren't. A
  # routine you bothered to save is one you want to tap; the star is for putting
  # the three you reach for daily at the front.
  scope :for_quick, -> { enabled.order(Arel.sql("position ASC NULLS LAST, LOWER(name) ASC")) }

  # The wall tablet takes only the starred ones, and that's about space rather
  # than principle. Quick is a popover you open, scan and dismiss, so carrying
  # everything costs nothing. The kiosk is a fixed pad with room for a handful
  # of big targets, and filling it with every routine ever saved buries the
  # three you walk up and press. There the star IS the gate.
  scope :for_kiosk, -> { enabled.pinned }

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
    phrase = detail.present? ? "#{tool.tr("_", " ")}: #{detail}" : tool.tr("_", " ")
    times  = args[Buddy::Tools::COUNT_ARG.to_s].to_i
    # How MANY times is half of what a step does, and leaving it off made a
    # routine lie about itself: "cup water" saved as three waters read back as
    # a single "complete chore: 8oz Water", so the one thing worth checking was
    # the one thing not shown.
    times > 1 ? "#{phrase} ×#{times}" : phrase
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
      step_rows:   step_rows,
      run_count:   run_count,
      last_run_at: last_run_at&.iso8601,
      position:    position,
    }
  end

  # What the editor needs per step, which is more than the summary line: its
  # ORIGINAL index (the only thing the client is allowed to send back), and
  # whether a count applies at all. `countable` is read off the tool rather than
  # guessed - merge_label is what declares repeat semantics, so a step without
  # one gets no stepper instead of a control that silently does nothing.
  def step_rows
    Array(steps).each_with_index.map { |raw, i|
      tool = Buddy::Tools[raw["tool_name"].to_s.presence || "-"]
      {
        index:     i,
        phrase:    self.class.step_phrase(raw),
        count:     (raw["payload"] || {})[Buddy::Tools::COUNT_ARG.to_s].to_i.clamp(1, 999),
        countable: tool.present? && tool[:merge_label].present?,
      }
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
