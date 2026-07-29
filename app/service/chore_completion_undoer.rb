# Removes a chore completion the SAME way a tap-undo in the Chores app does:
# destroy it, rebuild the streak, and broadcast so every open Chores client
# updates. Buddy's undo paths (Buddy::Reverter for a Level-2 complete_chore, and
# the undo_chore_completion tool) go through here, so undoing from Buddy fires
# the same callbacks/broadcasts as undoing in the app — the earlier bug was the
# Buddy undo removing the completion but never broadcasting the change.
class ChoreCompletionUndoer
  def self.call(user, completion, actor_tab_id: nil)
    return if completion.nil?

    leaf = completion.chore
    completion.destroy! # fires the :uncompleted Jil trigger via ChoreCompletion callbacks
    ChoreStreak.rebuild_for!(user, leaf)
    related = (leaf.parent_chore if leaf.respond_to?(:sub_chore?) && leaf.sub_chore?)
    ChoreBroadcaster.broadcast_changes!(user, leaf, related: related, actor_tab_id: actor_tab_id)
  end
end
