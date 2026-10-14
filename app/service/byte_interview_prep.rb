# The brief for an interview, written an hour before it starts.
#
# An hour out is when the question stops being "is this worth applying to" and
# becomes "what is this conversation and what do I need in my head for it". A
# recruiter call wants company facts and a reason to be interested; a technical
# screen wants the stack it will be in and the things worth going over first.
# Which of those it is has to be worked out from the booking rather than asked,
# because there is nobody to ask an hour before.
#
# The chain, and it is deliberately the standup brief's chain (see
# ByteStandupPrep, which this is modelled on and which documents most of the
# reasoning at length):
#
#   Interview event on the agenda
#     -> Jil "Interview Prep Schedule"  (-60 minutes, hung off the event)
#       -> ScheduledTrigger             (follows the event when it moves)
#         -> Jil "Interview Prep"       (Interview.prep(itemId))
#           -> HERE: a read-only `claude -p` on the Mac
#             -> InterviewPrep record + one push carrying the link
#
# The Jil half is in Jil on purpose: when it fires, whether it fires at all,
# and what it fires on are his to change without a deploy. What it reaches is
# here, because a local Claude session is not something Jil can express.
#
# Nothing is said to him when the session starts. The prompt is `hidden` and
# the thread is archived, so the first he hears of it is the finished brief -
# an hour before an interview, a buzz saying "started researching" is a buzz
# that costs attention and carries nothing.
#
# READ-ONLY, enforced by the machine and not by the prompt: the conversation
# sits in `permission_mode: "read"` and the Mac's PreToolUse hook answers every
# call itself from a fixed list - reads, greps, WebSearch and WebFetch - and
# denies the rest outright rather than posting a card nobody is there to tap.
module ByteInterviewPrep
  module_function

  NAME = "Interview Prep".freeze

  # What the -60 minute ScheduledTrigger fires, and the name the trigger row
  # carries. One name for both, the way "standup-prep" is.
  TRIGGER = "interview-prep".freeze

  # Where the session sits. The job hunt's own directory: always on the
  # internal disk, and `profile/profile.yml` is the maintained statement of
  # what he does, what he wants, and what he is asking for.
  CWD = "/Users/zoro/code/jobhunt".freeze

  # The resume repo, which is where the resume, the accomplishments and the
  # behavioral answers he has already written actually live. It is on an
  # external volume, so the prompt asks for it conditionally - an unmounted
  # drive must cost a paragraph of the brief, not the brief.
  RESUME_REPO = "/Volumes/RoccoBackup/Rocco/Me/Resume".freeze

  # The local posting: the description as it was scraped, which is the best
  # single source of what a technical conversation will be about. jobhunt runs
  # on the same machine as the session, so this is reachable there and nowhere
  # else - and best-effort, because the machine may be the only thing awake.
  JOBHUNT_URL = "http://localhost:8790".freeze

  def conversation(user)
    convo = user.byte_conversations.find_by(name: NAME)
    return sync!(convo) if convo

    user.byte_conversations.create!(
      name:            NAME,
      mode:            :claude,
      archived:        true,
      last_message_at: Time.current,
      metadata:        base_metadata,
    )
  end

  # Reasserted every run, for the two reasons the standup thread documents:
  # the pwd bar's toggle only knows `auto` and `ask`, so one tap silently
  # downgrades `read` to a mode an allow rule can widen; and this thread is
  # machinery rather than a place, so unarchived it sits in the list with an
  # unread count for a brief already read somewhere else.
  def sync!(convo)
    wanted = convo.metadata.to_h.merge(base_metadata)
    convo.update!(mode: :claude) unless convo.claude?
    convo.update!(archived: true) unless convo.archived?
    convo.update!(metadata: wanted) if convo.metadata.to_h != wanted
    convo
  end

  def base_metadata
    { "cwd" => CWD, "permission_mode" => "read", "interview_prep" => true }
  end

  # ==========================================================================
  # Which interview, and whether to write about it at all
  # ==========================================================================

  # THE FIRST LINE OF THE EVENT NOTES IS THE APPLICATION.
  #
  # `JobNote#item_notes` writes `job_application.interview_url` first on every
  # row a beat puts on the calendar, precisely so the row read on the day leads
  # back to the board. That makes it the handle here too.
  #
  # It is also what separates the two rows one interview has: the internal row
  # is ours and carries the link, and the company's synced invite carries the
  # event description that goes back out to every attendee. Both match a
  # listener looking for "interview" in the title; only one answers this.
  def application_for(item, user)
    id = item&.notes.to_s.lines.first.to_s[%r{/interviews/(\d+)}, 1]
    return nil if id.blank?

    user.job_applications.find_by(id: id)
  end

  # Already written, or already being written. Two different races:
  #
  # A trigger whose event is touched again re-arms and can fire twice, and a
  # second session started while the first is still researching spends ten
  # minutes to produce a duplicate.
  #
  # Keyed on the booking rather than on the day, because two interviews with
  # the same company on one day is a real shape - a recruiter screen in the
  # morning and the hiring manager in the afternoon are two conversations and
  # want two briefs.
  def already_prepped?(application, item)
    return false if item.nil?

    return true if application.preps.exists?(agenda_item_id: item.id)

    scope = conversation(application.user).byte_messages.where(direction: :outbound)
    scope = scope.where("byte_messages.metadata ->> 'agenda_item_id' = ?", item.id.to_s)
    scope.where.not(byte_messages: { state: :failed }).exists?
  end

  # ==========================================================================
  # Running it
  # ==========================================================================

  # Kick one by hand:
  #
  #   ByteInterviewPrep.kick!(item_id: 12345)
  #   ByteInterviewPrep.kick!(application: JobApplication.find(7))
  #
  # Ignores "already prepped", which is a guard against a trigger firing twice
  # and would otherwise do nothing at the exact moment somebody is watching.
  def kick!(item_id: nil, application: nil, user: User.me)
    item = item_id && ::AgendaItem.locate_for_user(item_id, user)
    application ||= application_for(item, user)
    raise "no application for that one" if application.nil?

    run!(user, application: application, item: item, force: true)
  end

  # Post the prompt and return. The Mac does the work and streams the report
  # back into this thread; `submit!` turns it into a record and sends the link
  # when it settles.
  def run!(user, application:, item: nil, force: false)
    return :already_prepped if !force && already_prepped?(application, item)

    convo = conversation(user)

    # Fresh session, and it has to land before the prompt does - /byte/incoming
    # answers 202 and runs the turn on a thread, so a reset sent as a message
    # races the prompt it is meant to precede. It matters more here than it does
    # for the standup brief: the thread is reused for every interview, and a
    # resumed session arrives already believing it knows which company this is.
    ByteLocal.reset_claude_session(conversation_id: convo.id)
    convo.update!(
      metadata: convo.metadata.to_h.merge("claude_session_id" => nil, "claude_session_name" => nil),
    )

    ByteMessageIntake.call(
      user:         user,
      conversation: convo,
      body:         Brief.text(application, item, user: user),
      metadata:     {
        "interview_prep"     => true,
        "hidden"             => true,
        "job_application_id" => application.id,
        "agenda_item_id"     => item&.id,
        "interview_at"       => item&.start_at&.iso8601,
      },
    )
    :sent
  end

  # What the -60 minute trigger reaches, through Jil's `Interview.prep`. The
  # agenda item id is carried in the trigger's own data because the fired
  # payload is `{ timestamp: }` merged with it and nothing else - the source
  # item does not ride along.
  #
  # Production only, for the reason DailyAuditWorker documents: a dev box runs
  # its own copy of the schedule, both answer "no" to already-prepped, and
  # ByteLocal reaches the SAME Mac from either - so the second run spends a
  # session researching the same company and files a duplicate brief.
  def dispatch(user, item_id)
    return :not_production unless ::Rails.env.production?

    item = ::AgendaItem.locate_for_user(item_id, user)
    return :no_event if item.nil?

    application = application_for(item, user)
    return :not_an_interview if application.nil?

    run!(user, application: application, item: item)
  rescue StandardError => e
    ::Rails.logger.warn("[InterviewPrep] failed: #{e.class}: #{e.message}")
    ::Buddy::Errors.report(section: "interview_prep", exception: e, user: user) if defined?(::Buddy::Errors)
    :failed
  end

  # ==========================================================================
  # The brief landing
  # ==========================================================================

  # The report has finished streaming: file it against the application and send
  # the link.
  #
  # Called from WebhooksController#byte_update on the transition to
  # `delivered`, which is the only completion signal there is - the Mac creates
  # the row as "..." and updates it as it streams.
  #
  # Guarded the same three ways the standup brief is, because this thread is a
  # real thread somebody can type in: right thread, a claude reply, answering a
  # prompt that carries `interview_prep`.
  def submit!(message) # rubocop:disable Naming/PredicateMethod -- it files; the boolean is whether it did
    convo = message.byte_conversation
    return false unless convo&.name == NAME
    return false unless message.metadata.to_h["kind"] == "claude"

    parent = prompt_message(message)
    return false if parent.nil?

    meta = parent.metadata.to_h
    # Scoped through the thread's own owner, not looked up globally. The only
    # thing that reaches here is a reply to a prompt this module wrote, but an
    # id out of message metadata is not a fact about whose application it is,
    # and a brief must never be filed against somebody else's row.
    application = message.user.job_applications.find_by(id: meta["job_application_id"])
    return false if application.nil?

    prep = file!(message, application, meta)
    return false if prep.nil?

    announce!(prep)
    true
  end

  def file!(message, application, meta)
    prep = ::InterviewPrep.from_report(
      message.body,
      job_application: application,
      agenda_item_id:  still_there(meta["agenda_item_id"]),
      byte_message_id: message.id,
      interview_at:    meta["interview_at"],
    )
    return nil unless prep.save

    application.touch_activity!
    prep
  end

  # The booking, if it is still a row by the time the brief lands. A recurring
  # occurrence resolves to a phantom whose id is not a number, and an event can
  # be deleted while the session is researching it - both would be a foreign key
  # violation on a record that is otherwise perfectly good.
  def still_there(id)
    return nil if id.blank? || !id.to_s.match?(/\A\d+\z/)

    id if ::AgendaItem.exists?(id: id)
  end

  # ONE message, carrying the link. The brief itself is not pasted into the
  # thread: it is a page of markdown with headings, and the thing being asked
  # for here is "open this now", which is a line and a link.
  def announce!(prep) # rubocop:disable Naming/PredicateMethod -- it sends; the boolean is whether it did
    target = ::ByteConversation.for_self_initiated(prep.job_application.user)
    if target.nil?
      # Filed but unannounced. Said out loud because the brief being written
      # and the brief being READ are not the same event, and the whole job is
      # the second one.
      ::Rails.logger.warn("[InterviewPrep] filed ##{prep.id} with no thread to send it to")
      return false
    end

    ::Buddy::CompanionDelivery.deliver_plain(
      user:         prep.job_application.user,
      conversation: target,
      text:         "#{said(prep)}\n\n#{prep.prep_url}",
      metadata:     { "kind" => "buddy", "source" => "interview_prep", "interview_prep" => true },
      push_title:   "#{prep.job_application.company} prep",
    )
    true
  end

  def said(prep)
    when_said = (
      if prep.interview_at.present?
        at = prep.interview_at.in_time_zone(prep.job_application.user.timezone)
        "at #{at.strftime("%-I:%M %p")}"
      else
        "coming up"
      end
    )

    "#{prep.job_application.company} #{when_said}. " \
      "Here's the prep - #{prep.kind_label || "the brief"}."
  end

  # The prompt this is answering, when it is answering one at all. A reply
  # typed into this thread by hand answers a different parent and is left where
  # it was written.
  def prompt_message(message)
    parent_id = message.metadata.to_h["in_reply_to"]
    return nil if parent_id.blank?

    parent = ::ByteMessage.find_by(id: parent_id)
    parent if parent && parent.metadata.to_h["interview_prep"].present?
  end
end
