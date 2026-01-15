class WhisperController < ApplicationController
  def show
    @list = List.find(360)
    @tasks = Task.where(id: [220, 221, 225])
  end
end
