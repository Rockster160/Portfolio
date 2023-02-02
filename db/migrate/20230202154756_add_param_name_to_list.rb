class AddParamNameToList < ActiveRecord::Migration[7.0]
  def change
    add_column :lists, :parameterized_name, :text

    List.find_each(&:save)
  end
end
