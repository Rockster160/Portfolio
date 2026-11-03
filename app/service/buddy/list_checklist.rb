module Buddy
  # A list, handed over as tickable boxes instead of as prose.
  #
  # Byte already has a checklist - every proposal it makes arrives as a row with
  # a box, and ticking one runs it. This posts one that nothing was proposed
  # for: the rows ARE the list, one per item, and ticking a box takes that item
  # off the list exactly the way checking it off in the app does.
  #
  # So it reuses `buddy_proposals` rather than growing a second checklist shape
  # - same renderer, same POST, same tool. What differs is that a row follows
  # the list instead of being a one-way proposal: `check!` ticks and unticks it
  # as often as they like, and `sync!` moves it when the list changes anywhere
  # else.
  #
  # Those rows are `remove_list_item` proposals left PENDING, which is the one
  # part that can't be borrowed: that tool is level 2, so ProposalBuilder would
  # have run every row the instant it built the card and handed back an already
  # empty list. The buttons are assembled here for that reason and no other.
  module ListChecklist
    module_function

    ITEM_TOOL = :remove_list_item

    # Long enough to survive the night. It goes up when the house goes dark and
    # has to still be tickable at 2am; the three-day proposal TTL would leave
    # last night's card live beside tonight's.
    TTL = 18.hours

    # What a row says its tick will do. `remove_list_item`'s own words ("Tap to
    # remove it") describe the mechanism, and on a to-do list the mechanism is
    # beside the point - the person is checking something OFF, and the item
    # leaving the list is the consequence of that, not the thing they're doing.
    HINT = { "tap" => "Tap when it's done", "done" => "Done - untick to put it back" }.freeze

    # A card is something somebody reads at a glance and taps. Thirty boxes is
    # not that - it is a page, and it pushes whatever was said above it out of
    # sight to show rows nobody is going to tick tonight.
    #
    # Capped rather than scrolled, and the cap SAYS SO. A truncated card that
    # stays quiet about it reads as the whole list, which is worse than a long
    # card: the person ticks off four things believing they are done.
    MAX_ROWS = 10

    # Returns how many boxes went up. 0 means nothing was posted at all: an
    # empty list has nothing to check off, and a bubble saying so is a
    # notification about nothing.
    def post!(user:, list:, text:)
      conversation = ::Buddy::CompanionRelay.conversation_for(user)
      items = list.list_items.to_a
      return 0 if conversation.nil? || items.empty?

      # Cap in the list's order, render in the reverse of it. `list_items` is
      # `-> { ordered }` = `sort_order DESC NULLS LAST`, so `first(MAX_ROWS)`
      # takes the NEWEST rows — the batch just added, which is the one worth
      # showing. A card is worked through top to bottom, so the rows it keeps
      # are then read oldest-first.
      shown   = items.first(MAX_ROWS).reverse
      body    = [text, overflow_note(items.length)].compact_blank.join("\n\n")
      buttons = shown.each_with_index.map { |item, i| button_for(list, item, i + 1) }
      action  = ByteAction.new(
        user:              user,
        byte_conversation: conversation,
        kind:              :custom,
        tool_name:         "buddy_proposals",
        multi_select:      true,
        buttons:           buttons,
        tool_input:        { "list_id" => list.id, "list_name" => list.name },
        expires_at:        TTL.from_now,
      )
      action.save!

      # Last night's card - or an earlier one tonight - points at the same
      # items, and unticking a stale row would put back what this one just took
      # off. Same identity rule every corrected proposal already uses.
      ::Buddy::Supersede.replace!(action: action, keys: buttons.pluck("merge_key"))

      message = ::Buddy::CompanionDelivery.deliver_plain(
        user:         user,
        conversation: conversation,
        text:         body,
        metadata:     metadata_for(action, buttons),
        # The note about what didn't fit belongs on the card, not in a push
        # notification, where it is a line of small print about nothing.
        push_title:   text,
      )
      action.update!(byte_message_id: message.id)
      shown.size
    end

    # Only this card puts a list on a proposal checklist's input; the model's
    # own checklists carry their queue there instead.
    def card?(action)
      action.tool_input.is_a?(Hash) && action.tool_input["list_id"].present?
    end

    # A row on this card is a mirror of the item, not a one-way proposal: ticked
    # means it's off the list, unticked means it's on it, and either can follow
    # the other as often as they like. So a tick runs the removal right here, in
    # the request, and an untick puts the item back and leaves the row pending -
    # never `undone`, which is the executor's word for a row that's finished.
    #
    # `checked` is the state they want, not a flip, so a repeat lands where the
    # first one did.
    def check!(action, button_id, checked)
      action.with_lock do
        buttons = (action.buttons || []).map(&:deep_dup)
        btn = buttons.find { |b| b["id"].to_i == button_id.to_i }
        next if btn.nil? || btn["status"].to_s == ::Buddy::Supersede::STATUS

        ticked = btn["status"].to_s == "executed"
        next if ticked == checked

        checked ? tick(action, btn) : untick(action, btn)
        action.update!(buttons: buttons)
      end
      repaint(action)
    end

    # The list changed somewhere other than the card - the app, another device,
    # a Jil task - so every live card for it is brought back in line with what
    # is actually on it.
    def sync!(list)
      # A fresh query: the item that just changed often has its list's items
      # already loaded from before the change.
      names = ::ListItem.where(list_id: list.id).pluck(:name).to_set { |name| ::ListItem.format_name(name) }
      live_cards(list).each { |action|
        changed = false
        action.with_lock do
          buttons = (action.buttons || []).map(&:deep_dup)
          buttons.each { |btn|
            next if btn["status"].to_s == ::Buddy::Supersede::STATUS

            on_list = names.include?(::ListItem.format_name(btn["label"]))
            ticked  = btn["status"].to_s == "executed"
            next if on_list != ticked

            on_list ? reset(btn) : mark_ticked(btn)
            changed = true
          }
          action.update!(buttons: buttons) if changed
        end
        repaint(action) if changed
      }
    rescue StandardError => e
      ::Buddy::Errors.report(section: "list_checklist.sync", exception: e, user: list.owner)
      nil
    end

    def live_cards(list)
      scope = ByteAction.active.where(tool_name: "buddy_proposals")
      scope.where("tool_input->>'list_id' = ?", list.id.to_s)
    end

    def tick(action, btn)
      tool = ::Buddy::Tools[ITEM_TOOL]
      shape = { "id" => btn["id"], "payload" => btn["payload"], "tool_name" => btn["tool_name"] }
      ctx = ::Buddy::ToolContext.new(action.user, proposal: shape, conversation: action.byte_conversation)
      outcome = ::Buddy::Tools.dispatch(tool, btn["payload"].transform_keys(&:to_sym), ctx)
      return btn.merge!("status" => "failed", "error_message" => outcome[:error]) unless outcome[:ok]

      mark_ticked(btn)
      btn.merge!(
        "result"       => outcome[:data],
        "receipt"      => tool[:receipt].call(outcome[:data], ctx).to_s,
        "activity_ids" => [outcome[:activity_id]].compact,
      )
    end

    # A row ticked from the app has no removal of its own to reverse, so the
    # item is simply put back by name.
    def untick(action, btn)
      revert = btn.dig("result", "revert")
      if revert.present?
        ::Buddy::Reverter.call(revert)
        ::BuddyActivity.mark_undone!(btn["activity_ids"], note: revert["summary"])
      else
        list = ::List.find(action.tool_input["list_id"])
        list.list_items.add(btn["label"])
      end
      reset(btn)
    end

    def mark_ticked(btn)
      btn.merge!("status" => "executed", "undoable" => true)
      btn.delete("error_message")
      btn
    end

    # Back to a fresh row: nothing left on it for the undo machinery to find.
    def reset(btn)
      btn.merge!("status" => "pending", "undoable" => false)
      btn.except!("result", "receipt", "activity_ids", "error_message", "undo_note")
    end

    def repaint(action)
      message = action.byte_message
      return if message.nil?

      message.update!(metadata: (message.metadata || {}).merge("buttons" => action.reload.buttons))
      MonitorChannel.broadcast_to(action.user, {
        id:      :byte,
        channel: :byte,
        data:    { kind: :message, message: message.as_wire },
      })
    end

    def overflow_note(total)
      hidden = total - MAX_ROWS
      return nil if hidden < 1

      "_+#{hidden} more on the list._"
    end

    # Shaped like ProposalBuilder#build_button, minus the label proc: "Remove
    # Lock the back door" is the tool describing itself, and what belongs on the
    # row is the item, verbatim, the way it reads on the list.
    def button_for(list, item, id)
      payload = { "list" => list.name, "item" => item.name, "list_id" => list.id, "list_name" => list.name }

      {
        "id"         => id,
        "label"      => item.name,
        "tool_name"  => ITEM_TOOL.to_s,
        "payload"    => payload,
        "args"       => payload,
        "count"      => 1,
        "merge_key"  => ::Buddy::Tools[ITEM_TOOL][:merge_key].call(payload.symbolize_keys),
        "status"     => "pending",
        # Explicitly nothing. Every row on this card is the same tool, so the
        # per-row chip would print "Remove List Item" down the whole card in
        # the place the person is trying to read item names.
        "kind_label" => nil,
        "hint"       => HINT,
      }
    end

    def metadata_for(action, buttons)
      {
        "kind"              => "buddy_reply",
        "source"            => "list_checklist",
        "tool_name"         => "buddy_proposals",
        "action_request_id" => action.request_id,
        "action_kind"       => "custom",
        "action_state"      => "pending",
        "action_expires_at" => action.expires_at&.iso8601,
        "multi_select"      => true,
        "buttons"           => buttons,
      }
    end
  end
end
