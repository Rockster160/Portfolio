Buddy::Tools.register(
  name:        :unpin_chore,
  summary:     "Take a pinned chore off THIS board. Board chat only. Archiving the chore itself " \
               "is edit_chore.",
  description: <<~TXT,
    Unpin a chore from the board this chat belongs to. The chore itself is
    untouched - it still shows here if it's in one of the board's groups and
    due, and everywhere else as before. Use for "take X off this board",
    "unpin X", "stop showing X here".
  TXT
  feature:     :chores,
  board:       true,
  routinable:  false,
  args:        {
    chore: { type: :string, required: true, description: "Fuzzy name of the pinned chore" },
  },
  confirm:     ->(payload, ctx) {
    board = Buddy::BoardAdmin.board!(ctx)
    pinned = Chore.where(id: board.pinned_chore_ids).to_a
    raise "nothing is pinned to #{board.display_name}" if pinned.empty?

    chore = ctx.resolve_chore(payload[:chore])
    unless chore && pinned.include?(chore)
      raise "#{payload[:chore].inspect} isn't pinned here - pinned: #{pinned.map(&:name).join(", ")}"
    end

    { summary: "Unpin #{chore.name}?", resolved: { chore_id: chore.id, board_name: board.display_name } }
  },
  label:       ->(payload, _ctx) {
    { title: Chore.find_by(id: payload[:chore_id])&.name.to_s, sub: "off #{payload[:board_name]}" }
  },
  level:       2,
  execute:     ->(payload, ctx) {
    board = Buddy::BoardAdmin.board!(ctx)
    chore = Chore.find(payload[:chore_id])
    revert = Buddy::BoardAdmin.revert_for(board, "pinned_chore_ids", summary: "pinned #{chore.name} again")
    board.unpin_chore!(chore)
    { chore_id: chore.id, revert: revert }
  },
  receipt:     ->(result, _ctx) {
    "Unpinned #{Chore.find_by(id: result[:chore_id])&.name || "chore"} ✓"
  },
)
