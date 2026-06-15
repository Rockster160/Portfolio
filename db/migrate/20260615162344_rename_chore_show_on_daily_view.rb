class RenameChoreShowOnDailyView < ActiveRecord::Migration[7.1]
  def up
    rename_column :chores, :show_on_daily_view, :show_on_today_view
    if index_name_exists?(:chores, :index_chores_on_show_on_daily_view)
      rename_index :chores, :index_chores_on_show_on_daily_view, :index_chores_on_show_on_today_view
    end
  end

  def down
    rename_column :chores, :show_on_today_view, :show_on_daily_view
    if index_name_exists?(:chores, :index_chores_on_show_on_today_view)
      rename_index :chores, :index_chores_on_show_on_today_view, :index_chores_on_show_on_daily_view
    end
  end
end
