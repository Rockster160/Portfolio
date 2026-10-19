Buddy::Tools.register(
  name:        :pin_chore,
  summary:     "Pin a chore to THIS board so it always shows here, due or not. Board chat only. " \
               "Filing a chore under a group is edit_chore with groups.",
  description: <<~TXT,
    Pin an existing chore to the board this chat belongs to. A pinned chore
    shows on the board every day, whatever groups the board watches and
    whether or not it's due - like the Dailies list keeps a chore on Today -
    and it is still an ordinary chore circle there (tap to complete, skip,
    wave off). Use when they want a chore "on this board", "always on the
    screen", "pinned here". To take one off, unpin_chore.
  TXT
  feature:     :chores,
  board:       true,
  routinable:  false,
  args:        {
    chore: { type: :string, required: true, description: "Fuzzy name of the chore to pin" },
  },
  confirm:     ->(payload, ctx) {
    board = Buddy::BoardAdmin.board!(ctx)
    chore = ctx.resolve_chore(payload[:chore])
    ctx.no_chore!(payload[:chore], suffix: "to pin") if chore.nil?
    raise "#{chore.name} is already pinned to #{board.display_name}" if board.pinned_chore_ids.include?(chore.id)

    { summary: "Pin #{chore.name} to #{board.display_name}?", resolved: { chore_id: chore.id, board_name: board.display_name } }
  },
  label:       ->(payload, _ctx) {
    { title: Chore.find_by(id: payload[:chore_id])&.name.to_s, sub: "pinned to #{payload[:board_name]}" }
  },
  level:       2,
  execute:     ->(payload, ctx) {
    board = Buddy::BoardAdmin.board!(ctx)
    chore = Chore.find(payload[:chore_id])
    revert = Buddy::BoardAdmin.revert_for(board, "pinned_chore_ids", summary: "unpinned #{chore.name}")
    board.pin_chore!(chore)
    { chore_id: chore.id, revert: revert }
  },
  receipt:     ->(result, _ctx) {
    "Pinned #{Chore.find_by(id: result[:chore_id])&.name || "chore"} ✓"
  },
)
