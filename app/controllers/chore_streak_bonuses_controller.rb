class ChoreStreakBonusesController < ApplicationController
  before_action :authorize_user_or_guest
  before_action :set_bonus, only: [:update, :destroy]

  def create
    bonus = current_user.chore_streak_bonuses.create!(bonus_params)
    render json: serialize(bonus), status: :created
  end

  def update
    @bonus.update!(bonus_params)
    render json: serialize(@bonus)
  end

  def destroy
    @bonus.destroy!
    head :no_content
  end

  private

  def set_bonus
    household_ids = current_user.chore_owner_user_ids
    @bonus = ChoreStreakBonus.where(user_id: household_ids).find(params[:id])
  end

  def bonus_params
    permitted = params.require(:chore_streak_bonus).permit(
      :name, :kind, :chore_id, :active,
      config: [levels: [:threshold, :multiplier, :bonus_pebbles]],
    )
    permitted[:chore_id] = nil unless permitted[:kind].to_s == "chore_streak"
    permitted[:config]   = normalize_config(permitted[:config])
    permitted
  end

  # Drops empty rows, coerces numerics, keeps only the three known keys.
  # Multipliers are integers only — fractional input is floored.
  def normalize_config(config)
    levels = Array(config&.dig(:levels)).filter_map { |lvl|
      threshold  = lvl[:threshold].to_s.strip
      multiplier = lvl[:multiplier].to_s.strip
      bonus      = lvl[:bonus_pebbles].to_s.strip
      next if threshold.empty? && multiplier.empty? && bonus.empty?

      {
        "threshold"     => threshold.to_i,
        "multiplier"    => multiplier.empty? ? 1 : multiplier.to_i,
        "bonus_pebbles" => bonus.to_i,
      }
    }
    { "levels" => levels }
  end

  def serialize(bonus)
    {
      id:       bonus.id,
      name:     bonus.name,
      kind:     bonus.kind,
      active:   bonus.active,
      chore_id: bonus.chore_id,
      config:   bonus.config,
      html: render_to_string(
        partial: "chores/streak_bonus_card",
        formats: [:html],
        locals: { bonus: bonus },
      ),
    }
  end
end
