class CreateMoneyBuckets < ActiveRecord::Migration[5.0]
  def change
    create_table :money_buckets do |t|
      t.belongs_to :user

      t.text :bucket_json
    end
  end
end
