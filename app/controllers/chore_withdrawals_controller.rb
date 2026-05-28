class ChoreWithdrawalsController < ApplicationController
  before_action :authorize_user_or_guest

  def create
    amount = params.dig(:chore_withdrawal, :amount_pebbles).to_i
    note = params.dig(:chore_withdrawal, :note)
    if amount <= 0 || amount > current_user.chore_balance
      return render json: { error: "Invalid amount" }, status: :unprocessable_entity
    end

    withdrawal = current_user.chore_withdrawals.create!(amount_pebbles: amount, note: note)
    ChoreBroadcaster.broadcast_changes!(current_user)
    render json: {
      id: withdrawal.id,
      amount_pebbles: withdrawal.amount_pebbles,
      note: withdrawal.note,
      created_at: withdrawal.created_at.iso8601,
      balance: current_user.chore_balance,
    }, status: :created
  end

  def destroy
    withdrawal = current_user.chore_withdrawals.find(params[:id])
    withdrawal.destroy!
    ChoreBroadcaster.broadcast_changes!(current_user)
    render json: { balance: current_user.chore_balance }
  end
end
