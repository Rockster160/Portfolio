class RefactorActionEventDate < ActiveRecord::Migration[7.1]
  def up
    JilTask.refactor_function("ActionEventData.date") do |line|
      line.methodname = :timestamp
    end
  end
end
