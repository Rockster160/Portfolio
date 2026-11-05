class AddMachineToByteConversations < ActiveRecord::Migration[7.1]
  def up
    # 0 is the Mini and 1 the laptop (ByteConversation's `machine` enum). Shell
    # threads were always about the laptop; everything else moves to the Mini.
    add_column :byte_conversations, :machine, :integer, default: 0, null: false
    execute("UPDATE byte_conversations SET machine = 1 WHERE mode = 1")

    # Cursor (4) is gone from the mode enum; a row still holding it would raise
    # on read.
    execute("UPDATE byte_conversations SET mode = 0 WHERE mode = 4")
  end

  def down
    remove_column :byte_conversations, :machine
  end
end
