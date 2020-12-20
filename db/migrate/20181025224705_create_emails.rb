class CreateEmails < ActiveRecord::Migration[5.0]
  def change
    create_table :emails do |t|
      t.belongs_to :sent_by
      t.string :from
      t.string :to
      t.string :subject
      t.text :blob
      t.text :text_body
      t.text :html_body

      t.datetime :read_at
      t.datetime :deleted_at
      t.timestamps
    end
  end
end
