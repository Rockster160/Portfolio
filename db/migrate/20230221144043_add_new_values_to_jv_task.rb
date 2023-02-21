class AddNewValuesToJvTask < ActiveRecord::Migration[7.0]
  def change
    add_column :jarvis_tasks, :sort_order, :integer
    add_column :jarvis_tasks, :last_result_val, :text

    # Bad practice, but personal project and nobody else using these
    change_column_default :jarvis_tasks, :trigger, from: nil, to: 0

    JarvisTask.where(trigger: nil).update_all(trigger: 0)
    JarvisTask.where.not(cron: ["", nil]).find_each { |j| j.update(input: j.cron) }
  end
end
