class AddTriggerExpressionToAgenda < ActiveRecord::Migration[7.1]
  def change
    add_column :agenda_schedules, :trigger_expression, :text
    add_column :agenda_items, :trigger_expression, :text
  end
end
