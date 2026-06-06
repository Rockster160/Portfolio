class AllowNullDurationSecondsOnTimerQuickButtons < ActiveRecord::Migration[7.1]
  def change
    change_column_null :timer_quick_buttons, :duration_seconds, true
  end
end
