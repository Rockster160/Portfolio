class BackfillKeywords < ActiveRecord::Migration[7.1]
  def change
    keywords = [
      "Object",
      "Key",
      "Value",
      "Index",
      "Break",
      "Next",
      "Item",
      "Arg",
      "FuncReturn",
    ]
    rx = /Global\.(#{keywords.join("|")})/

    JilTask.find_each do |task|
      next unless task.code.match?(rx)

      task.update(code: task.code.gsub(rx) { "Keyword.#{Regexp.last_match[1]}" })
    end
  end
end
