# The Rails half of a Feature Builder thread. The session itself runs on the
# Mini (~/code/Byte/builder.rb); this side carries what happens on GitHub back
# to it, and keeps the chip and the system page that say which Claude sessions
# are working on Portfolio there.
module FeatureBuilder
  module_function

  # A builder's branch names its thread: `feature-builder/<conversation id>-<slug>`.
  BRANCH = %r{\Afeature-builder/(\d+)-}

  # Only the owner's words on a PR are instructions. ByteSlime's own replies
  # come back through the same webhook and must not start another turn.
  REVIEWER = "Rockster160".freeze

  # GitHub's webhook secret, set once by a script and pasted into the repo's
  # webhook settings.
  SECRET_KEY = :feature_builder_github_secret

  # Feedback is held this long before it goes to the session, so a review with
  # several line comments arrives as one message instead of a burst of turns.
  GATHER_FOR = 30.seconds

  # The Mini reports every two minutes while anything is listed. Three missed
  # reports and the list is taken to be stale rather than still true.
  REPORT_STALE_AFTER = 6.minutes

  CHIP_KEY = :"mini:claude"

  INTRO = <<~TEXT.squish.freeze
    Tell me what you want built. I'll read the code, ask what I need to know,
    and write it up as a ticket. Once you say go I'll build it and open a PR as
    ByteSlime. I run in Claude on the Mac Mini, and the link to talk to me from
    the Claude app shows up here as soon as I start.
  TEXT

  def intro!(conversation)
    return unless conversation.builder?

    say(conversation, INTRO, notify: false)
  end

  # ---- GitHub ----

  def valid_signature?(body, signature)
    secret = DataStorage[SECRET_KEY].to_s
    return false if secret.blank? || signature.blank?

    expected = "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", secret, body)}"
    ActiveSupport::SecurityUtils.secure_compare(expected, signature.to_s)
  end

  # Returns what it did, for the webhook's response and the log.
  def github!(event, payload)
    case event.to_s
    when "pull_request"                then pull_request!(payload)
    when "pull_request_review"         then review!(payload)
    when "pull_request_review_comment" then line_comment!(payload)
    when "issue_comment"               then pr_comment!(payload)
    else :ignored
    end
  end

  def pull_request!(payload)
    return :ignored unless payload["action"] == "closed"

    conversation = conversation_for(payload["pull_request"])
    return :unknown if conversation.nil?

    merged = payload.dig("pull_request", "merged") == true
    return :finished if ByteLocal.builder(:finish, conversation_id: conversation.id, merged: merged)

    word = merged ? "merged" : "closed"
    say(conversation, "The PR was #{word}, but the Mini didn't answer, so its session is still open.")
    :mini_unreachable
  end

  def review!(payload)
    review = payload["review"].to_h
    return :ignored unless payload["action"] == "submitted" && owner?(review["user"])

    # Line comments arrive as their own events. The review itself only adds
    # something when it has words of its own or asks for changes.
    body = review["body"].to_s.strip
    return :ignored if body.empty? && review["state"] != "changes_requested"

    heading = review["state"] == "changes_requested" ? "Changes requested" : "Review"
    feedback!(payload["pull_request"], "#{heading}: #{body.presence || "see the comments"}", review["html_url"])
  end

  def line_comment!(payload)
    comment = payload["comment"].to_h
    return :ignored unless payload["action"] == "created" && owner?(comment["user"])

    where = [comment["path"], comment["line"] || comment["original_line"]].compact.join(":")
    text  = "On `#{where}` (comment #{comment["id"]}): #{comment["body"].to_s.strip}"
    feedback!(payload["pull_request"], text, comment["html_url"])
  end

  def pr_comment!(payload)
    comment = payload["comment"].to_h
    return :ignored unless payload["action"] == "created" && owner?(comment["user"])
    # An issue comment is on a PR when the issue carries a `pull_request` key.
    return :ignored unless payload["issue"].to_h.key?("pull_request")

    conversation = by_pr_number(payload.dig("issue", "number"))
    return :unknown if conversation.nil?

    feedback_for!(conversation, "Comment: #{comment["body"].to_s.strip}", comment["html_url"])
  end

  def owner?(user)
    user.to_h["login"].to_s.casecmp?(REVIEWER)
  end

  def feedback!(pull_request, text, url)
    conversation = conversation_for(pull_request)
    return :unknown if conversation.nil?

    feedback_for!(conversation, text, url)
  end

  # Shown in the thread as it arrives; handed to the session once it's gone
  # quiet (FeatureBuilderFeedbackWorker).
  def feedback_for!(conversation, text, url)
    say(conversation, "**PR feedback**: #{text}#{" ([on GitHub](#{url}))" if url.present?}", {
      pr_feedback: true,
      pr_text:     text,
    })
    FeatureBuilderFeedbackWorker.perform_in(GATHER_FOR, conversation.id)
    :queued
  end

  def conversation_for(pull_request)
    id = pull_request.to_h.dig("head", "ref").to_s[BRANCH, 1]
    conversation = ByteConversation.find_by(id: id) if id
    conversation = nil unless conversation&.builder?
    conversation || by_pr_number(pull_request.to_h["number"])
  end

  def by_pr_number(number)
    return nil if number.blank?

    ByteConversation.builder.find_by("metadata->'builder'->>'pr_number' = ?", number.to_s)
  end

  # Everything said on the PR since the last hand-off, as one prompt. Returns
  # nil when something newer is still inside its quiet window: the job queued
  # for that one sends the lot.
  def gather!(conversation)
    waiting = conversation.byte_messages.where("metadata->>'pr_feedback' = 'true'")
    waiting = waiting.where("metadata->>'pr_sent' IS NULL").order(:id).to_a
    return nil if waiting.empty?
    return nil if waiting.last.created_at > (GATHER_FOR - 2.seconds).ago

    waiting.each { |message|
      message.update!(metadata: message.metadata.merge("pr_sent" => true))
    }
    lines = waiting.map { |message| "- #{message.metadata["pr_text"]}" }
    "PR feedback from #{REVIEWER}:\n\n#{lines.join("\n")}"
  end

  # `notify: false` for something said to a person who is looking at the
  # thread already, like the intro on one they just opened.
  def say(conversation, text, metadata={}, notify: true)
    message = conversation.byte_messages.create!(
      user:         conversation.user,
      direction:    :inbound,
      state:        :delivered,
      body:         text,
      metadata:     { kind: :system, source: :feature_builder }.merge(metadata),
      delivered_at: Time.current,
    )
    conversation.touch_activity
    MonitorChannel.broadcast_to(conversation.user, {
      id:      :byte,
      channel: :byte,
      data:    { kind: :message, message: message.as_wire },
    })
    ByteNotifier.notify(conversation.user, message) if notify
    message
  end

  # ---- the Mini's Claude sessions ----

  def storage_key(machine)
    :"claude_sessions_#{machine}"
  end

  def report_sessions!(machine:, sessions:)
    listed = Array(sessions).map { |session| session.to_h.slice(*SESSION_FIELDS) }
    DataStorage[storage_key(machine)] = { reported_at: Time.current.iso8601, sessions: listed }
    refresh_chip!(User.me) if machine.to_s == "mini"
    listed
  end

  SESSION_FIELDS = %w[conversation_id kind working started_at branch rc_url pr_url].freeze

  # What the Mini last said is running, or nothing once that report is stale.
  def sessions(machine: :mini)
    stored = DataStorage[storage_key(machine)].to_h.with_indifferent_access
    at = Time.zone.parse(stored[:reported_at].to_s) if stored[:reported_at].present?
    return [] if at.nil? || at < REPORT_STALE_AFTER.ago

    Array(stored[:sessions]).map { |session| session.to_h.stringify_keys }
  end

  def kind_of(session, conversations)
    return :builder if session["kind"].to_s == "builder"

    conversations[session["conversation_id"].to_i]&.name == ByteDailyAudit::NAME ? :audit : :claude
  end

  # Two to four words on the chip, saying what is working right now. A builder
  # waiting on an answer is in the list on the page but not on the chip.
  def chip_name(kinds)
    return nil if kinds.empty?

    if kinds.one?
      { audit: "Auditing…", builder: "Building…", claude: "Claude working…" }.fetch(kinds.first)
    elsif kinds.all?(:builder)
      "#{kinds.length}x Builders running"
    else
      "#{kinds.length}x Claude running"
    end
  end

  def refresh_chip!(user)
    working = sessions.select { |session| session["working"] }
    conversations = ByteConversation.where(id: working.pluck("conversation_id")).index_by(&:id)
    name = chip_name(working.map { |session| kind_of(session, conversations) })
    return BackgroundProcess.clear(user: user, key: CHIP_KEY) if name.nil?

    BackgroundProcess.note(
      user:   user,
      key:    CHIP_KEY,
      name:   name,
      state:  :running,
      source: :mac,
      url:    Rails.application.routes.url_helpers.system_claude_url,
    )
  end
end
