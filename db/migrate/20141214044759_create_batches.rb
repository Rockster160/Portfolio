class CreateBatches < ActiveRecord::Migration
  def change
    create_table :batches do |t|
      t.string :text

      t.timestamps
    end
  end
end
