class AddTemplateToTimerQuickButtons < ActiveRecord::Migration[7.1]
  def change
    add_column :timer_quick_buttons, :template, :jsonb, null: false, default: {}
  end
end
