# A chore that got done by someone nobody named - a press on a board in a shared
# room, a logged event that more than one person could have caused. Rather than
# credit whoever happened to be signed in, it's marked done straight away by
# nobody (an anonymous stand-in, so every board and the Chores page show it
# done) and the person who owns the question is asked who it was. The answer
# hands that completion to the person named, at the time it was actually done.
#
# Every way in asks through here, so they all end the same way: answered, the
# stand-in becomes a real, paid completion; undone, the stand-in goes and so
# does the question about it.
#
# A chore's `who_did_it` settings widen the question:
#
#   ask:       "household" asks everyone in the household, a list of user ids
#              asks those of them who are in it. Each gets their own copy; the
#              first answer settles it and the other copies go.
#   questions: [{ key:, question:, prefill: }] free-text questions asked
#              alongside. A non-empty answer is stored in the event's data
#              under `key`. `prefill: "last"` starts it on the last answer
#              anyone gave it for this chore.
module ChoreWhoDidIt
  module_function

  SOURCE        = "ambiguous_chore".freeze
  WHO_QUESTION  = "Who did it?".freeze
  WHEN_QUESTION = "When?".freeze
  WAITING       = "Waiting to hear who did it".freeze

  # How close two completions of one chore have to be to be the same doing. An
  # answer reaches the bus more than once often enough to matter - a retried
  # job, the app and Buddy both submitting the same form.
  SAME_DOING = 1.second

  # Marks `chore` done by nobody yet and asks `user` who did it. The stand-in
  # goes on `stand_in_on` when that's a different row - a split chore's own
  # sub-chore - while the question stays about the chore as it's known. `extra`
  # rides along on the prompt for the caller's own bookkeeping. Every copy
  # carries `asked_for`, the person the doing is recorded under, so an answer
  # from anyone else still finds their event. Returns `user`'s own copy, or nil
  # when there's nobody to choose between.
  def ask!(user, chore, at:, stand_in_on: chore, extra: {})
    names = household_names(user)
    return nil if names.empty?

    stand_in = stand_in!(user, stand_in_on, at)
    prompts = recipients(user, chore).map { |person|
      person.prompts.create!(
        question: "Who did: #{chore.name}?",
        params:   extra.merge(
          source:        SOURCE,
          chore_name:    chore.name,
          chore_id:      chore.id,
          completion_id: stand_in.id,
          asked_for:     user.id,
        ),
        options:  options_for(person, chore, names, at),
      )
    }
    # A press, rather than a logged event, is the chore done with no event
    # behind it yet.
    ::RecordLinks::Propagator.log_stand_in_event(user, stand_in, prompts) if extra[:event_id].blank?
    prompts.each { |prompt|
      ::Jil.trigger(prompt.user, :prompt, prompt.with_jil_attrs(state: :create), auth: :link)
      # Asked where they already are, too: the question is one dropdown over a
      # time that's already right, and the app's prompt page is four steps away.
      ::Buddy::PromptDelivery.post!(prompt.user, prompt)
    }
    prompts.first
  end

  def options_for(person, chore, names, at)
    [
      {
        type:     :chips,
        question: WHO_QUESTION,
        choices:  names,
        default:  likely_doer(chore, names),
        colors:   ::PromptChips.colors(names),
      },
      { type: :datetime, question: WHEN_QUESTION, default: local_datetime(person, at) },
      *extra_questions(chore).map { |extra|
        { type: :text, question: extra[:question], default: prefill(chore, extra) }.compact
      },
    ]
  end

  def prefill(chore, extra)
    return unless extra[:prefill].to_s == "last"

    answered = ::Prompt.where.not(response: nil).where("params->>'source' = ?", SOURCE)
    answered = answered.where("params->>'chore_id' = ?", chore.id.to_s)
    answered = answered.where("NULLIF(TRIM(response->>?), '') IS NOT NULL", extra[:question])
    answered.order(updated_at: :desc).first&.response&.dig(extra[:question])
  end

  def settings(chore)
    chore.try(:who_did_it).to_h.with_indifferent_access
  end

  # Only ever people in the household, and `user` first, so their copy is the
  # one handed back.
  def recipients(user, chore)
    ask = settings(chore)[:ask]
    ids = Array(user.chore_household&.member_user_ids)
    if ask.is_a?(Array)
      ids &= ask.map(&:to_i)
    elsif ask.to_s != "household"
      ids = []
    end

    [user, *::User.where(id: ids).where.not(id: user.id).order(:id)]
  end

  def extra_questions(chore)
    Array(settings(chore)[:questions]).filter_map { |extra|
      extra = extra.to_h.with_indifferent_access
      extra if extra[:key].present? && extra[:question].present?
    }
  end

  # The answers to the chore's own questions, keyed for the event's data. One
  # left empty isn't an answer.
  def extra_answers(chore, response)
    extra_questions(chore).each_with_object({}) { |extra, answers|
      value = response[extra[:question]].to_s.strip
      answers[extra[:key].to_s] = value if value.present?
    }
  end

  # Whoever the doing is recorded under. A question asked before copies went to
  # anyone else carries no `asked_for`, and was always asked of them.
  def asked_for(prompt)
    params = prompt.params.to_h.with_indifferent_access
    ::User.find_by(id: params[:asked_for]) if params[:asked_for].present?
  end

  # The anonymous completion that stands until the question is answered.
  def stand_in!(user, chore, at)
    completion = ::ChoreCompletion.create!(
      chore:          chore,
      user:           user,
      completed_at:   at,
      day_key:        ::ChoreDay.current(user, at: at),
      payout_skipped: true,
      skipped_reason: WAITING,
      anonymous:      true,
    )
    related = (chore.parent_chore if chore.sub_chore?)
    ::ChoreBroadcaster.broadcast_changes!(user, chore, related: related)
    completion
  end

  def ours?(prompt)
    params = prompt.try(:params).to_h.with_indifferent_access
    params[:source].to_s == SOURCE
  end

  def waiting?(completion)
    completion.anonymous && completion.skipped_reason == WAITING
  end

  # The question was answered. The stand-in gives way to a real completion
  # credited to whoever was named - paid and streaked for them - and recorded by
  # the person who was asked, so their automations hear about it too. Returns
  # the time it was recorded at, or nil when the chore is gone.
  def answer!(user, prompt)
    params   = prompt.params.to_h.with_indifferent_access
    response = prompt.response.to_h.with_indifferent_access
    owner = asked_for(prompt) || user
    chore = find_chore(owner, params)
    return nil if chore.nil?

    who = ::User.find_by(username: response[WHO_QUESTION]) || user
    stand_in = ::ChoreCompletion.find_by(id: params[:completion_id], anonymous: true) if params[:completion_id].present?
    at = answered_time(user, response[WHEN_QUESTION], stand_in)

    # The event the question is about takes the answered time first, so the
    # completion below finds it as its partner instead of logging a second one.
    event = owner.action_events.find_by(id: params[:event_id]) if params[:event_id].present?
    if event
      answers = extra_answers(chore, response)
      attrs = { timestamp: at }
      attrs[:data] = event.data.to_h.merge(answers) if answers.any?
      event.update!(attrs)
    end

    # Before the stand-in goes: undoing it retracts every copy still open, and
    # that takes a logged event with it.
    close_other_copies!(prompt, by: user, at: at)
    ::ChoreCompletionUndoer.call(user, stand_in) if stand_in
    leaf = chore.completion_leaf_for(who)
    unless done_already?(leaf, at)
      ::ChoreCompleter.new(leaf, who, at: at, recorded_by: user).call
    end
    at
  end

  # The stand-in was undone before anyone answered, so there's no longer a
  # doing to ask about. Deleting the prompt is what closes the form Buddy posted
  # for it (see Prompt#settle_buddy_forms), and an event logged for the stand-in
  # goes too. An answered one is left alone - its stand-in goes as part of the
  # answer.
  def retract!(completion)
    return unless waiting?(completion)

    asked = copies_about(completion.id).to_a
    asked.each { |prompt| drop_logged_event!(prompt) }
    asked.each(&:destroy!)
  end

  # Every copy still open about one stand-in, whoever it was asked of.
  def copies_about(completion_id)
    asked = ::Prompt.unanswered.where("params->>'source' = ?", SOURCE)
    asked.where("params->>'completion_id' = ?", completion_id.to_s)
  end

  # Someone answered, so nobody else needs to. Each other copy's form settles
  # showing that answer before the copy goes, since deleting it alone would
  # settle the form as no longer needed with its defaults still in it.
  def close_other_copies!(prompt, by:, at:)
    completion_id = prompt.params.to_h.with_indifferent_access[:completion_id]
    return if completion_id.blank?

    response = prompt.response.to_h
    copies_about(completion_id).where.not(id: prompt.id).find_each { |copy|
      values = response.merge(WHEN_QUESTION => local_datetime(copy.user, at))
      ::Buddy::PromptDelivery.answered_elsewhere!(copy, by: by, values: values)
      copy.destroy!
    }
  end

  def drop_logged_event!(prompt)
    params = prompt.params.to_h.with_indifferent_access
    return unless params[:logged_event]

    owner = asked_for(prompt) || prompt.user
    event = owner.action_events.find_by(id: params[:event_id])
    return if event.nil?

    event.destroy!
    ::ActionEventNotifier.notify(owner, event, :removed, auth: :link)
  end

  # The answer's time, to the second. The form only holds minutes, so an
  # answer that left the time as it was given keeps the stand-in's exact
  # moment instead of rounding the completion down to the minute.
  def answered_time(user, raw, stand_in)
    given = parse_time(user, raw)
    original = stand_in&.completed_at
    return original || given || Time.current if given.nil?
    return original if original && given == original.in_time_zone(user.timezone).beginning_of_minute

    given
  end

  # The chore's assignee is offered first; anyone else is a pick away.
  def likely_doer(chore, names)
    name = chore.assigned_to_user&.username
    names.include?(name) ? name : ""
  end

  def household_names(user)
    ids = Array(user.chore_household&.member_user_ids)
    return [] if ids.empty?

    ::User.where(id: ids).order(:id).pluck(:username).compact_blank
  end

  # By id; by name for a question asked before the id was stored with it.
  def find_chore(user, params)
    chores = user.accessible_chores.active
    return chores.find_by(id: params[:chore_id]) if params[:chore_id].present?

    chores.detect { |c| c.name.to_s.casecmp(params[:chore_name].to_s).zero? }
  end

  # A re-answer that names someone ELSE is left alone rather than moved: the
  # payout was already worked out for whoever is on the row, and moving credit
  # is what editing the completion is for. Not scoped to a user - the person
  # named is usually not the one who was asked. A stand-in still waiting on
  # its own question isn't the doing being recorded already.
  def done_already?(chore, at)
    ::ChoreCompletion.where(
      chore_id:     chore.id,
      completed_at: (at - SAME_DOING)..(at + SAME_DOING),
    ).exists?(["skipped_reason IS DISTINCT FROM ?", WAITING])
  end

  # The field this lands in is `<input type="datetime-local">`, which takes a
  # local date and time and nothing else - an offset makes the value invalid,
  # and an invalid value renders as an empty box.
  def local_datetime(user, time)
    return nil if time.blank?

    time.in_time_zone(user.timezone).strftime("%Y-%m-%dT%H:%M")
  end

  # The form's value is local to the person asked, whatever zone this runs in.
  def parse_time(user, value)
    return nil if value.blank?
    return value if value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)

    user.parse_time(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end
end
