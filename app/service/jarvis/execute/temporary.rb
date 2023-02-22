class Jarvis::Execute::Temporary < Jarvis::Execute::Executor
  def distance
    str = evalargs.first
    tt = AddressBook.new(jil.user).traveltime_seconds(str)
    ActionView::Helpers::DateHelper.distance_of_time_in_words(tt)
  end
end
