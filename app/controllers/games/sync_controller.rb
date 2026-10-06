# The one mutation endpoint for a play in progress. Everything is upserted
# by client_uuid, so a replayed batch (the offline queue's whole reason for
# being) is harmless - including the PLAY itself, which is why this also
# handles "Start game" rather than a separate create action: the phone may
# be offline when the game starts, and the play needs its own client-minted
# uuid to exist before the server has ever seen it.
class Games::SyncController < ApplicationController
  before_action :authorize_user

  def create
    play = current_user.game_plays.find_or_initialize_by(client_uuid: params[:client_uuid])
    creating = play.new_record?

    ActiveRecord::Base.transaction do
      apply_play_attrs!(play, creating)
      play.save!
      play.ensure_action_event! if creating
      upsert_rolls!(play)
      upsert_scores!(play)
      apply_voids!(play)
    end

    render json: {
      play:      { id: play.id, client_uuid: play.client_uuid, current_player_index: play.current_player_index, status: play.status },
      rolls:     play.game_rolls.live.ordered.pluck(:client_uuid),
      scores:    play.game_score_entries.live.ordered.pluck(:client_uuid),
      server_ts: Time.current.iso8601(3),
    }
  end

  private

  def apply_play_attrs!(play, creating)
    data = play_params
    if creating
      play.user = current_user
      play.game_template_id = data[:game_template_id]
      play.name = data[:name].presence || "Game"
      play.settings = (data[:settings] || {}).deep_stringify_keys
      play.players = (data[:players] || []).map(&:deep_stringify_keys)
      play.dice_mode = data[:dice_mode].presence || :manual
      play.started_at = parse_iso(data[:started_at]) || Time.current
      play.status = :active
    end
    play.current_player_index = data[:current_player_index] if data[:current_player_index].present?
    play.dice_mode = data[:dice_mode] if !creating && data[:dice_mode].present?
    play.players = data[:players].map(&:deep_stringify_keys) if data[:players].present?
    play.settings = play.settings.merge(data[:settings].deep_stringify_keys) if data[:settings].present?
  end

  def upsert_rolls!(play)
    Array(params[:rolls]).each do |raw|
      roll = raw.permit(:client_uuid, :player_name, :player_index, :value, :dice, :source, :rolled_at, faces: [])
      next if roll[:client_uuid].blank? || play.game_rolls.exists?(client_uuid: roll[:client_uuid])

      play.game_rolls.create!(
        client_uuid: roll[:client_uuid], player_name: roll[:player_name], player_index: roll[:player_index].to_i,
        value: roll[:value].to_i, dice: roll[:dice], faces: roll[:faces],
        source: roll[:source].presence || :button, rolled_at: parse_iso(roll[:rolled_at]) || Time.current
      )
    rescue ActiveRecord::RecordNotUnique
      next
    end
  end

  def upsert_scores!(play)
    Array(params[:scores]).each do |raw|
      score = raw.permit(:client_uuid, :player_name, :delta, :entered_at)
      next if score[:client_uuid].blank? || play.game_score_entries.exists?(client_uuid: score[:client_uuid])

      play.game_score_entries.create!(
        client_uuid: score[:client_uuid], player_name: score[:player_name], delta: score[:delta].to_i,
        entered_at: parse_iso(score[:entered_at]) || Time.current
      )
    rescue ActiveRecord::RecordNotUnique
      next
    end
  end

  def apply_voids!(play)
    Array(params[:voids]).each do |raw|
      void = raw.permit(:kind, :client_uuid)
      next if void[:client_uuid].blank?

      case void[:kind].to_s
      when "roll"  then play.game_rolls.find_by(client_uuid: void[:client_uuid])&.void!
      when "score" then play.game_score_entries.find_by(client_uuid: void[:client_uuid])&.void!
      end
    end
  end

  def play_params
    params.require(:play).permit(
      :game_template_id, :name, :dice_mode, :started_at, :current_player_index,
      players: [:name, :color, :team], settings: {}
    ).to_h.deep_symbolize_keys
  rescue ActionController::ParameterMissing
    {}
  end

  def parse_iso(str)
    return nil if str.blank?

    current_user.parse_time(str)
  rescue ArgumentError
    nil
  end
end
