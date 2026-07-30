# Materializes a user's contact birthdays into a dedicated, read-only
# "Birthdays" calendar as yearly all-day AgendaSchedule rows — the same
# "sync an external source into real rows" pattern the Google calendar sync
# uses. Contacts stay the source of truth; the schedules are derived and
# regenerated from them (keyed back by metadata["birthday_contact_id"]).
#
# Kept read-only so the calendar UI won't offer to edit a derived event —
# edits belong on the contact. Jil `:agenda_schedule` triggers are suppressed
# so bulk generation doesn't spam "new event" automations.
class BirthdaySync
  AGENDA_NAME = "Birthdays".freeze
  AGENDA_SLUG = "birthdays".freeze
  AGENDA_COLOR = "#E5679E".freeze
  CONTACT_KEY = "birthday_contact_id".freeze

  # Recurrence anchor year for a birthday with no known year. The contact
  # holds the real (year-less) birthday; this is only the rule's anchor, and
  # a leap year keeps Feb 29 valid.
  ANCHOR_FALLBACK_YEAR = 2000

  def self.call(user)
    new(user).sync_all
  end

  def self.sync_contact(contact)
    new(contact.user).sync_contact(contact)
  end

  def self.remove_contact(contact)
    new(contact.user).sync_contact(contact, force_remove: true)
  end

  def initialize(user)
    @user = user
  end

  # Full reconcile: upsert a schedule for every birthday-bearing contact and
  # prune schedules whose contact no longer has a birthday (or is gone).
  def sync_all
    suppress {
      contacts = @user.contacts.where.not(birth_month: nil).where.not(birth_day: nil)
      kept_ids = contacts.map { |contact| upsert_schedule(contact).id }
      agenda.agenda_schedules.where.not(id: kept_ids).destroy_all
    }
    agenda
  end

  # Single-contact sync, driven by the Contact after_commit hook.
  def sync_contact(contact, force_remove: false)
    suppress {
      if !force_remove && contact.birth_month && contact.birth_day
        upsert_schedule(contact)
      else
        remove(contact)
      end
    }
  end

  private

  # Created lazily — only when there's actually a birthday to store, so a
  # user with no birthday-bearing contacts never gets an empty calendar.
  def agenda
    @agenda ||= @user.agendas.create_with(
      name:      AGENDA_NAME,
      source:    :user,
      read_only: true,
      color:     AGENDA_COLOR,
    ).find_or_create_by!(parameterized_name: AGENDA_SLUG)
  end

  def existing_agenda
    return @existing_agenda if defined?(@existing_agenda)

    @existing_agenda = @user.agendas.find_by(parameterized_name: AGENDA_SLUG)
  end

  def upsert_schedule(contact)
    schedule = find_schedule(contact, existing_agenda) || agenda.agenda_schedules.new
    schedule.assign_attributes(
      kind:             :event,
      name:             "#{contact_label(contact)}'s Birthday",
      all_day:          true,
      start_time:       "00:00",
      duration_minutes: 1440,
      recurrence:       { "freq" => "yearly" },
      starts_on:        anchor_date(contact),
      metadata:         { CONTACT_KEY => contact.id },
    )
    schedule.save!
    schedule
  end

  # Never creates the agenda — removing a birthday from a contact that never
  # had one is a no-op.
  def remove(contact)
    return unless existing_agenda

    find_schedule(contact, existing_agenda)&.destroy
  end

  def find_schedule(contact, scope_agenda)
    return nil if scope_agenda.nil?

    scope_agenda.agenda_schedules.where("metadata ->> ? = ?", CONTACT_KEY, contact.id.to_s).first
  end

  def contact_label(contact)
    [contact.name, contact.last_name].compact_blank.join(" ").presence || contact.name
  end

  def anchor_date(contact)
    ::Date.new(contact.birth_year || ANCHOR_FALLBACK_YEAR, contact.birth_month, contact.birth_day)
  rescue ::Date::Error
    ::Date.new(ANCHOR_FALLBACK_YEAR, contact.birth_month, contact.birth_day)
  end

  # Reuse the schedule model's existing trigger-suppression flag so derived
  # birthday writes don't fire user `:agenda_schedule` automations.
  def suppress
    key = ::GoogleCalendar::Sync::SUPPRESS_KEY
    previous = Thread.current[key]
    Thread.current[key] = true
    yield
  ensure
    Thread.current[key] = previous
  end
end
