class DedupeAndUniquifyUserCaches < ActiveRecord::Migration[7.1]
  def up
    duplicates = UserCache.group(:user_id, :key).having("COUNT(*) > 1").pluck(:user_id, :key)
    duplicates.each { |user_id, key|
      rows = UserCache.where(user_id: user_id, key: key).order(:id).to_a
      survivor = rows.first
      losers = rows.drop(1)
      ordered = rows.sort_by { |r| [r.updated_at, r.id] }
      merged = ordered.reduce({}) { |acc, r| acc.deep_merge(r.data || {}) }
      survivor.update!(data: merged)
      losers.each(&:destroy!)
    }

    add_index :user_caches, [:user_id, :key], unique: true
  end

  def down
    remove_index :user_caches, [:user_id, :key]
  end
end
