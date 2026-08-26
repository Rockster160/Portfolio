# Prod 4744-4750, 26 Aug. "Every night at 9pm, can you add these items to that
# list:" was answered first with a claim that never ran, and then, when he asked
# for it properly, with "I can't make list items recur on a schedule, so I've put
# that request on the list instead."
#
# The refusal was true and should never have been. Adding a list item is
# something Buddy does; putting a thing on the clock is something Buddy does;
# and `BuddyReminder#action` has always stored `{tool:, payload:}` and fired it
# with no model turn behind it. Both halves existed and nothing joined them, so
# the answer to "add these three every night" was a feature request.
#
# The first fix built a per-user Jil function and scheduled THAT, which is the
# wrong shape twice over: it makes a plain capability into something each person
# has to have a custom automation for, and it routes a list write through the
# automation engine to reach a tool sitting right there.
Buddy::Tools.register(
  name:        :schedule_list_items,
  description: <<~TXT,
    Put items onto a list LATER, once or on a repeat. "Add these to Before Bed
    every night at 9", "put the bin bags on the shopping list every Sunday
    morning", "add the packing items to Camping on Friday".

    Several items in one go: `items` is one per line, and they land together as
    one set of rows on one card, the same as if they'd been asked for now.

    ## Which of the list tools

      add_list_item        - one item, right now. Still the one for
                             "add milk to the shopping list".
      schedule_list_items  - anything with a WHEN on it. This one.

    ## Arguments

      list    - fuzzy list name, resolved now so a name that matches nothing
                comes back while they're still here to say which they meant.
      items   - the items, one per line, in their own words.
      at      - when to add them (ISO datetime). Required unless `repeat` is set.
      repeat  - a recurrence, the same spellings `schedule_reminder` takes
                ("daily:21:00", "weekdays:07:30", "weekly:sun:09:00").
      until   - stop repeating after this date (YYYY-MM-DD).
      section - a heading on the list to file them all under, exactly as it is
                spelled in `lists`.
      note    - the line to show in the thread when it runs, in their words.

    It repeats until they cancel it. They can see it in `upcoming_reminders`
    and call it off with `cancel_reminder`, the same as anything else on the
    clock, and the items it adds are ordinary list rows they can tick or
    remove.
  TXT
  feature:     :lists,
  args:        {
    list:    { type: :string, required: true,  description: "Fuzzy list name" },
    items:   { type: :string, required: true,  description: "The items, one per line, in their own words" },
    at:      { type: :string, required: false, description: "When to add them (ISO datetime). Required unless `repeat` is set." },
    repeat:  { type: :string, required: false, description: "Recurrence spec: daily:HH:MM / weekdays:HH:MM / weekly:<days>:HH:MM / monthly:<dom>:HH:MM / every:<n>-<unit>:HH:MM" },
    until:   { type: :string, required: false, description: "Stop repeating after this date (YYYY-MM-DD)" },
    section: { type: :string, required: false, description: "Section on the list to file them under - an exact name from `lists`" },
    note:    { type: :string, required: false, description: "The line to show in the thread when it runs, in their words" },
  },
  auto:        true,
  confirm:     ->(payload, ctx) {
    lines = payload[:items].to_s.split("\n").map(&:strip).compact_blank
    raise "nothing to add" if lines.empty?

    # Resolved through add_list_item's OWN confirm, never a copy of it. That is
    # where the list lookup, the section matching and `ListItemName.tidy` all
    # live, and a second implementation of any of them would drift from the one
    # that runs. It also means a bad list name fails HERE, while they're still
    # in the conversation, rather than silently at 9pm tomorrow.
    adder = Buddy::Tools[:add_list_item]
    rows  = lines.map { |line|
      args = { list: payload[:list], item: line, section: payload[:section] }.compact
      # Called for the CHECK, not for what it returns. What gets stored is
      # `args` - the same raw shape the model would have passed - so the list,
      # the section and the wording are all resolved again at fire time. Storing
      # the resolved ids instead would freeze a list id into a row that repeats
      # nightly for months, and a renamed or rebuilt list would go quietly
      # nowhere. Same reason `schedule_function` stores a function NAME.
      adder[:confirm].call(args, ctx)
      args
    }
    list_name = ctx.resolve_list(payload[:list])&.name

    recurrence = Buddy::RepeatSpec.parse(payload[:repeat], on: ctx.user.perceived_today)
    raise "unknown repeat spec #{payload[:repeat].inspect}" if payload[:repeat].to_s.strip.present? && recurrence.nil?

    if recurrence && payload[:until].to_s.strip.present?
      ends = (Date.parse(payload[:until].to_s) rescue nil)
      raise "couldn't read #{payload[:until].inspect} as a date" if ends.nil?

      recurrence = recurrence.merge("until_on" => ends.iso8601)
    end

    fire_at   = ctx.resolve_time(payload[:at]) if payload[:at].to_s.strip.present?
    fire_at ||= BuddyReminder.new(user: ctx.user, recurrence: recurrence).next_fire_at(from: Time.current) if recurrence
    raise "couldn't work out when to add them" if fire_at.nil?
    raise "that time has already passed" if fire_at < Time.current

    when_str = fire_at.in_time_zone(ctx.user.timezone).strftime("%a %-I:%M %p")
    count    = "#{rows.length} #{"item".pluralize(rows.length)}"
    summary  = (
      if recurrence
        "Add #{count} to **#{list_name}** repeatedly, starting #{when_str}?"
      else
        "Add #{count} to **#{list_name}** at #{when_str}?"
      end
    )

    {
      summary:  summary,
      resolved: {
        list_name:   list_name,
        rows:        rows,
        fire_at_iso: fire_at.iso8601,
        recurrence:  recurrence,
      }.compact,
    }
  },
  label:       ->(payload, ctx) {
    fire_at = (Time.zone.parse(payload[:fire_at_iso].to_s) rescue nil)
    when_s  = (
      if payload[:recurrence]
        "repeats #{payload[:repeat]}"
      else
        fire_at&.in_time_zone(ctx.user.timezone)&.strftime("%a %-I:%M %p")
      end
    )
    items = Array(payload[:rows]).map { |r| r.to_h.symbolize_keys[:item] }.compact
    { title: "#{items.length} → #{payload[:list_name]}", sub: [when_s, *items].compact_blank.join("\n") }
  },
  level:       2,
  execute:     ->(payload, ctx) {
    conversation = ByteConversation.for_self_initiated(ctx.user)
    raise "no conversation to add them in" if conversation.nil?

    rows = Array(payload[:rows]).map { |row|
      { "tool" => "add_list_item", "payload" => row.to_h.transform_keys(&:to_s) }
    }

    reminder = BuddyReminder.create!(
      user:              ctx.user,
      byte_conversation: conversation,
      kind:              :reminder,
      body:              payload[:note].to_s.presence || "Adding those to #{payload[:list_name]}.",
      fire_at:           Time.zone.parse(payload[:fire_at_iso].to_s),
      recurrence:        payload[:recurrence],
      action:            rows,
    )
    {
      reminder_id: reminder.id,
      list_name:   payload[:list_name].to_s,
      count:       rows.length,
      fire_at:     reminder.fire_at.iso8601,
      recurrence:  payload[:recurrence],
    }
  },
  receipt:     ->(result, ctx) {
    fire_at = (Time.zone.parse(result[:fire_at].to_s) rescue nil)
    count   = "#{result[:count]} #{"item".pluralize(result[:count].to_i)}"
    rec     = result[:recurrence]

    if rec.is_a?(Hash)
      "#{ctx.buddy_name} will add #{count} to **#{result[:list_name]}** #{Buddy::ReminderPresenter.repeat_phrase(rec)}"
    else
      "#{ctx.buddy_name} will add #{count} to **#{result[:list_name]}** #{ctx.friendly_future(fire_at)}"
    end
  },
)
