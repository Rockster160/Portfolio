module Buddy
  # The search box's question asked for Buddy: every kind of record at once,
  # for a name that could belong to any of them.
  #
  # GlobalSearch already scopes each kind the way its own page does, so this
  # adds only what a model needs to go on from a hit: the id in the form the
  # acting tools take, the calendar (which the box leaves to its own page), and
  # per group the tools that act on that kind. Those are filtered to what this
  # person is offered, so a group never points at a tool their account lacks.
  module SearchEverything
    module_function

    PER_GROUP = 5

    # The calendar is searched both ways from today, a year out, so a name that
    # is only an appointment still turns up whichever side of now it sits.
    AGENDA_DAYS = 365

    ACTS_WITH = {
      chores:     %i[complete_chore edit_chore pin_chore chore_history],
      events:     %i[log_event search_events edit_event delete_event],
      lists:      %i[show_list add_list_item],
      list_items: %i[edit_list_item remove_list_item],
      boxes:      %i[search_inventory edit_inventory_item remove_inventory_item show_inventory_image],
      agenda:     %i[search_agenda edit_agenda_item],
      contacts:   %i[contact_address],
      emails:     %i[search_email],
      stash:      %i[search_ideas read_idea],
      memories:   %i[search_memories],
    }.freeze

    # Places to open rather than records to act on, which a model has no use
    # for and would only read as more matches.
    SKIPPED = %i[areas pages timer_pages].freeze

    def call(user:, query:, conversation: nil)
      return [] if query.to_s.strip.empty?

      offered = Buddy::Tools.offered(user: user, conversation: conversation).to_set { |tool| tool[:name] }
      groups = GlobalSearch.call(user, query, limit: PER_GROUP).reject { |group| SKIPPED.include?(group[:group]) }
      groups = groups.map { |group|
        {
          kind:      group[:group],
          label:     group[:label],
          hits:      group[:results].map { |hit| hit_row(group[:group], hit) },
          acts_with: ACTS_WITH.fetch(group[:group], []).select { |name| offered.include?(name) },
        }
      }
      agenda = agenda_group(user, query, offered)
      agenda ? groups.push(agenda) : groups
    end

    # The id leads, written the way the group's tools take it.
    def hit_row(kind, hit)
      id = kind == :boxes ? "##{hit[:id]}" : hit[:id]
      [id, hit[:title], hit[:subtitle]].compact_blank.join(" · ")
    end

    def agenda_group(user, query, offered)
      acts = ACTS_WITH[:agenda].select { |name| offered.include?(name) }
      return if acts.empty?

      found = Buddy::AgendaSearch.call(user: user, query: query, direction: :any, days: AGENDA_DAYS, limit: PER_GROUP)
      return if found[:items].empty?

      {
        kind:      :agenda,
        label:     "Calendar",
        hits:      Buddy::AgendaSearch.rows(found[:items], user, found[:sources]),
        acts_with: acts,
      }
    end
  end
end
