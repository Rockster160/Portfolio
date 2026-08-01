# A sequence that stopped to ask someone a question, and never got an answer.
#
# Every other gate resolves on its own: a countdown finishes, and a checklist or
# a form sits in the thread where the person can see it. A relay gate is
# invisible and depends on a DIFFERENT person choosing to reply, so left alone
# it either fires days late or never, and both read as the sequence having
# quietly finished.
#
# So the gate carries an expiry (ProposalBuilder::AWAIT_TTL) and this closes out
# the ones that reached it, saying what didn't happen. The queue is dropped
# rather than run: everything behind the question was about the answer.
class BuddyAwaitSweepWorker
  include Sidekiq::Worker

  sidekiq_options queue: :low, retry: 1

  BATCH = 200

  def perform
    stale = ByteAction.where(tool_name: Buddy::ProposalBuilder::RELAY_GATE, state: :pending)
      .where.not(expires_at: nil)
      .where(expires_at: ...Time.current)
      .limit(BATCH)

    stale.each { |action| give_up(action) }
  end

  private

  def give_up(action)
    queue = nil
    action.with_lock do
      queue = Buddy::ProposalBuilder.claim_deferred(action)
      action.update!(state: :expired)
    end
    return if queue.blank?

    Buddy::ProposalBuilder.abandon_queue!(action, queue, because: waiting_on(action))
  rescue StandardError => e
    Buddy::Errors.report(
      section:   "buddy_await_sweep",
      exception: e,
      user:      action.user,
      extra:     { byte_action_id: action.id },
    )
  end

  # Names the person, because "nobody answered" is unhelpfully vague in a
  # household of several.
  def waiting_on(action)
    relay = BuddyRelay.find_by(id: action.tool_input["relay_id"])
    name  = relay&.to_user&.first_name
    name ? "#{name} never answered" : "nobody answered"
  end
end
