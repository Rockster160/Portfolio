# == Schema Information
#
# Table name: production_scripts
#
#  id               :bigint           not null, primary key
#  approved_at      :datetime
#  code             :text             not null
#  commit_sha       :string           not null
#  edited_by        :string           not null
#  exit_status      :integer
#  output           :text
#  ran_at           :datetime
#  started_at       :datetime
#  status           :integer          default("pending"), not null
#  title            :string           not null
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  feature_build_id :bigint
#  user_id          :bigint           not null
#

# A script to run once against production, the way `prodExec` runs a file:
# written by a Feature Builder session on the Mini (or by hand), and run only
# after the owner approves it on /system/production_scripts.
#
# `commit_sha` is the commit the script needs: it waits until that commit is
# part of what is deployed. Any change to the code takes the approval away
# again, whoever made it, so what runs is always what was approved.
class ProductionScript < ApplicationRecord
  belongs_to :user
  belongs_to :feature_build, optional: true

  # pending    written or changed, waiting on approval
  # approved   approved; runs as soon as its commit is deployed
  # running    `rails runner` has it now
  # succeeded  it ran and exited cleanly (`output` holds what it printed)
  # failed     it ran and raised or exited non-zero
  # skipped    set aside by hand; never runs
  enum :status, {
    pending:   0,
    approved:  1,
    running:   2,
    succeeded: 3,
    failed:    4,
    skipped:   5,
  }, prefix: :status

  EDITORS = %i[owner mini].freeze
  COMMITS_URL = "https://github.com/Rockster160/Portfolio/commit".freeze
  # The end of what it printed is kept, which is where a failure says why.
  OUTPUT_LIMIT = 200_000

  validates :title, :code, :commit_sha, presence: true
  validates :commit_sha, format: { with: /\A\h{7,40}\z/ }
  validates :edited_by, inclusion: { in: EDITORS.map(&:to_s) }
  validate :unchanged_while_running, on: :update

  before_save :withdraw_approval, if: :code_changed?, unless: :new_record?

  scope :newest, -> { order(created_at: :desc) }
  # What the System page counts: still to run, or ran and failed.
  scope :outstanding, -> { where(status: [:pending, :approved, :failed]) }

  def approvable?
    status_pending? || status_failed?
  end

  def status_label
    case status.to_sym
    when :pending   then "waiting on approval"
    when :approved  then "approved, waiting for its deploy"
    when :succeeded then "ran"
    else status
    end
  end

  def short_sha
    commit_sha.first(8)
  end

  def commit_url
    "#{COMMITS_URL}/#{commit_sha}"
  end

  private

  def withdraw_approval
    return if status_skipped?

    self.status = :pending
    self.approved_at = nil
  end

  def unchanged_while_running
    errors.add(:code, "can't change while it's running") if code_changed? && status_was == "running"
  end
end
