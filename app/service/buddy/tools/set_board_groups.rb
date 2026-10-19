Buddy::Tools.register(
  name:        :set_board_groups,
  summary:     "Change which groups THIS board watches (its whole list). Board chat only. One " \
               "chore always here is pin_chore.",
  description: <<~TXT,
    Set the groups the board this chat belongs to watches. A chore, routine
    or credit button shows on the board when it's tagged with ANY of them.
    Pass the FULL list the board should watch afterwards, comma-separated -
    to add one, include the ones it already watches (they're listed under
    "This board"). "All" shows every chore in the house.
  TXT
  feature:     :chores,
  board:       true,
  routinable:  false,
  args:        {
    groups: { type: :string, required: true, description: "Comma-separated FULL list of groups to watch" },
  },
  confirm:     ->(payload, ctx) {
    board = Buddy::BoardAdmin.board!(ctx)
    groups = GroupTaggable.normalize(payload[:groups])
    raise "say at least one group - a board with none shows nothing" if groups.empty?

    current = board.chore_tags
    if groups.map(&:downcase).sort == current.map(&:downcase).sort
      raise "#{board.display_name} already watches #{current.join(", ")}"
    end

    { summary: "Show #{groups.join(", ")} on #{board.display_name}?", resolved: { tags: groups, board_name: board.display_name } }
  },
  label:       ->(payload, _ctx) {
    { title: payload[:board_name].to_s, sub: "watches #{Array(payload[:tags]).join(", ")}" }
  },
  level:       2,
  execute:     ->(payload, ctx) {
    board = Buddy::BoardAdmin.board!(ctx)
    revert = Buddy::BoardAdmin.revert_for(board, %w[chore_tags chore_tag], summary: "put the groups back")
    board.chore_tags = payload[:tags]
    board.save!
    board.broadcast_changed!
    { conversation_id: board.id, tags: board.chore_tags, revert: revert }
  },
  receipt:     ->(result, _ctx) {
    "Board now watches #{Array(result[:tags]).join(", ")} ✓"
  },
)
