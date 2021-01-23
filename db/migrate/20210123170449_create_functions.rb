class CreateFunctions < ActiveRecord::Migration[5.0]
  def change
    create_table :functions do |t|
      t.text :title
      t.text :arguments
      t.text :description
      t.datetime :deploy_begin_at
      t.datetime :deploy_finish_at
      t.text :proposed_code
      t.text :results

      t.timestamps
    end
  end
end
