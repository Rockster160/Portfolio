class ChoreWithdrawalsController < ApplicationController
  before_action :authorize_user_or_guest

  def create
    amount = params.dig(:chore_withdrawal, :amount_pebbles).to_i
    note = params.dig(:chore_withdrawal, :note)
    if amount <= 0 || amount > current_user.chore_balance
      return render json: { error: "Invalid amount" }, status: :unprocessable_entity
    end

    withdrawal = current_user.chore_withdrawals.create!(amount_pebbles: amount, note: note)
    ChoreGoal.refresh_all_for(current_user)
    ChoreBroadcaster.broadcast_changes!(current_user)
    render json: {
      id: withdrawal.id,
      amount_pebbles: withdrawal.amount_pebbles,
      note: withdrawal.note,
      created_at: withdrawal.created_at.iso8601,
      balance: current_user.chore_balance,
      today_earnings: today_earnings,
    }, status: :created
  end

  def update
    withdrawal = current_user.chore_withdrawals.find(params[:id])
    if withdrawal.update(withdrawal_update_params)
      ChoreGoal.refresh_all_for(current_user)
    ChoreBroadcaster.broadcast_changes!(current_user)
      render json: {
        id: withdrawal.id,
        amount_pebbles: withdrawal.amount_pebbles,
        note: withdrawal.note,
        created_at: withdrawal.created_at.iso8601,
        balance: current_user.chore_balance,
        today_earnings: today_earnings,
      }
    else
      render json: { errors: withdrawal.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def destroy
    withdrawal = current_user.chore_withdrawals.find(params[:id])
    withdrawal.destroy!
    ChoreGoal.refresh_all_for(current_user)
    ChoreBroadcaster.broadcast_changes!(current_user)
    # `today_earnings` is unaffected by withdrawals (it sums completion
    # payouts on the current chore-day), but the controller emits it
    # anyway so the client can keep the header pill stable rather than
    # having to special-case which endpoints touch it. The pill is
    # always today_earnings, everywhere.
    render json: {
      balance: current_user.chore_balance,
      today_earnings: today_earnings,
    }
  end

  private

  def withdrawal_update_params
    params.require(:chore_withdrawal).permit(:amount_pebbles, :note, :created_at)
  end

  def today_earnings
    today = ChoreDay.current(current_user)
    current_user.chore_completions.where(day_key: today).sum(:paid_pebbles)
  end
end
