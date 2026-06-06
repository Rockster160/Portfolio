class AddTimerPageIdToTimerQuickButtons < ActiveRecord::Migration[7.1]
  def change
    add_reference :timer_quick_buttons, :timer_page,
                  foreign_key: true,
                  null:        true,
                  index:       true
  end
end
