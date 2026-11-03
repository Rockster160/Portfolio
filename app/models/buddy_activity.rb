# == Schema Information
#
# Table name: buddy_activities
#
#  id                   :bigint           not null, primary key
#  error_message        :text
#  ok                   :boolean          default(TRUE), not null
#  payload              :jsonb            not null
#  receipt              :text
#  reverts              :jsonb            not null
#  tool_name            :text             not null
#  undo_note            :text
#  undone_at            :datetime
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  byte_conversation_id :bigint
#  user_id              :bigint           not null
#
class BuddyActivity < ApplicationRecord
  belongs_to :user
  belongs_to :byte_conversation, optional: true

  # Kept long enough to answer "what did Buddy do last week".
  RETAIN_FOR = 90.days
  PAYLOAD_LIMIT = 4_000

  scope :recent, -> { order(created_at: :desc, id: :desc) }
  scope :expired, -> { where(created_at: ...RETAIN_FOR.ago) }

  # A tool that only looks something up changed nothing, so there's nothing
  # to list or undo. An answering tool that `acts` did change something.
  def self.recorded?(tool)
    !tool[:answers] || tool[:acts]
  end

  # Called from Buddy::Tools.dispatch for every call it runs. Recording must
  # never be the reason a tool fails, so this returns nil rather than raising.
  def self.record!(tool, payload, ctx, outcome)
    return unless recorded?(tool)
    return if ctx&.user.nil?

    data = outcome[:data].is_a?(Hash) ? outcome[:data] : {}
    create!(
      user:              ctx.user,
      byte_conversation: ctx.conversation,
      tool_name:         tool[:name],
      payload:           compact_payload(payload),
      ok:                outcome[:ok],
      error_message:     outcome[:error].to_s.truncate(1_000).presence,
      receipt:           (receipt_for(tool, outcome[:data], ctx) if outcome[:ok]),
      reverts:           outcome[:ok] ? Buddy::Reverter.descriptors(data).as_json : [],
    )
  rescue StandardError => e
    Rails.logger.warn("[BuddyActivity] couldn't record #{tool[:name]}: #{e.class}: #{e.message}")
    nil
  end

  def self.receipt_for(tool, data, ctx)
    return if tool[:receipt].nil?

    tool[:receipt].call(data, ctx).to_s.truncate(500).presence
  rescue StandardError
    nil
  end

  def self.compact_payload(payload)
    json = payload.to_h.as_json
    json.to_json.length > PAYLOAD_LIMIT ? { truncated: true } : json
  end

  def self.mark_undone!(ids, note: nil)
    ids = Array(ids).compact
    return if ids.empty?

    where(id: ids, undone_at: nil).update_all(undone_at: Time.current, undo_note: note, updated_at: Time.current)
  end

  def undoable?
    ok? && undone_at.nil? && Buddy::Reverter.descriptors("reverts" => reverts).any? { |rv| Buddy::Reverter.reversible?(rv) }
  end

  # The checklist row this call was made from, when it came from one. Undoing
  # through the row keeps the chat's checkbox in step with this page.
  def checklist_row
    actions = ByteAction.where(user_id: user_id)
    actions = actions.where("buttons @> ?", [{ activity_ids: [id] }].to_json)
    action = actions.order(id: :desc).first
    button = action && Array(action.buttons).find { |btn| Array(btn["activity_ids"]).include?(id) }
    [action, button] if button
  end

  # Returns the summary of what was put back; raises when nothing can be.
  def undo!
    raise "that's already been undone" if undone_at.present?
    raise "nothing here to undo" unless undoable?

    action, button = checklist_row
    if button
      # Unticked in the chat, or undone by asking, before this page caught up.
      live = button["status"].to_s == "executed" && button["undoable"] && !button.dig("result", "undone")
      unless live
        self.class.mark_undone!(id)
        raise "that's already been undone"
      end

      Buddy::ProposalExecutor.undo!(action.id, button["id"])
      reload.undo_note.presence || "Undone."
    else
      summary = reverts.map { |rv| Buddy::Reverter.call(rv) }.first
      self.class.mark_undone!(id, note: summary)
      summary
    end
  end
end
