# Reading the room is a SIDE EFFECT of nearly every Buddy turn: settling the
# expression enqueues BuddySentimentWorker, Sidekiq runs inline in specs, and
# so a hundred and twenty-seven examples reached out to OpenAI and died on
# WebMock — over a face not one of them asserts anything about.
#
# Answer "couldn't read it" by default. That's the honest unknown path and it
# is the one production already has to handle: Buddy::Sentiment#settle! falls
# back to the old pick, which is exactly what these examples saw before there
# was a reading at all, so nothing that wasn't about this changed shape.
#
# A spec that wants the real thing calls `and_call_original` in its own before
# hook and wins, since example-group hooks run after this one.
RSpec.configure do |config|
  config.before { allow(Buddy::Sentiment).to receive(:read).and_return(nil) }
end
