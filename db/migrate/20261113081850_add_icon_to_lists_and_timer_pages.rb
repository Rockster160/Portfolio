class AddIconToListsAndTimerPages < ActiveRecord::Migration[7.1]
  def change
    [:lists, :timer_pages].each do |table|
      change_table(table, bulk: true) { |t|
        t.string :icon
        t.string :icon_color
        t.binary :icon_png
      }
    end
  end
end
