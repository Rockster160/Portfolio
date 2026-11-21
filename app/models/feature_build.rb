# == Schema Information
#
# Table name: feature_builds
#
#  id                   :bigint           not null, primary key
#  approved_at          :datetime
#  asked_at             :datetime
#  branch               :string
#  closed_itself        :boolean          default(FALSE), not null
#  closed_reason        :text
#  deployed_at          :datetime
#  error                :text
#  feedback             :jsonb            not null
#  finished_at          :datetime
#  held                 :boolean          default(FALSE), not null
#  kind                 :integer          default("feature"), not null
#  landing_at           :datetime
#  merge_sha            :string
#  planned_at           :datetime
#  pr_number            :integer
#  pr_url               :string
#  pulled_at            :datetime
#  question             :text
#  queue_position       :integer
#  rc_url               :string
#  repo                 :string           default("Rockster160/Portfolio"), not null
#  request              :text             not null
#  status               :integer          default("starting"), not null
#  title                :string           not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  byte_conversation_id :bigint
#  byte_message_id      :bigint
#  feature_request_id   :bigint
#  parent_id            :bigint
#  session_id           :string
#  user_id              :bigint           not null
#

# One `/feature` request: a Claude session on the Mini, in its own worktree and
# branch, that asks what it needs (in the Claude app), builds, and opens a
# ByteSlime PR. The Mini runs it (~/code/Byte/builder.rb); this is the record of
# it, and the handle GitHub's comments find their way back through.
#
# `byte_message` is the one system message in the thread it was asked from. It
# is rewritten as the build moves - starting, then the link to the session -
# rather than followed by more of them. Its PR opening moves it to the bottom
# of the thread (FeatureBuilder.move_card!), so that news pushes.
#
# `repo` is the GitHub repo it builds in (FeatureBuilder::Repos), Portfolio
# unless the request was for another. Only Portfolio's PRs go through the
# merge queue: another repo's is merged by its owner, and from then until the
# laptop's checkout has the merge (`pulled_at`), it's waiting to be pulled.
#
# `parent` is the build it carries on from: a build a `/q` handed its work to,
# or a session started to carry on one that had closed. It speaks on its
# parent's card, under its parent's name, so the thread reads as one piece of
# work rather than one card per session.
class FeatureBuild < ApplicationRecord
  belongs_to :user
  belongs_to :byte_conversation, optional: true
  belongs_to :byte_message, optional: true
  # Set when it was started from a row on /system/feature_requests.
  belongs_to :feature_request, optional: true
  belongs_to :parent, class_name: "FeatureBuild", optional: true
  has_many :children, class_name: "FeatureBuild", foreign_key: :parent_id, inverse_of: :parent, dependent: :nullify
  has_many :production_scripts, dependent: :nullify

  # Screenshots and photos it was started with. The Mini downloads them into
  # the build's worktree and points the session at them.
  has_many_attached :images

  # starting   asked for; the Mini hasn't said it's up yet
  # running    the session is open (working or waiting on an answer)
  # stopped    the session was closed from the system page; the work is kept
  # finished   its PR was merged or closed, or the session closed itself
  #            (`closed_reason` says why), and the worktree is gone
  # failed     the Mini couldn't start it (`error` says why)
  #
  # `planned_at` is when the session first posted its ticket (`builder-pr plan`).
  enum :status, { starting: 0, running: 1, stopped: 2, finished: 3, failed: 4 }, prefix: :status

  # feature    `/feature`: build what was asked
  # audit      `/audit`: read the recent traffic, then fix what it turns up
  #            (FeatureBuilder::Audit)
  # quick      `/q`: answer a question or write a production script, read-only
  #            in the Portfolio checkout with no worktree or branch of its own
  #            (FeatureBuilder::Quick)
  enum :kind, { feature: 0, audit: 1, quick: 2 }, prefix: :kind

  # What each kind is called in the thread's status line, starting and then
  # running.
  KIND_WORDS = {
    feature: ["a Feature Builder", "Building"],
    audit:   ["an audit", "Running"],
    quick:   ["a quick session", "Looking into"],
  }.freeze

  validates :title, :request, presence: true

  # The card follows the build: any change that could move it repaints the
  # message, and the parent's when this one speaks on it.
  after_commit :repaint_card, on: :update
  # NeedsYou reads builds: the Mini's dashboard fetches it again.
  after_commit -> { MiniDashboardChannel.changed(user) }

  scope :newest,     -> { order(created_at: :desc) }
  scope :unfinished, -> { where(status: [:starting, :running, :stopped]) }
  scope :portfolio,  -> { where(repo: FeatureBuilder::Repos::PORTFOLIO) }
  scope :to_pull, -> {
    where.not(repo: FeatureBuilder::Repos::PORTFOLIO).where.not(merge_sha: nil).where(pulled_at: nil)
  }

  # A builder's branch names its build: `byte/<id>-<slug>`, or
  # `feature-builder/<id>-<slug>` for the builds that started before it.
  BRANCH = %r{\A(?:byte|feature-builder)/(\d+)-}

  # The build a PR in `repo` belongs to, by its branch, or by its number for
  # the events that don't carry the branch (a comment on the PR's
  # conversation). Numbers repeat from one repo to the next.
  def self.for_pull_request(pull_request, repo: FeatureBuilder::Repos::PORTFOLIO)
    id = pull_request.to_h.dig("head", "ref").to_s[BRANCH, 1]
    (id && find_by(id: id, repo: repo)) || for_pr_number(pull_request.to_h["number"], repo: repo)
  end

  def self.for_pr_number(number, repo: FeatureBuilder::Repos::PORTFOLIO)
    number.present? ? find_by(pr_number: number, repo: repo) : nil
  end

  def portfolio?
    FeatureBuilder::Repos.portfolio?(repo)
  end

  def repo_name
    FeatureBuilder::Repos.short_name(repo)
  end

  # What the thread's system message says at each point. Every open one
  # carries a link: the session once there is one, and the builds page until
  # then.
  #
  # A card a later session carries on from shows that session: the work moved
  # there, so that is where it has got to. One that closed itself says so
  # briefly, since the message announcing it carries the reason.
  def status_line
    latest = latest_child
    return latest.status_line if latest

    return card("Closed itself", links: [pr_markdown]) if closed_itself? && closed_reason.present?
    return card("Closed: #{closed_reason}", links: [pr_markdown]) if closed_reason.present?

    what, doing = KIND_WORDS.fetch(kind.to_sym)
    case status.to_sym
    when :starting then card("Starting #{what} on the Mini#{images_note}…")
    when :failed then card("Couldn't start #{what}: #{error}")
    when :finished then card(finished_step, links: [pr_markdown], scripts: script_links)
    when :stopped then card("Stopped", links: [pr_markdown, link_markdown])
    else running_card(doing)
    end
  end

  # Where an open session has got to: its PR's place in the merge queue once
  # it has one, and otherwise whether the Mini last saw it working or at rest.
  def running_card(doing)
    live = FeatureBuilder.sessions.find { |session| session["build_id"].to_i == id }
    idle = live && !live["working"]
    return card(idle ? "Answered" : "Looking into it on the Mini") if kind_quick?
    if pr_url.present?
      return card(pr_step(live), links: [pr_markdown, link_markdown], scripts: script_links)
    end
    return card("Waiting on you") if idle

    doing = "Planning" if kind_feature? && live && planned_at.nil?
    card("#{doing}#{" in #{repo_name}" unless portfolio?} on the Mini")
  end

  def pr_step(live)
    return "Working on it again on the Mini" if live&.dig("working") && !MergeQueue.landing?(self)

    {
      landing:  "Merging",
      held:     "Held",
      approved: "Approved, in line to merge",
      answer:   "Waiting on you",
      review:   "Ready for review#{scripts_note}",
    }.fetch(MergeQueue.state(self))
  end

  # A merged build is deploying until production runs it, or, in another
  # repo, waiting until the laptop has pulled it.
  def finished_step
    return (pr_url.present? ? "PR closed without merging" : "Finished") if merge_sha.blank?
    return (pulled_at ? "Shipped" : "Merged, waiting to be pulled") unless portfolio?

    deployed_at ? "Shipped" : "Merged, deploying"
  end

  def repaint_card
    FeatureBuilder.repaint!(self)
    FeatureBuilder.repaint!(parent) if parent && parent.byte_message_id != byte_message_id
  end

  def latest_child
    children.order(:created_at).last
  end

  # Every message about a build has the same shape, so a thread of them scans
  # down the left edge: its name, what's happening now, where to go, then its
  # production scripts a line each.
  def card(step, links: [link_markdown], scripts: [])
    lines = ["**#{thread_title}**", step, links.compact_blank.join(" · "), *scripts]
    lines.compact_blank.join("\n")
  end

  # The name its card goes by: the first build in the chain it carries on from.
  def thread_title
    root = self
    seen = [id]
    while root.parent && seen.exclude?(root.parent_id)
      seen << root.parent_id
      root = root.parent
    end
    root.full_title
  end

  def images_note
    count = images.attachments.length
    return "" if count.zero?

    count == 1 ? " with 1 image" : " with #{count} images"
  end

  # The images as {filename, content_type, url}, signed for the Mini to fetch.
  def image_sources
    FeatureBuilder.image_sources(images)
  end

  # The most useful place to go for this build from a message about it.
  def link_markdown
    return "[Open it in Claude](#{rc_url})" if rc_url.present?

    "[See it on the Mini page](#{Rails.application.routes.url_helpers.system_claude_url})"
  end

  def pr_markdown
    "[#{"#{repo_name} " unless portfolio?}PR ##{pr_number}](#{pr_url})" if pr_url.present?
  end

  # Marks a production script's line on a card, so one reads as something to
  # run against production rather than another place to go.
  SCRIPT_ICON = "📜".freeze

  # The production scripts it sent, each linked to the page it's approved on,
  # for its card once it has a PR and the messages that say it's done. Empty
  # when it sent none.
  def script_links
    helpers = Rails.application.routes.url_helpers
    production_scripts.where.not(status: :skipped).order(:created_at).map { |script|
      url = helpers.system_production_script_url(script)
      "#{SCRIPT_ICON} Script: [#{script.title}](#{url}) (#{script.status_label})"
    }
  end

  # "" or ", with 2 production scripts to approve", for the step it's added to.
  def scripts_note
    count = script_links.length
    return "" if count.zero?

    ", with #{count} production #{count == 1 ? "script" : "scripts"} to approve"
  end

  # The phrase a person typed, cut to something that reads as a name in the
  # Claude app's session list and on a branch.
  # Titles were once cut at 60 characters; this is the whole line one was cut
  # from.
  def full_title
    return title unless title.end_with?("…")

    line = request.to_s.lines.first.to_s.strip
    line.start_with?(title.delete_suffix("…").rstrip) ? line : title
  end

  def self.title_for(request)
    request.to_s.lines.first.to_s.strip
  end
end
