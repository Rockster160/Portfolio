module Buddy
  # Is this exact row already on that calendar?
  #
  # Three turns in three minutes can put the same two items on a calendar
  # twice, with the replies saying so out loud while the calls make the second
  # copy - *"I've got Start kitchen on tomorrow morning and Clear kitchen at
  # noon"*, *"that 9am kitchen start is already sitting there nicely"*. The next
  # morning's briefing then reads each of them twice.
  #
  # `ToolContext#existing_agenda_twin` had already found them: it looks an hour
  # either side and its note goes up in the ack the model reads before it writes
  # a word. That note is the right shape for a NEAR miss - two real errands can
  # legitimately collide, and refusing one of those is worse than a duplicate -
  # but for the same name on the same calendar at the same minute there is
  # nothing to weigh, and being told was not enough twice in one evening.
  #
  # So this is the exact case only, and it raises. Everything looser stays with
  # the twin note.
  module AgendaDuplicate
    module_function

    def existing(agenda_id, title, at)
      return nil if agenda_id.blank? || title.blank? || at.blank?

      start = at.respond_to?(:strftime) ? at : (::Time.zone.parse(at.to_s) rescue nil)
      return nil if start.nil?

      AgendaItem.where(
        agenda_id: agenda_id,
        start_at:  start,
      ).where(
        "LOWER(name) = ?", title.to_s.downcase.strip
      ).where.not(
        status: :cancelled,
      ).order(:id).first
    end

    # The message is the whole point of raising here rather than dropping the
    # call: it names the row that already exists and the tool that can change it,
    # so the turn recovers into an edit instead of dead-ending.
    def check!(agenda_id, title, at, zone: nil)
      row = existing(agenda_id, title, at)
      return nil if row.nil?

      when_ = row.start_at.in_time_zone(zone || ::Time.zone)
      raise "#{row.name} is already on #{row.agenda&.name || "that calendar"} at " \
            "#{Buddy::Clock.date_at(when_)} - adding it again leaves the first one " \
            "where it is and gives them two. If something about it is changing, that's " \
            "edit_agenda_item; if nothing is, it's already done and you can just say so"
    end
  end
end
