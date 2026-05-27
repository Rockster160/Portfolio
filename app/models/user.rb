# == Schema Information
#
# Table name: users
#
#  id               :integer          not null, primary key
#  dark_mode        :boolean
#  email            :string
#  invitation_token :string
#  password_digest  :string
#  phone            :string
#  role             :integer          default("standard")
#  username         :string
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#

# Should have `invited_at` and `invited_by`
# Ensure Username starts with a letter
class User < ApplicationRecord
  attr_accessor :should_require_current_password, :current_password

  has_many :api_keys, dependent: :destroy
  has_many :bowling_leagues, dependent: :destroy
  has_many :climbs, dependent: :destroy
  has_many :folders, dependent: :destroy
  has_many :pages, dependent: :destroy
  has_many :shared_pages, dependent: :destroy
  has_many :accessible_shared_pages, through: :shared_pages, source: :page
  has_many :contacts, dependent: :destroy
  has_many :friends, through: :contacts
  has_many :addresses, dependent: :destroy
  has_many :user_lists, dependent: :destroy
  has_many :recipes, dependent: :destroy
  has_many :recipe_favorites, class_name: "RecipeFavorite", foreign_key: :favorited_by_id
  has_many :favorited_recipes, through: :recipe_favorites, source: :favorited_by
  has_many :recipe_shares, class_name: "RecipeShare", foreign_key: :shared_to_id
  has_many :shared_recipes, through: :recipe_shares, source: :shared_to
  has_many :lists, through: :user_lists
  has_many :agendas, dependent: :destroy
  has_many :agenda_shares, dependent: :destroy
  has_many :shared_agendas, through: :agenda_shares, source: :agenda
  has_many :agenda_notification_settings, dependent: :destroy
  has_many :emails, dependent: :destroy
  has_many :scheduled_triggers, dependent: :destroy
  has_many :prompts, dependent: :destroy
  has_many :action_events
  has_many :user_surveys
  has_many :user_survey_responses
  has_many :push_subs, class_name: "UserPushSubscription", dependent: :destroy
  has_many :user_dashboards, dependent: :destroy
  has_many :meal_builders, dependent: :destroy
  has_many :list_builders, dependent: :destroy
  has_many :boxes, dependent: :destroy
  has_many :task_folders, dependent: :destroy
  has_many :tasks, dependent: :destroy
  has_many :executions, dependent: :destroy
  has_many :shared_tasks, dependent: :destroy
  has_many :accessible_shared_tasks, through: :shared_tasks, source: :task
  has_one :money_bucket
  has_one :avatar, dependent: :destroy
  def avatar = super || build_avatar
  # has_one :user_dashboard, dependent: :destroy
  # def user_dashboard; super() || build_user_dashboard; end
  has_many :caches, class_name: "UserCache"
  has_many :google_accounts, dependent: :destroy

  has_many :access_grants, class_name: "Doorkeeper::AccessGrant", foreign_key: :resource_owner_id, dependent: :delete_all
  has_many :access_tokens, class_name: "Doorkeeper::AccessToken", foreign_key: :resource_owner_id, dependent: :delete_all

  search_terms :username, :email

  has_secure_password validations: false

  after_save :confirm_guest
  after_save :ensure_default_agenda
  validates :phone, uniqueness: { allow_nil: true }
  validate :proper_fields_present?

  scope :by_username, ->(username) { where("LOWER(username) = ?", username.to_s.downcase) }

  enum :role, {
    guest:    5,
    standard: 0,
    admin:    10,
  }

  def self.me
    @@me ||= admin.first
  end

  def me? = id == 1

  # "Perceived today" — the date the user mentally still considers as today,
  # using a 3am rollover instead of midnight. At 1am-2:59am local, this
  # returns yesterday's calendar date. Both the FE (agenda.js#dayKey) and
  # the BE consult this for default-date logic so they always agree.
  def perceived_today
    zone = ActiveSupport::TimeZone[timezone] || Time.zone
    now = zone.now
    date = now.to_date
    date -= 1 if now.hour < 3
    date
  end

  # Owned agendas + agendas shared with this user.
  def accessible_agendas
    Agenda.where(user_id: id).or(Agenda.where(id: shared_agendas.select(:id)))
  end

  # Owned + editable-shared. Used to gate item/schedule mutations.
  def editable_agendas
    Agenda.where(user_id: id).or(
      Agenda.where(id: agenda_shares.editor.select(:agenda_id)),
    )
  end

  def accessible_agenda_items
    AgendaItem.where(agenda_id: accessible_agendas.select(:id))
  end

  def editable_agenda_items
    AgendaItem.where(agenda_id: editable_agendas.select(:id))
  end

  # Aggregate items (real + phantoms) across every accessible agenda.
  # Three SQL queries: agendas (with users eager-loaded), items, schedules.
  # The agendas query feeds preloaded_agendas so phantom-building's
  # `agenda.user` doesn't fire per-schedule lookups.
  def agenda_items_for_range(from, to)
    agendas = accessible_agendas.includes(:user).to_a
    Agenda.items_for_range_in(
      agendas.map(&:id),
      from, to,
      reference_user: self,
      preloaded_agendas: agendas,
    )
  end

  def agenda_items_for(date)
    agenda_items_for_range(date, date)
  end

  def agenda_visible_items_for(date)
    agenda_items_for(date).select { |item| item.visible_on?(date) }
  end

  def agenda_carry_over_items
    # Cutoff = perceived-today's local midnight. Tasks scheduled for what
    # the user still considers "today" (i.e. yesterday's calendar date at
    # 1am-2:59am) stay in their day section, NOT carry-over.
    # Tasks completed today stay in the section as crossed-out — matches
    # how today-scheduled items behave when checked off.
    zone = ActiveSupport::TimeZone[timezone] || Time.zone
    today_start = zone.local(perceived_today.year, perceived_today.month, perceived_today.day)
    accessible_agenda_items
      .where(kind: :task)
      .where(start_at: ...today_start)
      .where("completed_at IS NULL OR completed_at >= ?", today_start)
      .order(:start_at)
  end

  def self.auth_from_basic(basic_auth)
    username, password = basic_auth.split(":", 2)
    attempt_login(username, password)
  end

  def self.attempt_login(username, password)
    user = by_username(username).first

    return unless user.present? && user.authenticate(password)

    user
  rescue PG::CharacterNotInRepertoire, ArgumentError
    nil # Bad username passed
  end

  def self.find_or_create_by_filtered_params(raw_params)
    return User.new if raw_params.blank?

    user_scope = User.all
    user_scope = user_scope.where("lower(username) = ?", raw_params[:username].to_s.downcase.squish) if raw_params[:username].present?
    user_scope = user_scope.where(phone: raw_params[:phone].gsub(/[^0-9]/, "").last(10)) if raw_params[:phone].present?
    user_scope = user_scope.where(raw_params.except(:username, :phone))
    user_scope.first || User.new(raw_params)
  end

  def self.id(user_or_id)
    user_or_id.is_a?(::User) ? user_or_id.id : user_or_id.to_i
  end

  def self.ids(user_or_ids)
    case user_or_ids
    when ::User then [user_or_ids.id]
    when ::ActiveRecord::Relation then user_or_ids.ids
    else ::Array.wrap(user_or_ids)
    end
  end

  def account_has_data?
    self.class.reflections.values.find { |reflection|
      next unless reflection.is_a?(ActiveRecord::Reflection::HasManyReflection)

      send(reflection.name).any?
    }.present?
  end

  def merge_account(guest_account)
    self.class.reflections.each_value { |reflection|
      next unless reflection.is_a?(ActiveRecord::Reflection::HasManyReflection)

      fk = reflection.options[:foreign_key] || :user_id
      guest_account.send(reflection.name).update_all(fk => id)
    }

    guest_account.destroy
  end

  def self.timezone(&block)
    return "America/Denver" unless block_given?

    Time.use_zone(timezone) {
      block.call
    }
  end

  def timezone(&block)
    return "America/Denver" unless block_given?

    Time.use_zone(timezone) {
      block.call
    }
  end

  def parse_time(time_str, format=nil)
    timezone {
      if format.nil?
        Time.zone.parse(time_str)
      else
        Time.strptime(time_str, format)
      end
    }
    # parse_time("02/06/25 4:52pm", "%m/%d/%y %I:%M%p")
  end

  def me?
    id == 1 && admin?
  end

  def see!
    # last logged in at NOW
  end

  def address_book
    @address_book ||= AddressBook.new(self)
  end

  def update_with_password(new_attrs)
    should_require_current_password = !guest?
    update(new_attrs)
  end

  def update_avatar(character)
    avatar.update_by_builder(character)
  end

  def owns_list?(list)
    !!user_lists.where(list_id: list.try(:id)).try(:is_owner)
  end

  def assign_invitation_token
    self.invitation_token ||= loop do
      lower_alpha = ("a".."z").to_a
      upper_alpha = ("A".."Z").to_a
      numeric = (0..9).to_a
      alpha_num = (lower_alpha + upper_alpha + numeric)
      token = "#{alpha_num.sample(3).join}-#{alpha_num.sample(3).join}"
      break token unless self.class.where(invitation_token: token).any?
    end
  end

  def display_name
    username.presence || phone.gsub(/[^\d]/, "").presence || "<User:#{id}>"
  end

  def default_list
    (user_lists.find_by(default: true) || user_lists.first).try(:list)
  end

  def accessible_tasks
    Task.select("DISTINCT tasks.*").joins(
      <<-SQL.squish,
        LEFT JOIN shared_tasks ON shared_tasks.task_id = tasks.id AND shared_tasks.user_id = #{id}
      SQL
    ).where("tasks.user_id = :id OR shared_tasks.user_id = :id", id: id)
  end

  def primary_push_sub(channel: :jarvis)
    push_subs.for_channel(channel).where.not(registered_at: nil).order(registered_at: :desc).first
  end

  def all_push_subs_for_channel(channel)
    push_subs.for_channel(channel).where.not(registered_at: nil)
  end

  def ordered_lists
    lists.includes(:user_lists).where(user_lists: { user_id: id }).order("user_lists.sort_order")
  end

  def list_by_name(name)
    List.by_name_for_user(name, self)
  end

  def invite!(list)
    user_lists.create(list_id: list.id)
    return unless Rails.env.production?
    return if phone.blank?

    message = "You've been added to the list: \"#{list.name.titleize}\". Click the link below to join:\n"
    if invited?
      message += Rails.application.routes.url_helpers.register_url(invitation_token: invitation_token)
    else
      message += Rails.application.routes.url_helpers.list_url(list.name.parameterize)
    end
    # Is the other user required to opt-in first?
    SmsWorker.perform_async(phone, message)
  end

  def invited?
    invitation_token.present?
  end

  def confirmed?
    persisted? && !guest?
  end

  # Every real (non-guest) user gets a starter agenda named after their
  # username. Saves the user from staring at an empty "Create your first one."
  # screen on signup, and gives shared/aggregated views something to render
  # immediately. Guests skip this (they're temporary). Existing users with no
  # agendas get one the next time they save (cheap idempotent backfill).
  #
  # Public so the AgendasController can call it as a before_action — visiting
  # /agenda should never make the user click through an empty state.
  def ensure_default_agenda
    return if guest?
    return if username.blank?
    return if agendas.exists?

    agendas.create(name: username)
  end

  private

  def confirm_guest
    return unless guest?

    update(role: :standard) if username.present?
  end

  def proper_fields_present?
    return false if guest?

    if invited?
      errors.add(:base, "User must have a Username or Phone Number") if phone.blank? && username.blank?
    else
      if new_record?
        password_length = @password.try(:length).to_i
        errors.add(:password, "must be at least 8 and no more than 32 characters.") if password_length < 8 || password_length > 32
      end
      valid_presence?(:password_digest, :password)
      valid_presence?(:username)
      confirmation_matches_password
      username_constraints
      format_phone
      correct_current_password
    end
  end

  def valid_presence?(sym, error_sym=nil)
    error_sym ||= sym
    errors.add(error_sym, "must be present.") if send(sym).blank?
  end

  def format_phone
    return if phone.blank?

    stripped_phone = phone.gsub(/[^0-9]/, "").last(10)

    if stripped_phone.length == 10
      self.phone = stripped_phone
    elsif stripped_phone.present?
      errors.add(:phone, "must be a valid, 10 digit number.")
    else
      self.phone = nil
    end
  end

  def correct_current_password
    return unless should_require_current_password

    errors.add(:current_password, "wasn't right.") unless authenticate(current_password)
  end

  def confirmation_matches_password
    errors.add(:password, "must match confirmation.") unless @password == @password_confirmation
  end

  def username_constraints
    self.username = username.to_s.squish

    if User.by_username(username).where.not(id: id).any?
      errors.add(:base, "Sorry! That username has already been taken.")
      return
    end
    errors.add(:username, "must be between 3 and 20 characters in length.") if username.length < 3 || username.length > 20
    errors.add(:username, "can only contain alphanumeric characters.") unless (username =~ /[^a-zA-Z0-9_-]/).nil?
  end
end
