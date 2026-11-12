# == Schema Information
#
# Table name: feature_builds
#
#  id                   :bigint           not null, primary key
#  approved_at          :datetime
#  asked_at             :datetime
#  branch               :string
#  closed_reason        :text
#  deployed_at          :datetime
#  error                :text
#  feedback             :jsonb            not null
#  finished_at          :datetime
#  held                 :boolean          default(FALSE), not null
#  landing_at           :datetime
#  merge_sha            :string
#  planned_at           :datetime
#  pr_number            :integer
#  pr_url               :string
#  question             :text
#  queue_position       :integer
#  rc_url               :string
#  request              :text             not null
#  status               :integer          default("starting"), not null
#  title                :string           not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  byte_conversation_id :bigint
#  byte_message_id      :bigint
#  feature_request_id   :bigint
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
# rather than followed by more of them.
class FeatureBuild < ApplicationRecord
  belongs_to :user
  belongs_to :byte_conversation, optional: true
  belongs_to :byte_message, optional: true
  # Set when it was started from a row on /system/feature_requests.
  belongs_to :feature_request, optional: true
  has_many :production_scripts, dependent: :nullify

  # starting   asked for; the Mini hasn't said it's up yet
  # running    the session is open (working or waiting on an answer)
  # stopped    the session was closed from the system page; the work is kept
  # finished   its PR was merged or closed, or the session closed itself
  #            (`closed_reason` says why), and the worktree is gone
  # failed     the Mini couldn't start it (`error` says why)
  #
  # `planned_at` is when the session first posted its ticket (`builder-pr plan`).
  enum :status, { starting: 0, running: 1, stopped: 2, finished: 3, failed: 4 }, prefix: :status

  validates :title, :request, presence: true

  scope :newest,     -> { order(created_at: :desc) }
  scope :unfinished, -> { where(status: [:starting, :running, :stopped]) }

  # A builder's branch names its build: `byte/<id>-<slug>`, or
  # `feature-builder/<id>-<slug>` for the builds that started before it.
  BRANCH = %r{\A(?:byte|feature-builder)/(\d+)-}

  # The build a PR belongs to, by its branch, or by its number for the events
  # that don't carry the branch (a comment on the PR's conversation).
  def self.for_pull_request(pull_request)
    id = pull_request.to_h.dig("head", "ref").to_s[BRANCH, 1]
    (id && find_by(id: id)) || for_pr_number(pull_request.to_h["number"])
  end

  def self.for_pr_number(number)
    number.present? ? find_by(pr_number: number) : nil
  end

  # What the thread's system message says at each point. Every one carries a
  # link: the session once there is one, and the builds page until then.
  def status_line
    return "Closed **#{title}**: #{closed_reason}" if closed_reason.present?

    case status.to_sym
    when :starting then "Starting a Feature Builder on the Mini for **#{title}**… #{link_markdown}"
    when :failed   then "Couldn't start the Feature Builder for **#{title}**: #{error} #{link_markdown}"
    else "Building **#{title}** on the Mini. #{link_markdown}"
    end
  end

  # The most useful place to go for this build from a message about it.
  def link_markdown
    return "[Open it in Claude](#{rc_url})" if rc_url.present?

    "[See it on the Mini page](#{Rails.application.routes.url_helpers.system_claude_url})"
  end

  # The phrase a person typed, cut to something that reads as a name in the
  # Claude app's session list and on a branch.
  def self.title_for(request)
    line = request.to_s.lines.first.to_s.strip
    line.length > 60 ? "#{line[0, 57].rstrip}…" : line
  end
end
