class GamesController < ApplicationController
  before_action :authorize_user
  # Games themes itself from the phone's own light/dark setting. The site's
  # html.dark-mode class drags in `.dark-mode button:hover` (0,2,1), which
  # outranks every games button rule and leaves a tapped key painted blue.
  before_action { @skip_dark_mode = true }
  before_action :set_play, only: [:show, :edit_finish, :finish, :abandon, :replay]

  # GET /games
  def index
    @active_play = current_user.game_plays.active.order(started_at: :desc).first
    @history = history_rows
    @tiles = template_tiles(@history)
    render :index
  end

  # GET /games/plays/:id - a live play (own screen, driven by JS + the
  # offline queue) or a finished/abandoned one (plain read-only stats page).
  # One URL, real and bookmarkable either way - which is the whole point.
  def show
    if @play.active?
      @play_bootstrap = serialize_play(@play)
      render :play
    else
      @stats = GamePlay::Stats.for_play(@play)
      render :show
    end
  end

  # POST /games/plays/:id/replay - same template, settings and players as
  # @play, first player rotated by one. Starts immediately, no form: asking
  # for players again is Setup's job (a template picked fresh), not a
  # specific past play's.
  def replay
    new_play = current_user.game_plays.create!(
      game_template_id: @play.game_template_id,
      client_uuid:      SecureRandom.uuid,
      name:             @play.name,
      settings:         @play.settings,
      players:          @play.players.rotate,
      dice_mode:        @play.dice_mode,
      started_at:       Time.current,
      status:           :active,
    )
    new_play.ensure_action_event!
    redirect_to game_play_path(new_play.id)
  end

  # GET /games/new
  def new
    @templates = current_user.game_templates.by_last_played.to_a
    render :new
  end

  # GET /games/plays/:id/finish - the end-of-game form. A real page, a real
  # <form>, posts to #finish below and redirects back to #show on success.
  def edit_finish
    @score_totals = @play.game_score_entries.live.group(:player_name).sum(:delta)
    render :finish
  end

  # POST /games/plays/:client_uuid/finish
  def finish
    @play.finish!(
      final_scores:     numeric_scores(finish_params[:final_scores]),
      started_at:       parse_iso(finish_params[:started_at]) || @play.started_at,
      ended_at:         parse_iso(finish_params[:ended_at]) || Time.current,
      duration_minutes: finish_params[:duration_minutes].presence&.to_i,
    )
    respond_to do |format|
      format.html { redirect_to game_play_path(@play.id) }
      format.json { render json: serialize_play(@play).merge(stats: GamePlay::Stats.for_play(@play)) }
    end
  end

  # POST /games/plays/:client_uuid/abandon
  def abandon
    @play.abandon!
    respond_to do |format|
      format.html { redirect_to games_path }
      format.json { render json: serialize_play(@play) }
    end
  end

  # GET /games/legacy/:id - a manually-logged Game ActionEvent that never
  # got linked to a play (new manual logging keeps working this way; see
  # Task 283). Everything backfilled now lives at #show instead.
  def legacy_show
    @event = current_user.action_events.where(name: "Game").find(params[:id])
  end

  # GET /games/player_colors -> { "chelsea" => "#d6609a", ... }
  #
  # One query over every play's `players` jsonb. The most RECENT play with a
  # given name wins, so a changed colour propagates forward without
  # rewriting history. Cached client-side so it works offline.
  def player_colors
    colors = {}
    current_user.game_plays.order(created_at: :asc).pluck(:players).each do |players|
      Array(players).each do |p|
        name = p["name"].to_s.strip.downcase
        colors[name] = p["color"] if name.present? && p["color"].present?
      end
    end
    render json: colors
  end

  # POST /games/templates - create or save-to-template from New Game
  def upsert_template
    template = params[:id].presence ? current_user.game_templates.find(params[:id]) : current_user.game_templates.build
    template.assign_attributes(template_params)
    template.save!
    render json: serialize_template(template), status: (template.previously_new_record? ? :created : :ok)
  end

  private

  # One feed: finished/abandoned plays from this app, plus any legacy `Game`
  # ActionEvent that was never linked to a play (manual logging that happens
  # outside the app keeps working, per Task 283).
  def history_rows
    played = current_user.game_plays.where(status: [:finished, :abandoned]).map { |p|
      {
        source:           "play",
        id:               p.id,
        template_id:      p.game_template_id,
        name:             p.name,
        colors:           Array(p.players).to_h { |pl| [pl["name"], pl["color"]] },
        date:             (p.started_at || p.created_at).iso8601(3),
        duration_minutes: p.duration,
        winner_names:     p.winner_names,
        final_scores:     p.final_scores,
        abandoned:        p.abandoned?,
      }
    }
    legacy = current_user.action_events.where(name: "Game").reject { |e| e.data.to_h["play_id"].present? }.map { |e|
      data = e.data.to_h
      {
        source:           "legacy",
        id:               e.id,
        template_id:      nil,
        name:             e.notes,
        colors:           {},
        date:             e.timestamp.iso8601(3),
        duration_minutes: data["duration"].presence&.to_i,
        winner_names:     [],
        final_scores:     data["players"] || {},
        abandoned:        !!data["abandoned"],
      }
    }
    (played + legacy).sort_by { |r| r[:date] }.reverse
  end

  def set_play
    @play = find_play!(params[:id] || params[:client_uuid])
  end

  def find_play!(token)
    by_uuid = current_user.game_plays.find_by(client_uuid: token) if token.to_s.include?("-")
    by_uuid || current_user.game_plays.find(token)
  end

  # The form posts every score as a string. Compared as strings, "55" beats
  # "130" and the wrong person wins; a blank box is "no score", not 0.
  def numeric_scores(raw)
    raw.to_h.transform_values { |v| v.to_s.strip.match?(/\A-?\d+\z/) ? v.to_i : nil }
  end

  # Every saved game, most recently played first, with how often it's been
  # played - counting manually logged events filed under its name or an alias.
  def template_tiles(history)
    current_user.game_templates.by_last_played.map { |t|
      names = [t.name, *Array(t.aliases)].map { |n| n.to_s.strip.downcase }
      rows = history.select { |r| r[:template_id] == t.id || names.include?(r[:name].to_s.strip.downcase) }
      { template: t, plays: rows.size, last_played: rows.map { |r| r[:date] }.max }
    }.sort_by { |tile| tile[:last_played].to_s }.reverse
  end

  def finish_params
    params.permit(:started_at, :ended_at, :duration_minutes, final_scores: {}).to_h.symbolize_keys
  end

  def template_params
    params.permit(:name, :dice, :scoring, :win, :auto_advance, score_presets: [], aliases: [])
  end

  # current_user.parse_time, not a bare Time.zone.parse - the finish form's
  # `started_at` is a zoneless datetime-local string, and parsing that
  # against the wrong zone silently shifts it by hours.
  def parse_iso(str)
    return nil if str.blank?

    current_user.parse_time(str)
  rescue ArgumentError
    nil
  end

  def serialize_template(t)
    {
      id:             t.id,
      name:           t.name,
      dice:           t.dice,
      scoring:        t.scoring,
      win:            t.win,
      auto_advance:   t.auto_advance,
      score_presets:  t.score_presets,
      aliases:        t.aliases,
      last_played_at: t.game_plays.maximum(:started_at)&.iso8601(3),
    }
  end

  def serialize_play(play)
    {
      id:                   play.id,
      client_uuid:          play.client_uuid,
      name:                 play.name,
      game_template_id:     play.game_template_id,
      settings:             play.settings,
      players:              play.players,
      started_at:           play.started_at&.iso8601(3),
      ended_at:             play.ended_at&.iso8601(3),
      duration_minutes:     play.duration,
      dice_mode:            play.dice_mode,
      status:               play.status,
      current_player_index: play.current_player_index,
      final_scores:         play.final_scores,
      winner_names:         play.winner_names,
      action_event_id:      play.action_event_id,
      rolls:                play.game_rolls.live.ordered.map { |r| serialize_roll(r) },
      scores:               play.game_score_entries.live.ordered.map { |s| serialize_score(s) },
    }
  end

  def serialize_roll(r)
    {
      client_uuid:  r.client_uuid,
      player_name:  r.player_name,
      player_index: r.player_index,
      value:        r.value,
      dice:         r.dice,
      faces:        r.faces,
      source:       r.source,
      rolled_at:    r.rolled_at.iso8601(3),
    }
  end

  def serialize_score(s)
    {
      client_uuid: s.client_uuid,
      player_name: s.player_name,
      delta:       s.delta,
      entered_at:  s.entered_at.iso8601(3),
    }
  end
end
