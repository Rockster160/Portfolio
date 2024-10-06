class RenameTriggerFunctions < ActiveRecord::Migration[7.1]
  def up
    JilTask.rename_function("Global.trigger(", "Global.triggerNow(")
  end
end
