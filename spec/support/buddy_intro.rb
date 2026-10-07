# Opening a Buddy thread now posts a hidden seed and dispatches a turn, so the
# pet can say who it is (Buddy::Intro). Sidekiq runs INLINE in specs, so every
# example that creates a conversation through the controller started reaching
# out to OpenAI and dying on WebMock — twenty-one of them in byte_controller
# alone, over a message not one of them asserts anything about.
#
# Same shape and same reason as spec/support/buddy_sentiment.rb: answer "did
# nothing" by default, which is also what Intro.start! honestly returns for a
# thread that is not a new Buddy one.
#
# A spec that wants the real thing calls `and_call_original` in its own before
# hook and wins, since example-group hooks run after this one.
RSpec.configure do |config|
  config.before { allow(Buddy::Intro).to receive(:start!).and_return(nil) }
end
