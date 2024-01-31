class AddReturnDataToJarvisTask < ActiveRecord::Migration[7.1]
  def change
    remove_column :jarvis_tasks, :last_result, :text
    remove_column :jarvis_tasks, :last_result_val, :text

    add_column :jarvis_tasks, :return_data, :jsonb, default: { data: nil }.to_json
    add_column :jarvis_tasks, :output_text, :text
  end
end
