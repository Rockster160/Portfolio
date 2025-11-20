class AddHierarchyToBoxes < ActiveRecord::Migration[7.1]
  def change
    add_column :boxes, :hierarchy, :text

    reversible do |dir|
      dir.up do
        Box.find_each do |box|
          box.hierarchy = (box.hierarchy_data.pluck(:name) + [box.name]).join(" > ")
          box.save!(validate: false)
        end
      end
    end
  end
end
