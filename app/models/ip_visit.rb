# == Schema Information
#
# Table name: ip_visits
#
#  id            :bigint           not null, primary key
#  first_seen_at :datetime
#  ip_address    :string           not null
#  last_seen_at  :datetime
#  visit_count   :integer          default(0), not null
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#
class IpVisit < ApplicationRecord
  validates :ip_address, presence: true, uniqueness: true

  # Count this request and return how many came before it — which is exactly
  # what `log_trackers.ip_count` has always meant, so an unseen IP still
  # reports 0 and still renders as new in the log viewer.
  #
  # Written as one statement rather than find-then-update because concurrent
  # requests from the same IP would otherwise race and lose increments.
  # ON CONFLICT makes the whole thing atomic against the unique index.
  def self.record!(ip_address)
    return 0 if ip_address.blank?

    now = ::Time.current
    result = connection.exec_query(
      sanitize_sql_array([<<~SQL.squish, ip_address, now, now, now, now]),
        INSERT INTO ip_visits
          (ip_address, visit_count, first_seen_at, last_seen_at, created_at, updated_at)
        VALUES (?, 1, ?, ?, ?, ?)
        ON CONFLICT (ip_address) DO UPDATE SET
          visit_count = ip_visits.visit_count + 1,
          last_seen_at = EXCLUDED.last_seen_at,
          updated_at = EXCLUDED.updated_at
        RETURNING visit_count
      SQL
      "IpVisit Upsert",
    )

    result.first["visit_count"].to_i - 1
  end
end
