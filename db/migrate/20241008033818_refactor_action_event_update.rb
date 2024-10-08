class RefactorActionEventUpdate < ActiveRecord::Migration[7.1]
  def up
    # Luckily ActionEvent is the only one using this function right now...
    JilTask.refactor_function(".update") do |line|
      line.methodname = :change
    end
  end
end
