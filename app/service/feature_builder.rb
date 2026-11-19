# The Rails half of `/feature`. Typed in a Buddy thread, it starts a Feature
# Builder on the Mini (~/code/Byte/builder.rb): a Claude session in its own
# worktree and branch, reached from the Claude app, that asks, builds and opens
# a ByteSlime PR. The request stays in the thread as the person's own message,
# and the thread gets one system message, rewritten as the build starts and
# given the session's link, then one when its PR is open, and one each time it
# stops to ask its owner something, carrying the question in full. Its plan is recorded but not announced: the session builds straight on
# from it without waiting for a go. Nothing else is said there.
#
# A build can also be started from a row on /system/feature_requests, and then
# speaks in the owner's primary Buddy thread and moves the request along with
# it: planned when it starts, shipped when its PR is merged.
#
# A question is answered from Byte either by replying to any message about the
# build (the request itself included) or by telling Buddy (`answer_build`);
# both type the answer into the session. A reply with no question open goes in
# the same way, as more to go on. When master moves, the Mini has each open PR
# that no longer merges catch up with it, one build at a time (`sync`).
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

  # Raised while any build has a question or a PR waiting on its owner.
  NEEDS_YOU_KEY = :"mini:needs_you"

  # The looks a builder's owner's own pet holds while their builds are in each
  # state: at the laptop while one works, thinking while one is asking them
  # something, pleased with the job while a PR waits on their review. All low,
  # so a mood in a reply or an alert shows over them and the pet comes back to
  # them when idle. Asking outranks working, and a PR gives way to both.
  LOOKS = {
    building: { key: :"mini:building", face: :working,      strength: 20 },
    asking:   { key: :"mini:asking",   face: :thinking,     strength: 25 },
    reviewed: { key: :"mini:pr_ready", face: :accomplished, strength: 15 },
  }.freeze
  LOOK_KEYS = LOOKS.values.pluck(:key).freeze

  # The request, posted as the person's own message.
  REQUEST_KIND = :feature_request

  USAGE = "usage: `/feature add WHAT TO BUILD`".freeze

  # How every build talks, handed to it with its request. Each message a turn
  # ends with reaches its owner's phone as a push.
  TEXTING = <<~TXT.chomp.freeze
    HOW TO TALK
    Every message you end a turn with reaches the owner's phone as a text. Write it like one: a few short lines to take in at a glance, the answer first, no headings, no debrief. Questions are numbered so each can be answered by number. Detail belongs in the ticket, the PR or the script, not in the messages.
  TXT

  # A build's last message before it stopped, kept as the question it's asking.
  # One can run long; past this it's cut and the session has the rest.
  QUESTION_LIMIT = 4000

  # ---- starting one ----

  # `/feature add ...` (or just `/feature ...`). Returns the command as the
  # person's own message, which the slash command hands back as the echo of
  # what they typed: `typed`, word for word, defaulting to the command it
  # stands for. `local_id` is the client's optimistic bubble, which that
  # message takes over. `attachment_signed_ids` are images sent along with the
  # command, already uploaded to /byte/uploads: the build is given them, and
  # the request shows them.
  def start!(user:, conversation:, text:, typed: nil, local_id: nil, attachment_signed_ids: [])
    request = text.to_s.strip.sub(/\Aadd\b\s*/i, "")
    return say(conversation, USAGE) if request.empty?

    said = typed.presence || "/feature add #{request}"
    posted = nil
    launch!(
      user:                  user,
      conversation:          conversation,
      request:               request,
      attachment_signed_ids: attachment_signed_ids,
    ) { |build|
      posted = post_request!(build, conversation, said, { local_id: local_id }.compact)
    }
    posted
  end

  # The Build button on a feature request. Returns the build, or nil when the
  # request isn't one that can be built (FeatureRequest#buildable?).
  def start_from_request!(feature_request, user:, notes: nil, attachment_signed_ids: [])
    return nil unless feature_request.buildable?

    request = [
      feature_request.title,
      feature_request.body,
      notes.to_s.strip.presence&.then { |text| "Notes: #{text}" },
    ].compact.join("\n\n")

    feature_request.update!(status: :planned)
    launch!(
      user:                  user,
      conversation:          ByteConversation.for_self_initiated(user),
      request:               request,
      title:                 feature_request.title,
      feature_request:       feature_request,
      attachment_signed_ids: attachment_signed_ids,
    )
  end

  # `title` is a name already chosen, kept as it is. Without one the build is
  # named for `title_from` (the request, unless given something shorter that
  # says what it's about) by a model as it starts (FeatureBuilder::Title), and
  # goes by the request's first line only until then.
  # A block is given the build before its status line is posted, so what's
  # posted there reads above it.
  #
  # A build with a `parent` posts no card of its own: it takes over its
  # parent's, which from then on shows this build and answers to it.
  def launch!(
    user:,
    conversation:,
    request:,
    feature_request: nil,
    title: nil,
    title_from: nil,
    kind: :feature,
    parent: nil,
    attachment_signed_ids: [])
    build = FeatureBuild.create!(
      user:              user,
      byte_conversation: conversation,
      feature_request:   feature_request,
      parent:            parent,
      title:             FeatureBuild.title_for(title.presence || request),
      request:           without_session_links(request),
      kind:              kind,
    )
    blobs = blobs_for(attachment_signed_ids)
    build.images.attach(blobs) if blobs.any?
    if conversation
      yield build if block_given?
      take_over_card!(build) || post_card!(build, conversation)
    end
    refresh_looks!(user)
    FeatureBuildStartWorker.perform_async(build.id, title.present? ? nil : (title_from.presence || request))
    build
  end

  # A Claude session's Remote Control link.
  SESSION_LINK = %r{https://claude\.ai/code/session_\w+}

  # The request is the session's first prompt, so it is on the new pane's
  # screen as it starts, and the Mini takes the first session link it finds
  # there as the new session's own. A brief quoting an earlier build's
  # messages carries that build's link, which would be found first.
  def without_session_links(request)
    request.to_s.gsub(SESSION_LINK, "(session link)")
  end

  def post_card!(build, conversation)
    message = say(conversation, build.status_line, feature_build_id: build.id)
    build.update!(byte_message: message)
  end

  # The parent's card, now this build's: rewritten to show it, and a reply to
  # it reaches this session. Nil when the parent has no card to take.
  def take_over_card!(build)
    message = build.parent&.byte_message
    return nil if message.nil? || message.byte_conversation_id != build.byte_conversation_id

    message.update!(metadata: message.metadata.to_h.merge("feature_build_id" => build.id))
    build.update!(byte_message: message)
    repaint!(build)
    true
  end

  # `waiting_at` isn't kept: it's the Mini saying a turn just ended with
  # nothing announced in it, so the session is waiting on an answer.
  # `question` comes with it: the last thing that turn said.
  MINI_FIELDS = %w[
    status
    branch
    session_id
    rc_url
    pr_number
    pr_url
    error
    planned_at
    waiting_at
    question
    closed_reason
    rereview
  ].freeze

  def post_request!(build, conversation, body, metadata)
    message = conversation.byte_messages.create!(
      user:         build.user,
      direction:    :outbound,
      state:        :sent,
      body:         body,
      metadata:     { kind: REQUEST_KIND, source: :feature_builder, feature_build_id: build.id }.merge(metadata),
      delivered_at: Time.current,
    )
    message.files.attach(build.images.blobs) if build.images.attached?
    broadcast(message)
    message
  end

  # The Mini telling us how a build is going (PATCH /webhooks/byte/builds/:id).
  # The thread hears about three things only: the session's link, folded into
  # the message it already has, the PR, once, and each turn that ends waiting
  # on the owner without it. A plan only moves the chip from planning to
  # building.
  def update_from_mini!(build, attributes)
    attributes = attributes.to_h.stringify_keys.slice(*MINI_FIELDS).compact_blank
    return closed!(build, attributes) if attributes["closed_reason"].present?
    return rereview!(build, attributes["rereview"]) if attributes["rereview"].present?

    waiting = attributes.delete("waiting_at").present?
    question = attributes.delete("question")
    if question
      attributes.merge!("question" => question.first(QUESTION_LIMIT), "asked_at" => Time.current)
    elsif waiting && build.kind_quick?
      # A quick turn's answer is only ever this turn's, never one already said.
      attributes.merge!("question" => nil, "asked_at" => nil)
    end
    # A ticket posted again after a change keeps the time it was first posted.
    attributes.delete("planned_at") if build.planned_at.present?
    planned = attributes["planned_at"].present?
    announce_pr = attributes["pr_url"].present? && build.pr_url.blank?
    build.update!(attributes)
    repaint!(build)
    announce_pr!(build) if announce_pr
    announce_waiting!(build) if waiting && !announce_pr
    MergeQueue.enqueue!(build) if announce_pr
    # Handed the merge, it stopped without merging, closing or asking for a
    # review: whatever it said is for the owner, and it needs approving again.
    MergeQueue.released!(build) if waiting && build.reload.landing_at
    refresh_chip!(build.user) if planned
    refresh_needs_you!(build.user)
    MergeQueue.advance!(build.user)
    build
  end

  # Handed the merge, the session changed something the owner should see
  # again (`builder-pr rereview`): it has commented and asked for a review on
  # the PR, and gives up its approval and its turn.
  def rereview!(build, comment)
    announce!(
      build,
      build.card(
        "Needs another review: #{comment}",
        links: [build.pr_markdown, build.link_markdown],
      ),
      "Review again: #{build.full_title}",
    )
    MergeQueue.released!(build)
    refresh_needs_you!(build.user)
    build
  end

  # The session closed itself (`builder-pr close`): what it was asked for is
  # already in master, or needed no code. The Mini closes the PR and removes the
  # worktree on its own; this records why, and says so in the thread. The why
  # is said once, in the message: the card only says it closed itself.
  def closed!(build, attributes)
    build.update!(
      **attributes.slice("closed_reason", "pr_number", "pr_url"),
      status:        :finished,
      finished_at:   Time.current,
      question:      nil,
      asked_at:      nil,
      closed_itself: true,
    )
    repaint!(build)
    announce!(
      build,
      build.card(
        "Closed itself#{build.scripts_note}: #{build.closed_reason}",
        links:   [],
        scripts: build.script_links,
      ),
      "Closed: #{build.full_title}",
    )
    refresh_chip!(build.user)
    refresh_needs_you!(build.user)
    MergeQueue.released!(build)
    build
  end

  CANCELED_REASON = "canceled from the Claude page".freeze

  # The Cancel button: the Mini closes the session and the PR and removes the
  # worktree and the branch on its own once it has said yes. False when it
  # didn't answer, and the build is left as it was.
  # rubocop:disable Naming/PredicateMethod -- this sends; the boolean is whether it got there
  def cancel!(build, reason: CANCELED_REASON)
    return true if build.status_finished?

    told = ByteLocal.builder(
      :cancel,
      build_id:  build.id,
      repo:      build.repo,
      pr_number: build.pr_number,
      branch:    build.branch,
    )
    return false unless told

    build.update!(
      status:        :finished,
      finished_at:   Time.current,
      closed_reason: reason,
      question:      nil,
      asked_at:      nil,
    )
    repaint!(build)
    refresh_chip!(build.user)
    refresh_needs_you!(build.user)
    MergeQueue.released!(build)
    true
  end
  # rubocop:enable Naming/PredicateMethod

  # Rewrites the build's one message in place, the way an alert's bubble is.
  def repaint!(build)
    message = build.byte_message
    return if message.nil? || message.body == build.status_line

    message.update!(body: build.status_line)
    broadcast(message, update: true)
  end

  # Each message about a build that links a script says, after the link, what
  # the script is doing: rewritten whenever that changes.
  def repaint_script_links!(script)
    url = ProductionScripts::Card.url(script)
    link = /\]\(#{Regexp.escape(url)}\) \([^)\n]*\)/
    scope = ByteMessage.where(user_id: script.user_id).where("byte_messages.metadata->>'source' = 'feature_builder'")
    scope = scope.where("byte_messages.metadata->>'kind' = 'system'")
    scope = scope.where("byte_messages.body LIKE ?", "%(#{ActiveRecord::Base.sanitize_sql_like(url)}) (%")
    scope.find_each { |message|
      body = message.body.gsub(link, "](#{url}) (#{script.status_label})")
      next if body == message.body

      message.update!(body: body)
      broadcast(message, update: true)
    }
  end

  def announce_pr!(build)
    move_card!(build, "PR ready: #{build.full_title}")
  end

  # The build's card, posted again at the bottom of the thread and taken away
  # from where it was, so the news pushes and the thread still holds one card
  # for the build, the one that keeps up, rather than a live one further up
  # and a copy below that never changes again. Every build speaking on the old
  # card (a parent and the session carrying it on) moves with it.
  def move_card!(build, push_title)
    old = build.byte_message
    message = announce!(build, build.status_line, push_title)
    return if message.nil?

    build.update!(byte_message: message)
    return if old.nil? || old == message

    FeatureBuild.where(byte_message_id: old.id).update_all(byte_message_id: message.id)
    remove!(old)
  end

  def remove!(message)
    message.destroy!
    MonitorChannel.broadcast_to(message.user, {
      id:      :byte,
      channel: :byte,
      data:    {
        kind:                 :message_deleted,
        message_id:           message.id,
        byte_conversation_id: message.byte_conversation_id,
      },
    })
  end

  def announce_waiting!(build)
    return if build.status_finished? || build.status_failed?
    return announce_answer!(build) if build.kind_quick?

    step = (
      if build.question.present?
        "Asking, reply to this to answer:\n#{build.question}"
      else
        "Waiting on you"
      end
    )
    announce!(build, build.card(step), "Waiting on you: #{build.full_title}")
  end

  # A `/q` turn's last message is its answer, so that is the step, word for
  # word. A turn that ended with no text still says so, so the thread is never
  # left waiting on an answer that isn't coming.
  def announce_answer!(build)
    step = build.question.presence || "Finished a turn, but no answer came back from it"
    announce!(build, build.card(step), build.full_title)
  end

  # A production script a session sent, as a card in its thread to read and
  # approve there (ProductionScripts::Card).
  def script_sent!(script, updated: false)
    ProductionScripts::Card.post!(script, updated: updated)
  end

  # The script a session carrying on from another is sending in place of one
  # of its parent's: the same title, and not yet run. It replaces that one
  # rather than standing beside it, since it was started to change it.
  def replaced_script(build, title)
    return nil if build&.parent.nil? || title.blank?

    scope = build.parent.production_scripts.where(title: title)
    scope.where(status: [:pending, :approved, :failed]).order(:created_at).last
  end

  def announce!(build, text, push_title)
    target = build.byte_conversation
    target = ByteConversation.for_self_initiated(build.user) if target.nil? || target.archived?
    return if target.nil?

    ::Buddy::CompanionDelivery.deliver_plain(
      user:         build.user,
      conversation: target,
      text:         text,
      metadata:     { "kind" => "system", "source" => "feature_builder", "feature_build_id" => build.id },
      push_title:   push_title,
    )
  end

  # Loose blobs from /byte/uploads. A tampered or expired id is dropped, the
  # same as on a message.
  def blobs_for(signed_ids)
    Array(signed_ids).compact_blank.filter_map { |signed_id| ActiveStorage::Blob.find_signed(signed_id) }
  end

  # Images as {filename, content_type, url}, the shape the Mini downloads from.
  # Only formats Claude reads, and a URL that can't be built is left out rather
  # than taking the rest down with it.
  def image_sources(files)
    files.filter_map { |file|
      next unless ByteImageNormalizer::PASSTHROUGH_TYPES.include?(file.content_type.to_s)

      url = image_url(file)
      url && { filename: file.filename.to_s, content_type: file.content_type.to_s, url: url }
    }
  end

  def image_url(file)
    file.url(expires_in: ByteMessage::SOURCE_URL_TTL)
  rescue StandardError => e
    Rails.logger.warn("[FeatureBuilder] image url failed for blob #{file.blob_id}: #{e.class}: #{e.message}")
    nil
  end

  # ---- answering from Byte ----

  # The build a reply in the thread is aimed at: any message posted about it,
  # the request and the replies to it included, finished or not.
  def replied_to(user, message)
    id = message.metadata.to_h["feature_build_id"]
    id.present? ? FeatureBuild.find_by(user: user, id: id) : nil
  end

  # Whether a person's message went to a build instead of to Buddy.
  def sent_to_build?(message)
    message.outbound? && message.metadata.to_h["feature_build_id"].present?
  end

  # Builds with a question out to their owner, oldest first. What Buddy matches
  # an answer typed without a reply against. A `/q`'s last message is an
  # answer, not a question, and is replied to directly.
  def asking(user)
    scope = FeatureBuild.unfinished.where(user: user).where.not(kind: :quick)
    scope.where.not(question: nil).order(:asked_at)
  end

  # Every session whose last turn is waiting on its owner, `/q`s included: what
  # Buddy weighs a message typed without a reply against. A `/q` often ends a
  # turn on a question of its own ("should I start a /feature for it?"), and
  # the answer to it is typed as a plain message as often as a reply.
  def awaiting_reply(user)
    scope = FeatureBuild.unfinished.where(user: user)
    scope.where.not(question: nil).order(:asked_at)
  end

  # Types `text` into the build's session as its owner's next message, with
  # `images` ({filename, content_type, url}) downloaded on the Mini and listed
  # under it. False when the Mini didn't take it, and the question stays open.
  # rubocop:disable Naming/PredicateMethod -- these send; the boolean is whether it got there
  def answer!(build, text, images: [])
    fields = { build_id: build.id, text: text.to_s }
    fields[:attachments] = images if images.any?
    return false unless ByteLocal.builder(:message, **fields)

    build.update!(question: nil, asked_at: nil)
    refresh_needs_you!(build.user)
    true
  end

  # The message being answered when its images go along with an answer told to
  # Buddy: the last thing the person said, and only when it carries images.
  def latest_images_message(conversation)
    return nil if conversation.nil?

    latest = conversation.byte_messages.spoken.recent.first
    latest if latest&.model_image_sources.present?
  end

  # A reply typed at one of the build's messages: an answer when it's asking,
  # more to go on when it isn't. Said in the thread when it didn't get there,
  # since nothing else would show it. `target` is the message replied to: on a
  # production script's card, the session is told which script it's about.
  def answer_from_thread!(build, message, target: nil)
    script = ProductionScripts::Card.script_for(target)
    if build.status_finished? || build.status_failed?
      # A `/q` that has closed carries on in a new session of its own, and so
      # does any build whose script is being asked to change: that is work a
      # quick session can do on its own.
      if build.kind_quick? || script
        return FeatureBuilder::Quick.resume!(build, message, script: script).present?
      end

      over = build.status_failed? ? "Never started" : "Finished"
      say(
        message.byte_conversation,
        build.card("#{over}, so there's no session left to send that to", links: []),
        feature_build_id: build.id,
      )
      return false
    end
    text = script ? script_reply(script, message.body) : message.body
    return true if answer!(build, text, images: message.model_image_sources)

    say(
      message.byte_conversation,
      build.card("Couldn't reach the Mini, so that reply didn't get to it"),
      feature_build_id: build.id,
    )
    false
  end
  # rubocop:enable Naming/PredicateMethod

  # A reply to a script's card, as the session that wrote it is given it.
  def script_reply(script, text)
    <<~TXT.strip
      About production script ##{script.id}, "#{script.title}" (#{ProductionScripts::Card.url(script)}):

      #{text.to_s.strip}

      To change it, send it again with `builder-pr script` under the same title. It replaces this one, and needs approving again.
    TXT
  end

  # ---- GitHub ----

  def valid_signature?(body, signature)
    secret = DataStorage[SECRET_KEY].to_s
    return false if secret.blank? || signature.blank?

    expected = "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", secret, body)}"
    ActiveSupport::SecurityUtils.secure_compare(expected, signature.to_s)
  end

  # Returns what it did, for the webhook's response and the log. Every repo a
  # build can be for sends here (Repos), and says which it is.
  def github!(event, payload)
    repo = payload.dig("repository", "full_name").presence || Repos::PORTFOLIO
    case event.to_s
    when "pull_request"                then pull_request!(payload, repo)
    when "pull_request_review"         then review!(payload, repo)
    when "pull_request_review_comment" then line_comment!(payload, repo)
    when "issue_comment"               then pr_comment!(payload, repo)
    when "push"                        then push!(payload, repo)
    else :ignored
    end
  end

  # Master moved: the Mini checks every open PR against it and brings the
  # ones that no longer merge back in line (FeatureBuildSyncWorker). Only
  # Portfolio's: a PR in another repo is its owner's to merge.
  def push!(payload, repo=Repos::PORTFOLIO)
    return :ignored unless Repos.portfolio?(repo) && payload["ref"] == "refs/heads/master"
    return :ignored unless FeatureBuild.portfolio.unfinished.where.not(pr_url: nil).exists?

    FeatureBuildSyncWorker.perform_async
    :syncing
  end

  def pull_request!(payload, repo=Repos::PORTFOLIO)
    return :ignored unless payload["action"] == "closed"

    build = FeatureBuild.for_pull_request(payload["pull_request"], repo: repo)
    return :unknown if build.nil?
    return :ignored if build.status_finished?

    merged = payload.dig("pull_request", "merged") == true
    # Saved before anything else so the merge queue holds for its deploy, even
    # while the Mini is still to be told. In another repo, it's what the
    # laptop's checkout has to have for the build to be pulled.
    build.update!(merge_sha: payload.dig("pull_request", "merge_commit_sha")) if merged
    unless ByteLocal.builder(:finish, build_id: build.id, merged: merged)
      FeatureBuildFinishWorker.perform_in(FeatureBuildFinishWorker::RETRY_IN, build.id, merged)
      return :mini_unreachable
    end

    finished!(build, merged: merged)
    :finished
  end

  # The Mini has closed the session and removed the worktree and the branch.
  def finished!(build, merged:)
    build.update!(status: :finished, finished_at: Time.current)
    build.feature_request&.update!(status: :shipped) if merged
    refresh_needs_you!(build.user)
    MergeQueue.released!(build)
  end

  def review!(payload, repo=Repos::PORTFOLIO)
    review = payload["review"].to_h
    return :ignored unless payload["action"] == "submitted" && owner?(review["user"])

    # An approval puts it in line to merge, and changes asked for take it out.
    # Line comments arrive as their own events. The review itself only adds
    # something when it has words of its own or asks for changes.
    build = FeatureBuild.for_pull_request(payload["pull_request"], repo: repo)
    approved = review["state"] == "approved"
    MergeQueue.approve!(build) if approved && build && !build.status_finished?
    MergeQueue.unapprove!(build) if review["state"] == "changes_requested" && build
    body = review["body"].to_s.strip
    return (approved ? :approved : :ignored) if body.empty? && review["state"] != "changes_requested"

    heading = review["state"] == "changes_requested" ? "Changes requested" : "Review"
    feedback!(build, "#{heading}: #{body.presence || "see the comments"}")
  end

  def line_comment!(payload, repo=Repos::PORTFOLIO)
    comment = payload["comment"].to_h
    return :ignored unless payload["action"] == "created" && owner?(comment["user"])

    where = [comment["path"], comment["line"] || comment["original_line"]].compact.join(":")
    text  = "On `#{where}` (comment #{comment["id"]}): #{comment["body"].to_s.strip}"
    feedback!(FeatureBuild.for_pull_request(payload["pull_request"], repo: repo), text)
  end

  def pr_comment!(payload, repo=Repos::PORTFOLIO)
    comment = payload["comment"].to_h
    return :ignored unless payload["action"] == "created" && owner?(comment["user"])
    # An issue comment is on a PR when the issue carries a `pull_request` key.
    return :ignored unless payload["issue"].to_h.key?("pull_request")

    build = FeatureBuild.for_pr_number(payload.dig("issue", "number"), repo: repo)
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
    DataStorage[storage_key(machine)] = { reported_at: Time.current.iso8601(6), sessions: listed }
    if machine.to_s == "mini"
      answered_elsewhere!(listed)
      repaint_open_cards!
      refresh_chip!(User.me)
      refresh_needs_you!(User.me)
      refresh_look!
    end
    listed
  end

  # What the Mini last said is running, or nothing once that report is stale.
  def sessions(machine: :mini)
    return [] if sessions_reported_at(machine: machine).nil?

    stored = DataStorage[storage_key(machine)].to_h.with_indifferent_access
    Array(stored[:sessions]).map { |session| session.to_h.stringify_keys }
  end

  # A card says whether its session is working or at rest, which only the
  # Mini's report knows.
  def repaint_open_cards!
    FeatureBuild.where(status: :running).find_each(&:repaint_card)
  end

  # A build working again was answered some other way (the Claude app, the
  # pane), so its question is no longer open.
  def answered_elsewhere!(listed)
    working = listed.select { |session| session["working"] && session["build_id"] }
    return if working.empty?

    ids = working.map { |session| session["build_id"].to_i }
    FeatureBuild.where(id: ids).where.not(question: nil).find_each { |build|
      build.update!(question: nil, asked_at: nil)
    }
  end

  # A builder is planning until it has posted its ticket, and building after.
  # An audit is auditing throughout.
  def kind_of(session, conversations, builds={})
    if session["kind"].to_s == "builder"
      build = builds[session["build_id"].to_i]
      return :auditing if build&.kind_audit?
      return :quick if build&.kind_quick?

      return build && build.planned_at.nil? ? :planning : :builder
    end
    return :questions if session["kind"].to_s == "questions"

    conversations[session["conversation_id"].to_i]&.name == ByteDailyAudit::NAME ? :audit : :claude
  end

  # The sessions that stay open when they have nothing to do: idle, they're
  # at rest rather than waiting on anyone.
  AT_REST_KINDS = %i[questions quick claude audit].freeze

  def at_rest?(kind)
    AT_REST_KINDS.include?(kind)
  end

  # Two to four words on the chip, saying what is working right now. A builder
  # waiting on an answer is in the list on the page but not on the chip, and
  # the standing questions session never is: it's always open, so it would
  # read as work going on when nothing is.
  def chip_name(kinds)
    return nil if kinds.empty?

    if kinds.one?
      {
        audit:    "Auditing…",
        auditing: "Auditing…",
        quick:    "Looking into it…",
        planning: "Planning…",
        builder:  "Building…",
        claude:   "Claude working…",
      }.fetch(kinds.first)
    elsif kinds.all? { |kind| kind.in?([:planning, :builder]) }
      "#{kinds.length}x Builders running"
    else
      "#{kinds.length}x Claude running"
    end
  end

  def refresh_chip!(user)
    working = sessions.select { |session| session["working"] }
    conversations = ByteConversation.where(id: working.pluck("conversation_id").compact).index_by(&:id)
    builds = FeatureBuild.where(id: working.pluck("build_id").compact).index_by(&:id)
    kinds = working.map { |session| kind_of(session, conversations, builds) }
    name = chip_name(kinds - [:questions])
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

  # Every owner of an unfinished build, and everyone still wearing one of the
  # looks, has theirs worked out again.
  def refresh_look!
    owner_ids = FeatureBuild.unfinished.distinct.pluck(:user_id)
    owner_ids |= BuddyAlert.status_open.where(key: LOOK_KEYS).distinct.pluck(:user_id)
    User.where(id: owner_ids).find_each { |user| refresh_looks!(user) }
  end

  # Holds each look whose state one of the person's builds is in, and lets go
  # of the rest. Holding an unchanged look again sends nothing.
  def refresh_looks!(user)
    states = look_states(user)
    LOOKS.each do |state, look|
      if states.include?(state)
        Buddy::Alerts.hold!(
          user:       user,
          key:        look[:key],
          body:       nil,
          expression: look[:face],
          strength:   look[:strength],
        )
      else
        Buddy::Alerts.resolve!(user: user, key: look[:key])
      end
    end
  end

  # The states the person's builds are in, of :building, :asking, :reviewed.
  #
  # A build is working while its session is, and also before the Mini has
  # reported it at all: from the moment it's asked for, and after a change the
  # last report predates, for as long as a report would still hold. An approved PR is the merge queue's to land, so it no
  # longer waits on them.
  def look_states(user)
    builds = FeatureBuild.unfinished.where(user: user).to_a
    return [] if builds.empty?

    listed = sessions.select { |session| session["build_id"] }.index_by { |session| session["build_id"].to_i }
    reported_at = sessions_reported_at
    waiting = pending(user)
    asking = waiting[:questions] | builds.select { |build| build.question.present? && !build.kind_quick? }

    states = []
    states << :asking if asking.any?
    states << :reviewed if (waiting[:prs] - asking).any? { |build| build.approved_at.nil? }
    states << :building if builds.any? { |build|
      session = listed[build.id]
      next session["working"] && session["kind"].to_s == "builder" if session
      next true if build.status_starting?

      build.status_running? && build.updated_at > [reported_at, REPORT_STALE_AFTER.ago].compact.max
    }
    states
  end

  # When the Mini last reported its sessions, while that report still holds.
  def sessions_reported_at(machine: :mini)
    stored = DataStorage[storage_key(machine)].to_h.with_indifferent_access
    at = Time.zone.parse(stored[:reported_at].to_s) if stored[:reported_at].present?
    at if at && at >= REPORT_STALE_AFTER.ago
  end

  # ---- waiting on the owner ----

  # Builds whose PR is open, and builds with no PR yet whose open session has
  # ended its turn: it's asking something, before its plan or partway through
  # the build.
  def pending(user)
    idle = sessions.select { |session| session["build_id"] && !session["working"] }
    idle = idle.map { |session| session["build_id"].to_i }
    live = FeatureBuild.where(user: user, status: [:starting, :running, :stopped]).where.not(kind: :quick)
    live = live.newest.to_a
    {
      prs:       live.select { |build| build.pr_url.present? },
      questions: live.select { |build| build.pr_url.blank? && idle.include?(build.id) },
    }
  end

  # The builds waiting on them, and the merges in other repos still to pull on
  # the laptop.
  def pending_count(user)
    pending(user).values.sum(&:length) + FeatureBuild.to_pull.where(user: user).count
  end

  # The laptop's checkout of `repo` has these merge commits now
  # (POST /webhooks/byte/pulls), so there's nothing left to pull for them.
  def pulled!(repo, shas)
    builds = FeatureBuild.to_pull.where(repo: repo, merge_sha: Array(shas)).to_a
    builds.each { |build| build.update!(pulled_at: Time.current) }
    builds.map(&:user).uniq.each { |user| refresh_needs_you!(user) }
    builds
  end

  # Where a build has got to, in the words the pages show it in. `live` is the
  # Mini's report for it, when it's listed. Once it has a PR, its place in the
  # merge queue says more than the session does, except while merging.
  def stage(build, live)
    return "merged, to pull" if build.merge_sha && !build.portfolio? && build.pulled_at.nil?
    return build.status.humanize.downcase if build.status_failed? || build.status_finished?
    return (live["working"] ? "working" : "answered") if live && build.kind_quick?
    return pr_stage(build, live) if build.pr_url.present?
    return (build.planned_at ? "building" : "planning") if live&.dig("working")

    live ? "waiting on you" : build.status.humanize.downcase
  end

  def pr_stage(build, live)
    queue = MergeQueue.state(build)
    return "merging" if queue == :landing
    return "working" if live&.dig("working")
    return "held" if queue == :held
    return "approved" if queue == :approved

    "PR open"
  end

  # The chip counting what waits on them, and the looks their pet wears for
  # it: every change to a build that might move either comes through here.
  def refresh_needs_you!(user)
    return if user.nil?

    refresh_looks!(user)
    count = pending_count(user)
    return BackgroundProcess.clear(user: user, key: NEEDS_YOU_KEY) if count.zero?

    BackgroundProcess.note(
      user:   user,
      key:    NEEDS_YOU_KEY,
      name:   count == 1 ? "1 build needs you" : "#{count} builds need you",
      state:  :waiting,
      source: :mac,
      links:  [{ label: "Claude on the Mini", url: Rails.application.routes.url_helpers.system_claude_url }],
    )
  end
end
