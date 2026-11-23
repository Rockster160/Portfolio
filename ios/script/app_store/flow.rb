require "fileutils"
require "json"
require_relative "config"
require_relative "connect"
require_relative "wizard"

module AppStore
  # Runs a script's flow for an app, ending quietly on Ctrl-C and plainly on a failure.
  def self.main(flow, config)
    flow.new(config).run
  rescue Interrupt
    puts
    puts("   Stopped. Run it again to carry on: it picks up what is already done.")
    exit(130)
  rescue Error => e
    puts
    e.message.each_line { |line| puts("   #{Wizard.yellow("!")} #{line.chomp}") }
    exit(1)
  end

  # What both scripts share: the API key, the app's record and the project's
  # own settings. What only this Mac knows (which key, the last build number it
  # uploaded, the one-time steps already done) is kept in settings_path, outside
  # the repository, one file per app.
  class Flow
    include Wizard

    # Where Apple's tools look for API keys, by name (AuthKey_<KEY ID>.p8).
    KEYS = File.expand_path("~/.appstoreconnect/private_keys")
    SETTINGS_DIR = File.expand_path("~/.appstoreconnect")
    CONNECT = "https://appstoreconnect.apple.com".freeze
    API_KEYS = "#{CONNECT}/access/integrations/api".freeze
    MEMBERSHIP = "https://developer.apple.com/account#MembershipDetailsCard".freeze
    DOWNLOADS = File.expand_path("~/Downloads")
    JUST_DOWNLOADED = 30 * 60

    attr_reader :config

    def initialize(config)
      @config = config
    end

    def settings_path = File.join(SETTINGS_DIR, "#{config.settings_name}.json")

    def settings
      return @settings if @settings

      @settings = File.exist?(settings_path) ? read_settings(settings_path) : {}
    end

    def read_settings(path) = JSON.parse(File.read(path), symbolize_names: true)

    def save(changes)
      settings.merge!(changes)
      FileUtils.mkdir_p(File.dirname(settings_path))
      File.write(settings_path, JSON.pretty_generate(settings))
      File.chmod(0o600, settings_path)
    end

    def key_path = File.join(KEYS, "AuthKey_#{settings[:key_id]}.p8")

    def connect
      @connect ||= (
        set_up_key unless key_ready?
        Connect.new(key_id: settings[:key_id], issuer_id: settings[:issuer_id], key_path: key_path)
      )
    end

    # The app's record, waiting on it being made when it isn't there yet.
    def app
      @app ||= loop do
        found = find_app
        break found if found

        warn("App Store Connect has no app for #{config.bundle_id} yet")
        pause(
          [
            "Click the + beside Apps (top left), then New App.",
            <<~TEXT.chomp,
              Platforms: iOS. Name: #{config.new_app_name} (one not already on the store; the
              phone still shows #{config.name}). Primary Language: English (U.S.).
              Bundle ID: #{config.bundle_id} (not one of its .extension ids).
              SKU: #{config.sku}. User Access: Full Access.
            TEXT
            "Click Create.",
          ],
          page: website("Apps"),
        )
      end
    end

    def app_link(path) = "#{CONNECT}/apps/#{app[:id]}/#{path}"

    # [what the page is, its url] for a pause: a page of the app's, or the list of apps.
    def website(name, path=nil)
      ["App Store Connect, #{name}", path ? app_link(path) : "#{CONNECT}/apps"]
    end

    def marketing_version = project_setting(:MARKETING_VERSION)

    def marketing_version=(version)
      text = File.read(config.project_yml)
      replaced = text.sub(/^(\s*MARKETING_VERSION: )"[^"]*"/, "\\1\"#{version}\"")
      File.write(config.project_yml, replaced)
    end

    # The team that signs, from the app's xcconfigs (a gitignored Local one wins)
    # or project.yml; asked for once and written to the first xcconfig when blank.
    def team
      @team ||= xcconfig_team || project_team || ask_for_team
    end

    # The subjects of the commits that changed the app since the one noted under key
    # (note_changes), as a starting note; nil when none is noted or nothing changed.
    def changes_since(key)
      return unless settings[key]

      subjects = git("log", "--format=%s", "#{settings[key]}..HEAD", "--", config.dir)
      subjects.lines.map(&:strip).reject(&:empty?).join("; ").then { |line| line unless line.empty? }
    end

    def note_changes(key) = save(key => git("rev-parse", "HEAD"))

    # A path as Terminal types it when a file is dragged in: quoted, or with escaped spaces.
    def dragged(path) = path.delete_prefix("'").delete_suffix("'").gsub("\\ ", " ")

    def git(*args)
      output = IO.popen(["git", "-C", config.dir, *args], err: File::NULL, &:read)
      output.strip
    end

    private

    def key_ready? = settings[:key_id] && settings[:issuer_id] && File.exist?(key_path)

    def find_app
      params = { "filter[bundleId]": config.bundle_id }
      connect.list("/v1/apps", params).find { |found|
        found.dig(:attributes, :bundleId) == config.bundle_id
      }
    rescue Connect::Refused => e
      raise unless e.status == 401

      warn("App Store Connect turned down the API key.")
      save(key_id: nil, issuer_id: nil)
      set_up_key(reuse: false)
      @connect = nil
      retry
    end

    def project_setting(name)
      File.read(config.project_yml)[/^\s*#{name}: "?([^"\n]*)"?$/, 1]
    end

    def xcconfig_team = config.xcconfigs.reverse.filter_map { |file| team_in(file) }.first
    def project_team = project_setting(:DEVELOPMENT_TEAM).to_s.then { |id| id unless id.empty? }

    def team_in(file)
      path = File.join(config.dir, file)
      return unless File.exist?(path)

      File.read(path)[/^\s*DEVELOPMENT_TEAM\s*=\s*(\w+)\s*$/, 1]
    end

    def ask_for_team
      step("Developer team (once)")
      say("The Team ID is on the Membership details card, ten letters and digits.")
      open_page(MEMBERSHIP)
      id = loop do
        answer = ask("Team ID").upcase
        break answer if answer.match?(/\A[A-Z0-9]{10}\z/)

        warn("A Team ID looks like 9FB25883J5")
      end
      file = config.xcconfigs.first
      if file
        path = File.join(config.dir, file)
        File.write(path, File.read(path).sub(/^(\s*DEVELOPMENT_TEAM\s*=).*$/, "\\1 #{id}"))
        warn("#{file} now says #{id}; ship that change so every Mac signs the same way")
      end
      id
    end

    # A team key works for every app on the team, so one set up for another app
    # here is offered before making a new one.
    def set_up_key(reuse: true)
      shared = reuse && shared_key
      if shared && yes?("Use the App Store Connect key already set up for #{shared[:app]}?")
        save(key_id: shared[:key_id], issuer_id: shared[:issuer_id])
        return done("Using key #{shared[:key_id]}")
      end

      step("App Store Connect API key (once on this Mac)")
      say("The scripts sign in to Apple with a key made once on the App Store Connect website.")
      pause(
        [
          "Sign in with the developer team's Apple Account (the one in Xcode, Settings, Accounts).",
          <<~TEXT.chomp,
            The page is Users and Access, Integrations, App Store Connect API. If it shows
            Request Access, click it and accept the terms (only the Account Holder can; it is
            granted right away).
          TEXT
          <<~TEXT.chomp,
            On the Team Keys tab, click + (or Generate API Key). Name: App Store builds.
            Access: Admin (Xcode needs it to make the distribution certificate). Generate.
          TEXT
          <<~TEXT.chomp,
            On the new key's row, click Download. Apple allows one download; it lands in
            Downloads as AuthKey_<Key ID>.p8.
          TEXT
          "Keep the page open: the Issuer ID above the list is asked for next.",
        ],
        page: ["App Store Connect, API keys", API_KEYS],
      )
      found = newest_key
      hint = found ? "Enter for this one, or drag another here" : "drag it here"
      file = dragged(ask("The downloaded key (#{hint})", default: found))
      raise Error, "No file at #{file}" unless File.exist?(file)

      key_id = File.basename(file)[/\AAuthKey_(\w+)\.p8\z/, 1] || ask("Key ID (on the key's row)")
      issuer_id = issuer
      FileUtils.mkdir_p(KEYS)
      destination = File.join(KEYS, "AuthKey_#{key_id}.p8")
      FileUtils.cp(file, destination) unless File.expand_path(file) == destination
      File.chmod(0o600, destination)
      save(key_id: key_id, issuer_id: issuer_id)
      done("Key #{key_id} saved in #{KEYS}")
    end

    # Another app's settings on this Mac whose key is still in place.
    def shared_key
      Dir.glob(File.join(SETTINGS_DIR, "*.json")).each do |path|
        next if File.expand_path(path) == File.expand_path(settings_path)

        other = read_settings(path)
        next unless other[:key_id] && other[:issuer_id]
        next unless File.exist?(File.join(KEYS, "AuthKey_#{other[:key_id]}.p8"))

        return other.slice(:key_id, :issuer_id).merge(app: File.basename(path, ".json"))
      rescue JSON::ParserError
        next
      end
      nil
    end

    # One downloaded just now: the push alert key is an AuthKey_*.p8 too, and older.
    def newest_key
      keys = Dir.glob(File.join(DOWNLOADS, "AuthKey_*.p8")).select { |file|
        File.mtime(file) > Time.now - JUST_DOWNLOADED
      }
      keys.max_by { |file| File.mtime(file) }
    end

    def issuer
      loop do
        answer = ask("Issuer ID (above the list of keys, with a Copy button beside it)")
        return answer if answer.match?(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/)

        warn("An Issuer ID looks like 69a6de70-03db-47e3-e053-5b8c7c11a4d1")
      end
    end
  end
end
