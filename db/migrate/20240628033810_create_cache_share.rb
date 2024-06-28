class CreateCacheShare < ActiveRecord::Migration[7.1]
  def change
    create_table :cache_shares do |t|
      t.belongs_to :user
      t.belongs_to :jarvis_cache

      t.timestamps
    end
  end
end
