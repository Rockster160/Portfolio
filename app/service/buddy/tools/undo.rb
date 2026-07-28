Buddy::Tools.register(
  name:        :undo,
  description: <<~TXT,
    Undo the most recent thing you did for the person in THIS conversation:
    reverses your last create (removes what you added), edit (restores the
    old values), or delete (brings it back). Use when they say "undo that",
    "never mind", "put it back", "revert that", "scratch that".

    Currently covers events you logged and agenda items you added / edited /
    removed. For undoing a chore COMPLETION specifically, use
    undo_chore_completion instead. If there's nothing recent to undo, say so
    plainly rather than guessing.
  TXT
  args: {},
  confirm: ->(_payload, ctx) {
    found = Buddy::Reverter.most_recent(ctx.conversation)
    raise "nothing recent to undo" if found.nil?

    {
      summary:  "Undo #{found[:summary]}?",
      resolved: { byte_action_id: found[:action_id], button_id: found[:button_id], undo_summary: found[:summary] },
    }
  },
  label:   ->(payload, _ctx) { { title: "Undo", sub: payload[:undo_summary] } },
  execute: ->(payload, _ctx) {
    Buddy::Reverter.perform!(payload[:byte_action_id], payload[:button_id])
  },
  receipt: ->(result, _ctx) { result[:summary].to_s.presence || "Done, undone." },
)
