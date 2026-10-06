# A project on the Playground, read from config/playground/projects.yml, with
# its About page content from config/playground/about/<slug>.yml.
#
# `access` is who can open it:
#   public  - anybody, no account involved
#   guest   - anybody; a guest account is made for them on arrival
#   account - a registered account (a guest has to finish signing up)
#   admin   - admins
#   owner   - only whoever passes `gate` on User (`me?` unless the entry says)
class PlaygroundProject
  ACCESS_LEVELS = [:public, :guest, :account, :admin, :owner].freeze
  CONFIG_PATH = Rails.root.join("config/playground/projects.yml")
  ABOUT_DIR = Rails.root.join("config/playground/about")

  attr_reader :slug, :title, :year, :description, :access, :tags, :api, :path, :subdomain, :gate, :match

  def self.all
    @all = nil if Rails.env.development?
    @all ||= YAML.load_file(CONFIG_PATH, permitted_classes: [Symbol]).map { |attrs|
      new(attrs.deep_symbolize_keys)
    }
  end

  def self.listed
    all.reject(&:hidden?)
  end

  def self.find(slug)
    listed.find { |project| project.slug == slug.to_s }
  end

  # The listed project a request belongs to, by subdomain or by path prefix.
  # The longest matching prefix wins, so a sub-page maps to its own project
  # rather than to one whose path happens to be a parent of it.
  def self.for_request(request)
    on_subdomain = listed.find { |project| project.subdomain.present? && project.subdomain.to_s == request.subdomain }
    return on_subdomain if on_subdomain
    return if request.subdomain.present? && request.subdomain != "www"

    candidates = listed.flat_map { |project| project.prefixes.map { |prefix| [prefix, project] } }
    matches = candidates.select { |prefix, _| request.path == prefix || request.path.start_with?("#{prefix}/") }
    matches.max_by { |prefix, _| prefix.length }&.last
  end

  def initialize(attrs)
    @slug = attrs.fetch(:slug).to_s
    @title = attrs.fetch(:title)
    @year = attrs.fetch(:year)
    @access = attrs.fetch(:access).to_sym
    @description = attrs[:description]
    @path = attrs[:path]&.to_sym
    @subdomain = attrs[:subdomain]&.to_sym
    @gate = (attrs[:gate] || :me?).to_sym
    @tags = Array(attrs[:tags]).map(&:to_sym)
    @match = Array(attrs[:match])
    @api = attrs[:api]
    @hidden = !!attrs[:hidden]
    @showcase = !!attrs[:showcase]

    raise ArgumentError, "#{@slug}: unknown access #{@access.inspect}" unless ACCESS_LEVELS.include?(@access)
  end

  def hidden? = @hidden

  # Only shown as an About page; visitors can never open it.
  def showcase? = @showcase

  def to_param = slug

  def entry_path
    return if path.nil?

    Rails.application.routes.url_helpers.public_send(:"#{path}_path")
  end

  def prefixes
    [entry_path, *match].compact.uniq
  end

  def openable? = path.present?

  def open_to?(user)
    return false unless openable?

    case access
    when :public, :guest then true
    when :account then user.present? && !user.guest?
    when :admin then !!user&.admin?
    when :owner then !!user&.public_send(gate)
    end
  end

  def about
    @about ||= (
      file = ABOUT_DIR.join("#{slug}.yml")
      file.exist? ? YAML.load_file(file).deep_symbolize_keys : {}
    )
  end

  def screenshots
    Array(about[:screenshots])
  end
end
