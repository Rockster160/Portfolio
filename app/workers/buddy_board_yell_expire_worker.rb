# Stops a board yell whose `minutes` have run out (see Buddy::BoardYell). It
# names the telling it was set for, so a yell said again since stands on.
class BuddyBoardYellExpireWorker
  include Sidekiq::Worker

  sidekiq_options queue: :default, retry: 1

  def perform(board_id, key, raised_at)
    board = ByteConversation.find_by(id: board_id)
    return if board.nil?

    Buddy::BoardYell.clear!(board, key, raised_at: raised_at)
  end
end
