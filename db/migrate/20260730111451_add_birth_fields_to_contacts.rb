class AddBirthFieldsToContacts < ActiveRecord::Migration[7.1]
  def up
    add_column :contacts, :birth_month, :integer
    add_column :contacts, :birth_day, :integer
    add_column :contacts, :birth_year, :integer
    add_column :contacts, :maiden_name, :text

    execute(<<~SQL.squish)
      UPDATE contacts
      SET birth_month = EXTRACT(MONTH FROM birthday)::int,
          birth_day   = EXTRACT(DAY FROM birthday)::int,
          birth_year  = EXTRACT(YEAR FROM birthday)::int
      WHERE birthday IS NOT NULL
    SQL

    remove_column :contacts, :birthday
  end

  def down
    add_column :contacts, :birthday, :date

    execute(<<~SQL.squish)
      UPDATE contacts
      SET birthday = make_date(COALESCE(birth_year, 2000), birth_month, birth_day)
      WHERE birth_month IS NOT NULL AND birth_day IS NOT NULL
    SQL

    remove_column :contacts, :maiden_name
    remove_column :contacts, :birth_year
    remove_column :contacts, :birth_day
    remove_column :contacts, :birth_month
  end
end
