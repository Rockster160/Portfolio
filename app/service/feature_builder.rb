# The Rails half of `/feature`. Typed in a Buddy thread, it starts a Feature
# Builder on the Mini (~/code/Byte/builder.rb): a Claude session in its own
# worktree and branch, reached from the Claude app, that asks, builds and opens
# a ByteSlime PR. The thread gets one system message, rewritten as the build
# starts and given the session's link, and then the PR once it's open. Nothing
# else is said there.
#
# This side also carries GitHub's comments back to the session, and keeps the
# chip and the system page that say which Claude sessions are working on
# Portfolio on the Mini.
module FeatureBuilder
  module_function

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

  USAGE = "usage: `/feature add WHAT TO BUILD`".freeze

  # ---- starting one ----

  # `/feature add ...` (or just `/feature ...`). Returns the system message it
  # posted, which the slash command hands back as its answer.
  def start!(user:, conversation:, text:)
    request = text.to_s.strip.sub(/\Aadd\b\s*/i, "")
    return say(conversation, USAGE) if request.empty?

    build = FeatureBuild.create!(
      user:              user,
      byte_conversation: conversation,
      title:             FeatureBuild.title_for(request),
      request:           request,
    )
    message = say(conversation, build.status_line, feature_build_id: build.id)
    build.update!(byte_message: message)
    FeatureBuildStartWorker.perform_async(build.id)
    message
  end

  MINI_FIELDS = %w[status branch session_id rc_url pr_number pr_url error].freeze

  # The Mini telling us how a build is going (PATCH /webhooks/byte/builds/:id).
  # The thread hears about two things only: the session's link, folded into
  # the message it already has, and the PR, once.
  def update_from_mini!(build, attributes)
    attributes = attributes.to_h.stringify_keys.slice(*MINI_FIELDS).compact_blank
    announce = attributes["pr_url"].present? && build.pr_url.blank?
    build.update!(attributes)
    repaint!(build)
    announce_pr!(build) if announce
    build
  end

  # Rewrites the build's one message in place, the way an alert's bubble is.
  def repaint!(build)
    message = build.byte_message
    return if message.nil? || message.body == build.status_line

    message.update!(body: build.status_line)
    broadcast(message, update: true)
  end

  def announce_pr!(build)
    target = build.byte_conversation
    target = ByteConversation.for_self_initiated(build.user) if target.nil? || target.archived?
    return if target.nil?

    ::Buddy::CompanionDelivery.deliver_plain(
      user:         build.user,
      conversation: target,
      text:         "**#{build.title}** is ready for review: [PR ##{build.pr_number}](#{build.pr_url})",
      metadata:     { "kind" => "system", "source" => "feature_builder", "feature_build_id" => build.id },
      push_title:   "PR ready: #{build.title}",
    )
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

    build = FeatureBuild.for_pull_request(payload["pull_request"])
    return :unknown if build.nil?
    return :ignored if build.status_finished?

    merged = payload.dig("pull_request", "merged") == true
    return :mini_unreachable unless ByteLocal.builder(:finish, build_id: build.id, merged: merged)

    build.update!(status: :finished, finished_at: Time.current)
    :finished
  end

  def review!(payload)
    review = payload["review"].to_h
    return :ignored unless payload["action"] == "submitted" && owner?(review["user"])

    # Line comments arrive as their own events. The review itself only adds
    # something when it has words of its own or asks for changes.
    body = review["body"].to_s.strip
    return :ignored if body.empty? && review["state"] != "changes_requested"

    heading = review["state"] == "changes_requested" ? "Changes requested" : "Review"
    build = FeatureBuild.for_pull_request(payload["pull_request"])
    feedback!(build, "#{heading}: #{body.presence || "see the comments"}")
  end

  def line_comment!(payload)
    comment = payload["comment"].to_h
    return :ignored unless payload["action"] == "created" && owner?(comment["user"])

    where = [comment["path"], comment["line"] || comment["original_line"]].compact.join(":")
    text  = "On `#{where}` (comment #{comment["id"]}): #{comment["body"].to_s.strip}"
    feedback!(FeatureBuild.for_pull_request(payload["pull_request"]), text)
  end

  def pr_comment!(payload)
    comment = payload["comment"].to_h
    return :ignored unless payload["action"] == "created" && owner?(comment["user"])
    # An issue comment is on a PR when the issue carries a `pull_request` key.
    return :ignored unless payload["issue"].to_h.key?("pull_request")

    build = FeatureBuild.for_pr_number(payload.dig("issue", "number"))
    feedback!(build, "Comment: #{comment["body"].to_s.strip}")
  end

  def owner?(user)
    user.to_h["login"].to_s.casecmp?(REVIEWER)
  end

  # Held on the build until it's gone quiet (FeatureBuilderFeedbackWorker).
  def feedback!(build, text)
    return :unknown if build.nil?
    return :ignored if build.status_finished?

    build.with_lock {
      build.update!(feedback: build.feedback + [{ "text" => text, "at" => Time.current.iso8601 }])
    }
    FeatureBuilderFeedbackWorker.perform_in(GATHER_FOR, build.id)
    :queued
  end

  # Everything said on the PR since the last hand-off, as one prompt. Nil when
  # there's nothing, or when something newer is still inside its quiet window:
  # the job queued for that one sends the lot. The caller clears `feedback`
  # once the Mini has it.
  def gather(build)
    waiting = build.feedback
    return nil if waiting.empty?
    return nil if Time.zone.parse(waiting.last["at"].to_s) > (GATHER_FOR - 2.seconds).ago

    lines = waiting.map { |item| "- #{item["text"]}" }
    "PR feedback from #{REVIEWER}:\n\n#{lines.join("\n")}"
  end

  def say(conversation, text, metadata={})
    message = conversation.byte_messages.create!(
      user:         conversation.user,
      direction:    :inbound,
      state:        :delivered,
      body:         text,
      metadata:     { kind: :system, source: :feature_builder }.merge(metadata),
      delivered_at: Time.current,
    )
    broadcast(message)
    message
  end

  def broadcast(message, update: false)
    MonitorChannel.broadcast_to(message.user, {
      id:      :byte,
      channel: :byte,
      data:    { kind: :message, message: message.as_wire, update: update }.compact_blank,
    })
  end

  # ---- the Mini's Claude sessions ----

  def storage_key(machine)
    :"claude_sessions_#{machine}"
  end

  SESSION_FIELDS = %w[conversation_id build_id kind working started_at].freeze

  def report_sessions!(machine:, sessions:)
    listed = Array(sessions).map { |session| session.to_h.stringify_keys.slice(*SESSION_FIELDS) }
    DataStorage[storage_key(machine)] = { reported_at: Time.current.iso8601, sessions: listed }
    refresh_chip!(User.me) if machine.to_s == "mini"
    listed
  end

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
    conversations = ByteConversation.where(id: working.pluck("conversation_id").compact).index_by(&:id)
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
