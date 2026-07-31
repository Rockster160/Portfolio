Buddy::Tools.register(
  name:        :undo,
  description: <<~TXT,
    Undo the most recent thing you did for the person in THIS conversation:
    reverses your last create (removes what you added), edit (restores the
    old values), or delete (brings it back). Use when they say "undo that",
    "never mind", "put it back", "revert that", "scratch that".

    "The last thing" is meant literally - this reaches back a couple of hours
    at most, because it takes no arguments and so can only ever mean the thing
    you just did. It is NOT the tool for "undo the water I logged this morning";
    that one has a name attached, so it wants undo_chore_completion, edit_event
    or delete_event.

    Currently covers events you logged and agenda items you added / edited /
    removed. For undoing a chore COMPLETION specifically, use
    undo_chore_completion instead.

    When it comes back with nothing recent, say so plainly. Do not go looking
    for something else to undo - offering to unpick something from hours ago is
    alarming, and it is never what they meant.
  TXT
  args: {},
  # "The last thing" means something different every single run.
  routinable: false,
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
