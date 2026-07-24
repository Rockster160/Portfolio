Buddy::Tools.register(
  name:        :complete_chore,
  description: <<~TXT,
    Mark a chore as done for today. Use this whenever the user says they
    finished a household task. `chore` is a fuzzy name and will match
    against the user's accessible chores. Supports `count=N` when the
    same chore should be marked done multiple times (e.g. drank water 5x).
  TXT
  args: {
    chore: { type: :string, required: true,  description: "Fuzzy chore name" },
    note:  { type: :string, required: false, description: "Optional note captured on the completion" },
  },
  confirm: ->(payload, ctx) {
    chore = ctx.resolve_chore(payload[:chore])
    raise "no chore matching #{payload[:chore].inspect}" if chore.nil?

    { summary: "Mark #{chore.name} done for today?", resolved: { chore_id: chore.id } }
  },
  label: ->(payload, ctx) {
    chore = Chore.find_by(id: payload[:chore_id])
    return payload[:chore].to_s if chore.nil?

    parts = [chore.name]
    parts << "· #{chore.freq}" if chore.respond_to?(:freq) && chore.freq.present?
    if chore.assigned? && chore.assigned_to_user_id != ctx.user.id
      parts << "· for #{chore.assigned_to_user&.first_name}"
    end
    parts.join(" ")
  },
  merge_key: ->(payload) { "complete_chore:#{payload[:chore_id]}" },
  merge_label: ->(payload, count) {
    chore = Chore.find_by(id: payload[:chore_id])
    "#{count}× #{chore&.name || payload[:chore]}"
  },
  execute: ->(payload, ctx) {
    chore = Chore.find(payload[:chore_id])
    result = ChoreCompleter.new(chore, ctx.user, note: payload[:note]).call
    { chore_completion_id: result.completion&.id, skipped_reason: result.skipped_reason }
  },
  receipt: ->(_result, ctx) {
    chore_id = ctx.proposal["payload"]&.dig("chore_id")
    name = Chore.find_by(id: chore_id)&.name || "that chore"
    "Marked #{name} done ✓"
  },
)
