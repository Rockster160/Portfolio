class AddHexParamToBox < ActiveRecord::Migration[7.1]
  def change
    add_column :boxes, :param_key, :text
    add_index :boxes, :param_key, unique: true

    reversible do |dir|
      dir.up do
        say_with_time "Generating param_key for existing boxes" do
          Box.find_each { |box|
            box.send(:set_param_key)
            box.save!
          }
        end
      end
    end
  end
end
