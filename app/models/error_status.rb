# == Schema Information
#
# Table name: error_statuses
#
#  id          :bigint           not null, primary key
#  fingerprint :text             not null
#  status      :integer          not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  user_id     :bigint
#
class ErrorStatus < ApplicationRecord
  # What has been decided about a failure on `/system/errors`, keyed by its
  # fingerprint so it covers every occurrence, past and to come. No row is open:
  # nobody has said anything about it yet.
  #
  #   resolved  believed fixed. The next occurrence is announced as having come
  #             back and the row goes, so it is open again.
  #   ignored   known and not worth hearing about. Occurrences are still
  #             recorded and still listed; they are just never announced.
  belongs_to :user, optional: true

  enum :status, { resolved: 0, ignored: 1 }

  # { fingerprint => status row }
  def self.for(fingerprints) = where(fingerprint: fingerprints).index_by(&:fingerprint)

  # `:open` clears whatever was decided.
  def self.set!(fingerprint, status, user:)
    if status.to_sym == :open
      where(fingerprint: fingerprint).delete_all
      return nil
    end

    row = find_or_initialize_by(fingerprint: fingerprint)
    row.update!(status: status, user: user)
    row
  end
end
