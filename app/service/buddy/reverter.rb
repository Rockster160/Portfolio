module Buddy
  # Reverses a single Byte mutation from a `revert` descriptor that the tool
  # stashed on its execute result (which the executor persists onto the
  # proposal button). This is the "lightweight recent-undo": no history table,
  # just the descriptor on the proposal.
  #
  # Descriptor shape (all string/symbol-indifferent):
  #   { op: "created", model: "ActionEvent", id: 42, summary: "..." }
  #   { op: "updated", model: "AgendaItem",  id: 7,  before: {...}, summary }
  #   { op: "recreated", model: "ActionEvent", attrs: {...}, summary }
  #
  # Deliberately narrow: only models whose reversal is clean. These are the
  # models Level-2 (execute-then-undo) tools create/remove — logging an event,
  # adding an agenda item, completing a chore, adding/removing a list item —
  # so unchecking a pre-checked row can cleanly walk it back.
  module Reverter
    module_function

    MODELS = {
      "ActionEvent"     => "ActionEvent",
      "AgendaItem"      => "AgendaItem",
      "Chore"           => "Chore",
      "ChoreCompletion" => "ChoreCompletion",
      "ChoreWithdrawal" => "ChoreWithdrawal",
      "ListItem"        => "ListItem",
    }.freeze

    def reversible?(revert)
      r = normalize(revert)
      return false if r[:op].blank?

      r[:op].to_s == "recreated" ? MODELS.key?(r[:model].to_s) : (r[:id].present? && MODELS.key?(r[:model].to_s))
    end

    # Reverses the descriptor. Returns a short human summary; raises on failure.
    def call(revert)
      r = normalize(revert)
      case r[:op].to_s
      when "created"   then remove(r)
      when "updated"   then revert_update(r)
      when "recreated" then recreate(r)
      else raise "nothing here to undo"
      end
      r[:summary].to_s.presence || "Undone."
    end

    # The descriptor that would put back whatever `call(revert)` is ABOUT to
    # take away. Must be built BEFORE reversing, because for a create the whole
    # point is to read the row while it still exists.
    #
    # Prod: an undo removed a chore completion carrying the note "built rocking
    # chair", and there was no way back - `remove` destroyed the row and kept
    # nothing, so re-marking the chore produced a bare completion with the note
    # gone. An undo has to be undoable, or it's a delete with a friendly name.
    #
    # Only creates need this. An `updated` descriptor already carries `before`,
    # and a `recreated` one is itself the inverse of a delete.
    def inverse(revert)
      r = normalize(revert)
      return nil unless r[:op].to_s == "created"
      return nil unless MODELS.key?(r[:model].to_s)

      rec = klass(r[:model]).find_by(id: r[:id])
      return nil if rec.nil?

      {
        "op"      => "recreated",
        "model"   => r[:model].to_s,
        "attrs"   => restorable_attrs(rec),
        "summary" => "put #{r[:summary].to_s.sub(/\Aunmarked\s+/i, "").presence || "it"} back",
      }
    end

    # Everything except the identity and the bookkeeping Rails owns. `id` is
    # deliberately dropped: the row is coming back as a new record, and holding
    # the old primary key would collide with anything created since.
    SKIP_ATTRS = %w[id created_at updated_at].freeze

    def restorable_attrs(rec)
      rec.attributes.except(*SKIP_ATTRS)
    end

    def normalize(revert)
      revert.respond_to?(:with_indifferent_access) ? revert.with_indifferent_access : {}
    end

    def klass(name)
      raise "can't undo #{name}" unless MODELS.key?(name.to_s)

      name.to_s.constantize
    end

    def find!(r)
      rec = klass(r[:model]).find_by(id: r[:id])
      raise "it's already gone" if rec.nil?

      rec
    end

    # Undo a create → remove what was just added (soft where the model allows).
    # Event mutations fire the :event trigger + broadcast (ActionEvent has no
    # model callback for it), the SAME as an in-app change.
    def remove(r)
      rec = find!(r)
      case r[:model].to_s
      when "ActionEvent"
        rec.destroy!
        ActionEventNotifier.notify(rec.user, rec, :removed, auth: :buddy, auth_id: rec.user_id)
      when "AgendaItem"      then rec.update!(status: :cancelled, cancelled_at: Time.current)
      # Archived, not destroyed. A chore owns its completions and its streak
      # history, and undoing "you just made this" must not take a month of
      # someone's record with it. Archiving is also what the Chores app itself
      # does for "delete", so this lands the same way removing it by hand would
      # — including the cascade to sub-chores and the :archived Jil trigger.
      when "Chore"           then rec.update!(archived_at: Time.current)
      # Go through the shared undoer so the streak rebuilds AND the Chores app
      # gets the broadcast — not just a silent destroy.
      when "ChoreCompletion" then ChoreCompletionUndoer.call(rec.user, rec)
      when "ListItem" then rec.soft_destroy
      when "ChoreWithdrawal"
        rec.destroy!
        refresh_balance(rec.user)
      end
    end

    # A balance change is invisible until the goal cards are recomputed and the
    # Chores app is told, so both halves of a withdrawal undo have to do what
    # ChoreWithdrawalsController does.
    def refresh_balance(user)
      ChoreGoal.refresh_all_for(user)
      ChoreBroadcaster.broadcast_changes!(user)
    end

    # Undo an edit → put the previous values back.
    def revert_update(r)
      before = (r[:before] || {}).to_h
      raise "no prior values recorded" if before.empty?

      rec = find!(r)
      rec.update!(before)
      # AgendaItem and Chore re-broadcast via their own model callbacks; the
      # other two need to be told, or the Chores/Events app keeps showing the
      # edited values.
      case r[:model].to_s
      when "ActionEvent"
        ActionEventNotifier.notify(rec.user, rec, :changed, auth: :buddy, auth_id: rec.user_id)
      when "ChoreCompletion"
        ChoreStreak.rebuild_for!(rec.user, rec.chore) if before.key?("day_key") || before.key?(:day_key)
        ChoreBroadcaster.broadcast_changes!(rec.user, rec.chore)
      end
    end

    # Undo a hard delete → recreate from the stored attributes. A removed list
    # item goes back through the list's own add path (soft-undelete + resort)
    # rather than a bare create!, so it lands like the app re-added it.
    def recreate(r)
      attrs = (r[:attrs] || {}).to_h
      raise "nothing to recreate" if attrs.empty?

      if r[:model].to_s == "ListItem"
        list = List.find(attrs["list_id"] || attrs[:list_id])
        return list.list_items.add(attrs["name"] || attrs[:name])
      end

      rec = klass(r[:model]).create!(attrs)
      case r[:model].to_s
      # Re-adding a deleted event fires the :event trigger + broadcast, same as
      # a fresh log.
      when "ActionEvent"
        ActionEventNotifier.notify(rec.user, rec, :added, auth: :buddy, auth_id: rec.user_id)
      # A completion coming back has to rebuild the streak and tell the Chores
      # app, exactly as removing it did — otherwise the row is in the database
      # but the app still shows the day as missed.
      when "ChoreCompletion"
        ChoreStreak.rebuild_for!(rec.user, rec.chore)
        ChoreBroadcaster.broadcast_changes!(rec.user, rec.chore, related: (rec.chore.parent_chore if rec.chore.sub_chore?))
      when "ChoreWithdrawal"
        refresh_balance(rec.user)
      end
      rec
    end

    # ---- finding + performing the most-recent undo (for the `undo` tool) ----

    # How far back "undo that" is willing to reach. `undo` takes no arguments -
    # it means "the thing you just did" - so anything old enough that they'd
    # have to NAME it isn't what they're pointing at.
    #
    # Prod 1362: told the routine it had just saved was wrong, Buddy offered to
    # undo a chore completion from five hours earlier, because that was simply
    # the newest reversible thing in the thread. Past this window the honest
    # answer is "nothing recent to undo", which sends them to the tools that
    # take a name (undo_chore_completion, edit_event, delete_event) instead of
    # quietly proposing to unpick their morning.
    RECENT_WINDOW = 2.hours

    # The newest executed proposal button in the conversation that carries a
    # still-un-undone, reversible `revert` descriptor. Returns
    # { action_id:, button_id:, summary: } or nil.
    def most_recent(conversation, within: RECENT_WINDOW)
      return nil if conversation.nil?

      actions = ByteAction
        .where(byte_conversation_id: conversation.id, tool_name: "buddy_proposals")
        .where(created_at: within.ago..)
        .order(created_at: :desc)
        .limit(25)
      actions.each do |action|
        Array(action.buttons).reverse_each { |btn|
          result = btn["result"]
          next unless result.is_a?(Hash)
          next if result["undone"]

          reverts = descriptors(result)
          next if reverts.empty? || !reverts.all? { |rv| reversible?(rv) }

          return { action_id: action.id, button_id: btn["id"], summary: normalize(reverts.first)[:summary].to_s.presence || "your last change" }
        }
      end
      nil
    end

    # A tool that touched several rows in one go (editing both of today's water
    # completions) stashes `reverts:`; everything else stashes a single
    # `revert:`. Both shapes read out as a list so callers walk one path.
    def descriptors(result)
      raw = result["reverts"].presence || result[:reverts].presence
      raw ||= [result["revert"] || result[:revert]]
      Array(raw).compact
    end

    # Reverse the button's stashed descriptor and mark it undone so a second
    # undo moves on to the previous action.
    #
    # Returns `reverts:` alongside the summary — the descriptors that put back
    # what this just removed. The `undo` tool passes them straight through as
    # its own revert, which is what makes the undo row itself undoable.
    def perform!(byte_action_id, button_id)
      action  = ByteAction.find(byte_action_id)
      buttons = Array(action.buttons).map(&:dup)
      btn     = buttons.find { |b| b["id"].to_i == button_id.to_i }
      raise "can't find that action" if btn.nil?

      result = (btn["result"] || {}).dup
      raise "that's already been undone" if result["undone"]

      reverts = descriptors(result)
      raise "nothing here to undo" if reverts.empty?

      # Snapshot first: after `call` the rows are gone and there is nothing left
      # to read them off.
      inverses = reverts.filter_map { |rv| inverse(rv) }
      summary  = reverts.map { |rv| call(rv) }.first

      result["undone"] = true
      btn["result"] = result
      action.update!(buttons: buttons)
      { summary: summary, reverts: inverses }
    end
  end
end
