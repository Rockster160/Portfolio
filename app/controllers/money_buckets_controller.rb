class MoneyBucketsController < ApplicationController
  before_action :authorize_user_or_guest
  before_action :set_bucket

  def update
    @money_bucket.buckets = bucket_params[:bucket_data]
    @money_bucket.update(bucket_params.permit(:withdraw, :deposit))

    if @money_bucket.deposit_errors.present?
      render :show
    else
      redirect_to :money_buckets
    end
  end

  private

  def bucket_params
    params.require(:money_bucket)
  end

  def set_bucket
    @money_bucket ||= current_user.money_bucket || current_user.create_money_bucket
  end
end
