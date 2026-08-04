class CreateCustomCharts < ActiveRecord::Migration[7.1]
  # A saved chart definition over the ActionEvent log. `query` is a breaker/search
  # string (the same syntax Jil listeners use) that selects the events; `config`
  # is a free jsonb of chart shape (metric, series split, bucket, type) so new
  # options never need a migration.
  def change
    create_table :custom_charts do |t|
      t.belongs_to :user, index: true
      t.text :name
      t.text :query
      t.jsonb :config, default: {}, null: false
      t.integer :position

      t.timestamps
    end
  end
end
