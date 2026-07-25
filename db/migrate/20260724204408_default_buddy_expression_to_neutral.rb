class DefaultBuddyExpressionToNeutral < ActiveRecord::Migration[7.1]
  def up
    change_column_default :users, :buddy_expression, from: "happy", to: "neutral"
    # Reset every user still sitting on the old default. Anyone whose
    # expression genuinely diverged (checkin-driven celebrating, focused
    # from a [[mood]] shift, etc.) is intentionally NOT touched.
    User.where(buddy_expression: "happy").update_all(buddy_expression: "neutral")
  end

  def down
    change_column_default :users, :buddy_expression, from: "neutral", to: "happy"
    User.where(buddy_expression: "neutral").update_all(buddy_expression: "happy")
  end
end
