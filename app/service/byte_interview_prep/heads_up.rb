# The nudge two minutes before an interview: the link to join, or a heads-up
# that it is a call and the phone is about to ring.
#
# Hung off the same event as the brief, by the same Jil task, one trigger
# further along:
#
#   Interview event on the agenda
#     -> Jil "Interview Prep Schedule"  (-60 brief, -2 heads-up)
#       -> ScheduledTrigger "interview-join"
#         -> Jil "Interview Join"       (Interview.headsUp(itemId))
#           -> HERE: one message, with a push
#
# The link is rarely on our own row. Ours is written by a job beat and carries
# whatever the email said; the company's synced invite is where Google and
# Teams put the join link. So the twin - same minute, company in the title -
# is read as well, ours first.
module ByteInterviewPrep
  module HeadsUp
    module_function

    TRIGGER = "interview-join".freeze
    SOURCE = "interview_join".freeze

    # Hosts that are a call you JOIN. Deliberately a list rather than "any
    # URL": the notes are full of links - the application page, the calendar's
    # own "view event", `tel.meet` dial-ins - and none of them is the one to
    # tap with two minutes left.
    MEETING_HOSTS = [
      "meet.google.com",
      "zoom.us",
      "zoomgov.com",
      "teams.microsoft.com",
      "teams.microsoft.us",
      "teams.live.com",
      "webex.com",
      "whereby.com",
      "chime.aws",
      "meet.jit.si",
      "gotomeet.me",
      "meet.goto.com",
      "around.co",
      "hirevue.com",
      "coderpad.io",
      "codesignal.com",
      "hackerrank.com",
    ].freeze

    URL_RE = %r{https?://[^\s<>"')\]]+}

    # A street number then a word - "2600 W Executive Pkwy". A phone number in
    # the location field starts with a digit too, but never a digit and a space.
    ADDRESS_RE = /\A\s*\d+\s+[[:alpha:]]/

    PHONE_RE = /phone (?:call|screen|interview)|(?:will|'ll) call you|call you at|I will call/i

    # What the -2 minute trigger reaches. Production only for the reason
    # `ByteInterviewPrep.dispatch` gives: a dev box arms its own copy of every
    # trigger, and his phone would buzz twice.
    def dispatch(user, item_id)
      return :not_production unless ::Rails.env.production?

      item = ::AgendaItem.locate_for_user(item_id, user)
      return :no_event if item.nil?

      # The listener matches both rows of an interview; only ours names the
      # application, so the invite's own trigger stops here and he hears once.
      application = ByteInterviewPrep.application_for(item, user)
      return :not_an_interview if application.nil?

      send!(user, application: application, item: item)
    rescue StandardError => e
      ::Rails.logger.warn("[InterviewHeadsUp] failed: #{e.class}: #{e.message}")
      ::Buddy::Errors.report(section: "interview_heads_up", exception: e, user: user) if defined?(::Buddy::Errors)
      :failed
    end

    def send!(user, application:, item:)
      target = ::ByteConversation.for_self_initiated(user)
      return :no_thread if target.nil?
      return :already_sent if already_sent?(target, item)

      how = how(item, application, user)
      # In the building already, or on the way. A buzz with no link in it two
      # minutes before is just a buzz.
      return :in_person if how[:kind] == :in_person

      ::Buddy::CompanionDelivery.deliver_plain(
        user:         user,
        conversation: target,
        text:         said(application, how),
        metadata:     {
          "kind"           => "buddy",
          "source"         => SOURCE,
          "agenda_item_id" => item.id,
          "joins_by"       => how[:kind].to_s,
        },
        push_title:   "#{application.company} in 2 minutes",
      )
      how[:kind]
    end

    # A re-armed trigger can fire twice, and both rows of one interview carry
    # one; neither should be a second buzz.
    def already_sent?(target, item)
      scope = target.byte_messages.where("byte_messages.metadata ->> 'source' = ?", SOURCE)
      scope.exists?(["byte_messages.metadata ->> 'agenda_item_id' = ?", item.id.to_s])
    end

    # `{ kind: :link, url: }`, `{ kind: :in_person }`, or `{ kind: :phone, said: }`.
    #
    # An address on OUR row wins over a link on the invite: Google attaches a
    # Meet to every event it creates, so an onsite with a Meet link on the
    # invite is still an onsite.
    def how(item, application, user)
      return { kind: :in_person } if item.location.to_s.match?(ADDRESS_RE)

      rows = [item, *twins(item, application, user)]
      texts = rows.flat_map { |row| [row.location, row.notes] }
      url = texts.lazy.filter_map { |text| meeting_url(text) }.first
      return { kind: :link, url: url } if url

      { kind: :phone, said: rows.any? { |row| row.notes.to_s.match?(PHONE_RE) } }
    end

    # The company's synced invite: the same minute, on a calendar he can see,
    # with the company somewhere in the title.
    def twins(item, application, user)
      scope = user.accessible_agenda_items.event.not_cancelled.where(start_at: item.start_at)
      scope = scope.where.not(id: item.id)
      scope.where("agenda_items.name ILIKE ?", "%#{::AgendaItem.sanitize_sql_like(application.company)}%").to_a
    end

    def meeting_url(text)
      text.to_s.scan(URL_RE).find { |url| meeting_host?(url) }&.sub(/[.,;:!?]+\z/, "")
    end

    def meeting_host?(url)
      host = URI.parse(url).host.to_s.downcase
      MEETING_HOSTS.any? { |known| host == known || host.end_with?(".#{known}") }
    rescue URI::InvalidURIError
      false
    end

    def said(application, how)
      case how[:kind]
      when :link
        "#{application.company} starts in 2 minutes - here's the link.\n\n#{how[:url]}"
      when :phone
        if how[:said]
          "#{application.company} starts in 2 minutes - it's a phone call, keep your phone close."
        else
          "#{application.company} starts in 2 minutes. There's no link on the booking, " \
            "so it's probably a call - keep an eye on your phone."
        end
      end
    end
  end
end
