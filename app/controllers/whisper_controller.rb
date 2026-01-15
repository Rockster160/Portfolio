class WhisperController < ApplicationController
  def show
    @list = List.find(360)

    task_ids = [
      220, # Fed
      221, # Nap Toggle
      230, # Gone Toggle
      225, # Sleep
    ]
    @tasks = Task.where(id: task_ids).order(Arel.sql("FIELD(id, #{task_ids.join(", ")})"))
  end
end
