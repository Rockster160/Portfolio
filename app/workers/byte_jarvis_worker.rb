# Handles a single Byte message bound for Jarvis: a whole conversation in
# :jarvis mode, a "/j" from any thread, or a "." aside in a Buddy one. Sends the
# body through Jarvis and posts the response back as an inbound message on the
# same conversation.
#
# Jarvis mode intentionally skips the Mac local server — Jarvis lives
# entirely in Rails and doesn't need a shell / Claude CLI wrapper. Keeps
# the round-trip in-process, faster than a webhook bounce.
class ByteJarvisWorker
  include Sidekiq::Worker
  sidekiq_options queue: :default, retry: 3

  def perform(message_id)
    message = ByteMessage.find_by(id: message_id)
    return if message.nil?

    conversation = message.byte_conversation
    user         = message.user
    return if conversation.nil? || user.nil?

    # Mark the user's send as sent so the composer's pending state clears.
    message.update!(state: :sent) if message.state == "pending"

    # The prefix is our routing marker, not part of what they said.
    body = ByteMessageIntake.jarvis_words(message.body)
    return if body.empty?

    # Say that it's in hand, before it is.
    #
    # `Jarvis.command` runs the whole Jil chain inline, so a house command takes
    # exactly as long as the house takes to answer. Prod, 26 Aug 16:49: ".close
    # blinds" reached a Home Assistant that was down, the POST sat on
    # RestClient's 60-second read timeout, and the thread showed NOTHING for a
    # full minute - no receipt, no pending state, no face. The reply when it
    # came was correct ("the house didn't take that one"), but for that minute
    # there was no way to tell a stalled command from one that never sent.
    #
    # Both halves, because they answer different questions. The face says the
    # companion is busy; the BUBBLE says this particular command is what it's
    # busy with, and it sits in the thread under the words they typed. Buddy's
    # own turns have always had both; a Jarvis aside is the one route into a
    # Buddy thread that had neither, and it's the route with the longest wait
    # on it.
    #
    # The bubble is the reply itself, opened early rather than a second row that
    # would have to be reconciled: every path below either fills it in or drops
    # it. Settled in the ensure so a raise can't leave the pet thinking forever.
    Buddy::ExpressionState.thinking!(conversation)
    reply = open_reply(user, conversation, message)

    ran      = []
    response = ::Jarvis.command(user, body) { |tasks| ran = tasks }
    text     = response.is_a?(Array) ? response.first.to_s : response.to_s
    data     = response.is_a?(Array) ? (response.last || {}) : {}

    # Before the reply, in the order they ran: a spoken command leaves the same
    # visible trail a Buddy tool call does, so "did that do anything?" is
    # answered by the thread rather than by trusting the sentence underneath.
    post_task_chips(user, conversation, ran)

    # If Jarvis emitted structured button data alongside its reply, render
    # an action-request bubble with tap targets instead of (or in addition
    # to) plain text. Format: `[reply_text, { byte_buttons: [...], multi_select: bool, title: "" }]`.
    button_list = (data.is_a?(Hash) ? (data["byte_buttons"] || data[:byte_buttons]) : nil)
    if button_list.is_a?(Array) && button_list.any?
      buttons  = button_list
      multi    = data["multi_select"] || data[:multi_select]
      title    = data["title"] || data[:title] || "Jarvis"
      subtitle = text.to_s.presence || "Choose an option"

      ByteAction.create_request!(
        user:         user,
        conversation: conversation,
        kind:         :jarvis,
        title:        title,
        subtitle:     subtitle,
        buttons:      buttons.map { |b| b.is_a?(Hash) ? b : { "label" => b.to_s, "value" => b.to_s } },
        multi_select: !!multi,
      )
      # The reply text is the request's own subtitle, so the bubble would be
      # the same words twice.
      drop_reply(user, reply)
      broadcast(user, message.reload)
      return
    end

    # Silence means a task ran and had nothing to say, and there is only one way
    # to get here: a matched `tell:` task RETURNS from Jarvis#command directly,
    # so the action chain never runs. Half the enabled ones never
    # `Global.return` anything — "Alexa: Darkness", "Whisper In", "Do Laundry"
    # just do the thing — and with a receipt above it naming what ran, a bubble
    # reading "(no response)" under that reads as a failure of the thing that
    # just worked. The chip IS the answer.
    if text.strip.empty? && ran.any?
      drop_reply(user, reply)
      return broadcast(user, message.reload)
    end

    # Backstop, not an expected case. When NO task matches, the fallback chain
    # runs and Jarvis::Talk answers unconditionally — a question, a greeting, a
    # thanks, or "I don't know how to X, sir." So nothing-ran-and-nothing-said
    # shouldn't be reachable, and if it ever becomes reachable, saying so beats
    # a message that vanished.
    text = "(no response)" if text.strip.empty?

    # `created_at` moves to now as it settles. The row was opened before the
    # task chips existed, so leaving it where it was created would slot the
    # answer ABOVE the receipts for the work it is reporting on - the same
    # re-timestamp a finalised Claude turn does for the cards it spawned.
    reply.update!(state: :delivered, body: text, delivered_at: Time.current, created_at: Time.current)

    broadcast(user, message.reload)
    broadcast(user, reply)
  rescue => e
    Rails.logger.warn("[ByteJarvis] #{e.class}: #{e.message}")
    fail_body = "Jarvis error: #{e.class}: #{e.message}"
    # The thinking bubble becomes the error, rather than being left spinning
    # above one - a stuck bubble next to an error message reads as two things
    # having gone wrong.
    drop_reply(user, reply)
    conversation&.byte_messages&.create!(
      user:         user,
      direction:    :inbound,
      state:        :failed,
      body:         fail_body,
      metadata:     { kind: :system, error: true, in_reply_to: message&.id },
      delivered_at: Time.current,
    )&.then { |m| broadcast(user, m) }
  ensure
    Buddy::ExpressionState.settle!(conversation)
  end

  # The reply, opened before there's anything to put in it.
  #
  # `streaming` with an empty body is what the thread renders as the pulsing
  # "Thinking" bubble - the same one a Buddy turn shows while it works. The row
  # is the real reply from the start, so the answer lands by filling this in
  # rather than by posting a second message next to it.
  private def open_reply(user, conversation, message)
    conversation.byte_messages.create!(
      user:      user,
      direction: :inbound,
      state:     :streaming,
      body:      "",
      metadata:  { kind: :jarvis, in_reply_to: message.id },
    ).tap { |reply| broadcast(user, reply) }
  end

  # For the two endings that have no words in them. Leaving the bubble to be
  # tidied up on the next reload would mean a thread that reads as still
  # thinking, forever, about something that already finished.
  private def drop_reply(user, reply)
    return if reply.nil?

    id              = reply.id
    conversation_id = reply.byte_conversation_id
    reply.destroy!
    MonitorChannel.broadcast_to(user, {
      id:      :byte,
      channel: :byte,
      data:    { kind: :message_deleted, message_id: id, byte_conversation_id: conversation_id },
    })
  end

  # One receipt per Jil task the words set off. Jarvis's own fallbacks
  # (Jarvis::Tesla, Jarvis::Say, the rest) are not tasks and get nothing — they
  # have no name to show and the reply already says what they did.
  private def post_task_chips(user, conversation, tasks)
    Array(tasks).each { |task|
      Buddy::ActivityChip.post!(
        conversation: conversation,
        user:         user,
        tool_name:    :jarvis_task,
        body:         "Called **#{task.name}**",
        detail:       task.last_message.presence,
        payload:      { "task_id" => task.id, "task_name" => task.name },
      )
    }
  end

  private def broadcast(user, message)
    MonitorChannel.broadcast_to(user, {
      id:      :byte,
      channel: :byte,
      data:    { kind: :message, message: message.as_wire },
    })
  end
end
