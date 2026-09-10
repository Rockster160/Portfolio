# Removes a chore completion the SAME way a tap-undo in the Chores app does:
# destroy it, rebuild the streak, and broadcast so every open Chores client
# updates. Buddy's undo paths (Buddy::Reverter for a Level-2 complete_chore, and
# the undo_chore_completion tool) go through here, so undoing from Buddy fires
# the same callbacks/broadcasts as undoing in the app — the earlier bug was the
# Buddy undo removing the completion but never broadcasting the change.
class ChoreCompletionUndoer
  # `actor` is whoever is undoing. The streak and the cards being rebuilt belong
  # to the person the completion CREDITED, and since a chore can be marked done
  # on a housemate's behalf those are not always the same person — rebuilding
  # the actor's streak would leave the credited person's own record standing on
  # a completion that no longer exists. The actor still gets a broadcast of
  # their own, because the Chores channels are per-user.
  def self.call(actor, completion, actor_tab_id: nil)
    return if completion.nil?

    leaf = completion.chore
    credited = completion.user || actor
    completion.destroy! # fires the :uncompleted Jil trigger via ChoreCompletion callbacks
    ChoreStreak.rebuild_for!(credited, leaf)
    related = (leaf.parent_chore if leaf.respond_to?(:sub_chore?) && leaf.sub_chore?)
    ChoreBroadcaster.broadcast_changes!(credited, leaf, related: related, actor_tab_id: actor_tab_id)
    return if actor.nil? || actor.id == credited.id

    ChoreBroadcaster.broadcast_changes!(actor, leaf, related: related, actor_tab_id: actor_tab_id)
  end
end
