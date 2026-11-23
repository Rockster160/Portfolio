module AppStore
  # Everything the scripts say or do that belongs to one app: its identity, where
  # its project lives, and the words its store listing and App Review start from.
  # Each app under ios/ has one (ios/<app>/app_store.rb), and its bin/ scripts
  # hand it to the flows.
  class Config
    attr_reader(
      :name,
      :bundle_id,
      :sku,
      :dir,
      :project,
      :scheme,
      :xcconfigs,
      :settings_name,
      :new_app_name,
      :group,
      :first_note,
      :site,
      :description,
      :keywords,
      :support_url,
      :privacy_url,
      :update_note,
      :categories,
      :review_notes,
      :third_party_hint,
      :age_rating_steps,
      :app_privacy_steps,
      :audience,
    )

    # dir: the app's folder under ios/. xcconfigs: files that may set
    # DEVELOPMENT_TEAM, relative to dir, read in order with the last one winning.
    def initialize(name:, bundle_id:, dir:, **options)
      @name = name
      @bundle_id = bundle_id
      @dir = dir
      @sku = options.fetch(:sku, "#{name.downcase}-ios")
      @project = options.fetch(:project, "#{name}.xcodeproj")
      @scheme = options.fetch(:scheme, name)
      @xcconfigs = options.fetch(:xcconfigs, [])
      @settings_name = options.fetch(:settings_name, name.downcase)
      @new_app_name = options.fetch(:new_app_name, name)
      @group = options.fetch(:group, "#{name} team")
      @first_note = options.fetch(:first_note)
      @site = options.fetch(:site)
      @description = options.fetch(:description)
      @keywords = options.fetch(:keywords)
      @support_url = options.fetch(:support_url, @site)
      @privacy_url = options.fetch(:privacy_url, "#{@site}/privacy-policy")
      @update_note = options.fetch(:update_note, "Improvements and fixes.")
      @categories = options.fetch(:categories)
      @review_notes = options.fetch(:review_notes)
      @third_party_hint = options.fetch(:third_party_hint, nil)
      @age_rating_steps = options.fetch(:age_rating_steps)
      @app_privacy_steps = options.fetch(:app_privacy_steps)
      @audience = options.fetch(:audience)
    end

    def project_yml = File.join(dir, "project.yml")
  end
end
