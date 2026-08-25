module Buddy
  # A list, handed over as tickable boxes instead of as prose.
  #
  # Byte already has a checklist - every proposal it makes arrives as a row with
  # a box, and ticking one runs it. This posts one that nothing was proposed
  # for: the rows ARE the list, one per item, and ticking a box takes that item
  # off the list exactly the way checking it off in the app does.
  #
  # So it reuses `buddy_proposals` wholesale rather than growing a second
  # checklist shape - same renderer, same POST, same executor, same
  # untick-to-put-it-back. The only thing different is who wrote the rows.
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

    # Returns how many boxes went up. 0 means nothing was posted at all: an
    # empty list has nothing to check off, and a bubble saying so is a
    # notification about nothing.
    def post!(user:, list:, text:)
      conversation = ::Buddy::CompanionRelay.conversation_for(user)
      items = list.list_items.to_a
      return 0 if conversation.nil? || items.empty?

      buttons = items.each_with_index.map { |item, i| button_for(list, item, i + 1) }
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
        text:         text,
        metadata:     metadata_for(action, buttons),
        push_title:   text,
      )
      action.update!(byte_message_id: message.id)
      items.size
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
