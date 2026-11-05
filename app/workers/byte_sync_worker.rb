# Brings the Mac Mini's copies of Byte, Portfolio and Claude's memory up to
# date. Enqueued whenever Sidekiq boots in production, which is every deploy.
#
# The laptop does most of it: it pushes Byte and the memory to the Mini, then
# asks the Mini to pull Portfolio. When the laptop is shut, the Mini is asked
# directly and does the one part that needs nothing from the laptop.
class ByteSyncWorker
  include Sidekiq::Worker

  # A missed sync costs nothing but staleness until the next deploy, and a
  # retry would only land on a laptop that is still asleep.
  sidekiq_options queue: :default, retry: false

  def perform
    return if ByteLocal.sync(:laptop)

    ByteLocal.sync(:mini)
  end
end
