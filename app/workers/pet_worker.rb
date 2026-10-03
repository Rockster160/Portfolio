# Passes one thing to terminal-pet on the Mac - see ByteLocal.pet.
#
# Off the request on purpose: logging a drink or ticking a row must not wait on
# a machine that is often asleep.
class PetWorker
  include Sidekiq::Worker

  # No retries. A drink fed to the pet hours late, once the Mac wakes, is worse
  # than one it never heard about.
  sidekiq_options retry: false

  # `PetWorker.tell(:feed, 10)`. Sidekiq args have to be plain JSON.
  def self.tell(verb, *words)
    perform_async(verb.to_s, words.flatten.map(&:to_s))
  end

  def perform(verb, words=[])
    result = ByteLocal.pet(verb, words)
    return if result[:ok]

    PrettyLogger.info("[Pet] #{verb} #{words.join(" ")}: #{result[:reply] || result[:error]}")
  end
end
