class RefactorActionEventSearch < ActiveRecord::Migration[7.1]
  def up
    JilTask.refactor_function("ActionEvent.search") do |line|
      q, limit, date, order = line.args

      if date != "\"\""
        if q.match?(/\A\".*?\"\z/)
          q = q.gsub(/\"\z/, " after:\#{#{date}}\"")
        else
          q = "\"\#{#{q}} after:\#{#{date}}\""
        end
      end

      line.args = [q, limit, order]
    end
  end
end
