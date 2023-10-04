class CreateJilForm < ActiveRecord::Migration[7.0]
  def change
    create_table :jil_prompts do |t|
      t.text :question
      t.jsonb :params
      t.jsonb :options
      t.jsonb :response
      t.integer :answer_type
      t.references :task
      t.references :user

      t.timestamps
    end
  end
end
