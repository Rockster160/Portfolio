class Jarvis::Execute::Temporary < Jarvis::Execute::Executor
  include ActionView::Helpers::DateHelper

  def distance
    str = evalargs.first
    tt = AddressBook.new(jil.task.user).traveltime_seconds(str)
    distance_of_time_in_words(tt)
  end
end
