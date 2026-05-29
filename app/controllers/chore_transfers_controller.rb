class ChoreTransfersController < ApplicationController
  before_action :authorize_user_or_guest

  def create
    transfer = current_user.chore_transfers_sent.new(transfer_params)
    if transfer.save
      ChoreBroadcaster.broadcast_changes!(current_user)
      ChoreBroadcaster.broadcast_changes!(transfer.to_user) if transfer.to_user
      render json: payload(transfer), status: :created
    else
      render json: { errors: transfer.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def update
    transfer = sender_only_transfer(params[:id])
    return unless transfer

    if transfer.update(transfer_update_params)
      ChoreBroadcaster.broadcast_changes!(current_user)
      ChoreBroadcaster.broadcast_changes!(transfer.to_user) if transfer.to_user
      render json: payload(transfer)
    else
      render json: { errors: transfer.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def destroy
    transfer = sender_only_transfer(params[:id])
    return unless transfer

    recipient = transfer.to_user
    transfer.destroy!
    ChoreBroadcaster.broadcast_changes!(current_user)
    ChoreBroadcaster.broadcast_changes!(recipient) if recipient
    render json: {
      balance: current_user.chore_balance,
      today_earnings: ChoreCompletion
        .where(user_id: current_user.id, day_key: ChoreDay.current(current_user))
        .sum(:paid_pebbles),
    }
  end

  private

  # Only the sender can edit / delete a transfer — the recipient
  # never had agency over creating it, so they don't have agency over
  # mutating it either. Anyone else 404s.
  def sender_only_transfer(id)
    transfer = current_user.chore_transfers_sent.find_by(id: id)
    return transfer if transfer

    render json: { error: "not found" }, status: :not_found
    nil
  end

  def transfer_params
    params.require(:chore_transfer).permit(:to_user_id, :amount_pebbles, :note)
  end

  def transfer_update_params
    # Recipient is fixed for the life of the transfer — to redirect,
    # the user deletes + recreates. Amount/note/timestamp are mutable.
    params.require(:chore_transfer).permit(:amount_pebbles, :note, :created_at)
  end

  def payload(transfer)
    today = ChoreDay.current(current_user)
    today_earnings = current_user.chore_completions.where(day_key: today).sum(:paid_pebbles)
    {
      id: transfer.id,
      from_user_id: transfer.from_user_id,
      to_user_id:   transfer.to_user_id,
      amount_pebbles: transfer.amount_pebbles,
      note: transfer.note,
      created_at: transfer.created_at.iso8601,
      balance: current_user.chore_balance,
      today_earnings: today_earnings,
    }
  end
end
