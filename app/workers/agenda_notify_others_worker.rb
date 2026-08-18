# Fans out a Buddy heads-up to everyone else on a shared agenda when the
# actor checked "Notify others" while adding/updating an item (or creating a
# recurring event). Each recipient's OWN Buddy (Byte/Moss) composes the
# message from a seed, so it reads in-character — same delivery path as
# reminders/watches (Buddy::CompanionDelivery.deliver_prompt).
#
# Enqueued on a short delay from the controllers so the async travel-chain
# sync has usually stamped metadata["travel"] by the time the briefing is
# built — that lets the seed include travel time on brand-new events.
class AgendaNotifyOthersWorker
  include Sidekiq::Worker

  sidekiq_options queue: :default, retry: false

  # source_type: "AgendaItem" | "AgendaSchedule"
  # action:      "created" | "updated"
  def perform(source_type, source_id, actor_id, action)
    source = source_class(source_type)&.find_by(id: source_id)
    return if source.nil?

    actor = User.find_by(id: actor_id)
    return if actor.nil?

    agenda = source.agenda
    recipients(agenda, actor).each do |recipient|
      notify_one(source: source, actor: actor, recipient: recipient, action: action)
    end
  end

  private

  def source_class(source_type)
    return AgendaItem     if source_type.to_s == "AgendaItem"
    return AgendaSchedule if source_type.to_s == "AgendaSchedule"

    nil
  end

  # Everyone with access to the agenda except the actor, gated to users who
  # actually use Buddy (have a buddy conversation) so we never spin one up
  # for someone who's never opened it — mirrors Buddy::TodaySchedule's candidate set.
  def recipients(agenda, actor)
    agenda.access_users
      .where.not(id: actor.id)
      .where(id: ByteConversation.where(mode: :buddy).select(:user_id))
  end

  def notify_one(source:, actor:, recipient:, action:)
    seed = Buddy::AgendaBriefing.seed(source: source, actor: actor, recipient: recipient, action: action)
    return if seed.blank?

    Buddy::CompanionDelivery.deliver_prompt(
      user:         recipient,
      conversation: Buddy::CompanionRelay.conversation_for(recipient),
      seed:         seed,
      metadata:     { kind: "buddy_trigger", hidden: true, source: "agenda_notify", agenda_id: source.agenda_id },
    )
  rescue StandardError => e
    # One recipient's delivery failing must not drop the rest.
    Buddy::Errors.report(
      section:   "agenda_notify_others_worker.notify_one",
      exception: e,
      user:      recipient,
      extra:     { agenda_id: source.agenda_id },
    )
  end
end
