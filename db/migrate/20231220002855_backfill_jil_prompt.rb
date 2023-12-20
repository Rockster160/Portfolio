class BackfillJilPrompt < ActiveRecord::Migration[7.0]
  def up
    JilPrompt.find_each do |prompt|
      prompt.update(options: { actions: prompt.options })
    end
  end

  def down
    JilPrompt.find_each do |prompt|
      prompt.update(options: prompt.options["actions"])
    end
  end
end
