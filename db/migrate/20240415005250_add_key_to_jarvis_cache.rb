class AddKeyToJarvisCache < ActiveRecord::Migration[7.1]
  def change
    add_column :jarvis_caches, :key, :string
  end
end
