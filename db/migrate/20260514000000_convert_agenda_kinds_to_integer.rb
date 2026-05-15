class ConvertAgendaKindsToInteger < ActiveRecord::Migration[7.1]
  def up
    change_column :agenda_items, :kind, :integer,
      using: "CASE kind WHEN 'event' THEN 1 ELSE 0 END",
      null:  false
    change_column :agenda_schedules, :kind, :integer,
      using: "CASE kind WHEN 'event' THEN 1 ELSE 0 END",
      null:  false
  end

  def down
    change_column :agenda_items, :kind, :string,
      using: "CASE kind WHEN 1 THEN 'event' ELSE 'task' END",
      null:  false
    change_column :agenda_schedules, :kind, :string,
      using: "CASE kind WHEN 1 THEN 'event' ELSE 'task' END",
      null:  false
  end
end
