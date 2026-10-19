module Buddy
  # A board's own Buddy: the chat opened from the message button on a board,
  # where the person sets the board up by talking to the pet on it. The thread
  # IS the board (a board is a ByteConversation), so the pet always knows which
  # board it's on, and the board-only tools (`board: true` in Buddy::Tools)
  # act on that one.
  module BoardAdmin
    module_function

    # The board this turn is about, or a refusal the model can read. Board tools
    # are only offered on a board's thread, so this is the backstop for a call
    # that arrives from anywhere else (a routine replaying one, a stale card).
    def board!(ctx)
      convo = ctx.conversation
      raise "that only works from a board's own chat" unless convo&.board?

      convo
    end

    # Undo for a setting kept in the board's metadata: the keys this change
    # touched and what they held before (nil when the key wasn't there).
    def revert_for(convo, keys, summary:)
      before = Array(keys).index_with { |key| convo.metadata.to_h[key] }
      { op: "updated", model: "ByteConversation", id: convo.id, before: { "metadata" => before }, summary: summary }
    end

    # What the pet is told about the board it's on, every turn on that board.
    def prompt_block(convo)
      user = convo.user
      groups = convo.chore_tags
      pinned = Chore.where(id: convo.pinned_chore_ids).index_by(&:id)
      pinned_names = convo.pinned_chore_ids.filter_map { |id| pinned[id]&.name }
      buttons = credit_buttons(user, convo.named_board_groups)

      <<~TXT.strip
        ## This board
        This conversation is the chat for **#{convo.display_name}**, a chore board on a screen in the house. The person opened it from the board to set the board up. You are the pet on that board, and "this board" / "here" always means this one.

        What it shows:
        - **Groups it watches:** #{groups.any? ? groups.join(", ") : "none yet - it shows nothing until it has one"}. A chore, routine or credit button shows here when it's tagged with any of these groups. "All" means every chore. "Whisper" is a feed group with no chores behind it.
        - **Pinned chores** (always shown, due or not, whatever the groups): #{pinned_names.any? ? pinned_names.join(", ") : "none"}.
        - **Credit buttons** (one press marks a chore done for a chosen person): #{buttons.any? ? buttons.join("; ") : "none"}.
        - **Hidden by search:** #{convo.hidden_chore_filter.presence || "nothing"}.
        - **Hot-chore dreams:** #{convo.chore_dreams? ? "on - each lasts #{convo.dream_minutes} min, then #{convo.dream_break_minutes} min off" : "off"}.

        Setting it up:
        - To put a NEW chore on this board, create it with `groups` set to one of this board's groups (create_chore files it under this board's groups when you leave `groups` out). Assign it with `assignee`.
        - To put an EXISTING chore on this board for good, pin it (pin_chore). To file it under a group instead, edit_chore with `groups`.
        - A credit button is for a chore people mark done for someone else ("Dishes, by Chelsea"): add_credit_button.
        - Changing which groups the board watches is set_board_groups, with the FULL list it should watch.
        - Anything the board can't do yet - a new kind of button, a layout change, a setting that doesn't exist - is a feature request (request_feature). Say plainly that it isn't something you can do yet and that you've asked for it.
      TXT
    end

    # "Dishes, by Chelsea → Dishes (credits Chelsea)" for each button in the
    # board's groups.
    def credit_buttons(user, groups)
      return [] if groups.empty? || user.chore_household_id.nil?

      scope = ChoreCreditButton.where(chore_household_id: user.chore_household_id).for_board(groups)
      scope.includes(:chore, :credit_user).map { |button|
        who = button.credit_user&.first_name || "whoever did it"
        "#{button.label} → #{button.chore&.name} (credits #{who})"
      }
    end
  end
end
