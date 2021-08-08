class AddTimestampToAction < ActiveRecord::Migration[5.0]
  def change
    add_column :action_events, :timestamp, :datetime
    add_column :action_events, :notes, :text

    ActionEvent.find_each { |ae| ae.update(timestamp: ae.created_at) }
  end
end
