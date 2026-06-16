# Interactive console wizard for Tesla Fleet API setup.
# Run from a LOCAL console — hosted IPs are filtered by auth.tesla.com.
#
#   TeslaSetup.run        # interactive menu
#   TeslaSetup.status     # cached completion overview (no network)
#
# Direct calls (advanced):
#   TeslaSetup.partner_token        # cached 1h in DataStorage
#   TeslaSetup.register_partner
#   TeslaSetup.verify_public_key
#   TeslaSetup.paired?              # uses partner token, bypasses proxy
class TeslaSetup
  AUDIENCE              = "https://fleet-api.prd.na.vn.cloud.tesla.com".freeze
  FLEET_API_URL         = "https://fleet-api.prd.na.vn.cloud.tesla.com/api/1/".freeze
  PARTNER_TOKEN_URL     = "https://auth.tesla.com/oauth2/v3/token".freeze
  DOMAIN                = "ardesian.com".freeze
  PUBLIC_KEY_URL        = "https://ardesian.com/.well-known/appspecific/com.tesla.3p.public-key.pem".freeze
  VEHICLE_CMD_REPO      = "~/code/vehicle-command".freeze
  PRIVATE_KEY_PATH      = "~/code/Portfolio/_scripts/tesla_keys/private_key.pem".freeze
  PUBLIC_KEY_PATH       = "~/code/Portfolio/public/.well-known/appspecific/com.tesla.3p.public-key.pem".freeze
  PARTNER_TOKEN_TTL     = 1.hour
  PARTNER_TOKEN_DS_KEY  = :tesla_partner_token
  PARTNER_TOKEN_EXP_KEY = :tesla_partner_token_expires_at

  STEPS = [
    { key: :"1", label: "Verify dev portal + served PEM",       run: :do_check_portal      },
    { key: :"2", label: "Register partner_account",             run: :do_register_partner  },
    { key: :"3", label: "Verify Tesla-stored public_key",       run: :do_verify_public_key },
    { key: :"4", label: "Pair vehicle key (BLE)",               run: :do_pair_vehicle      },
    { key: :"5", label: "Third-party auth (access_token)",      run: :do_third_party_auth  },
    { key: :"6", label: "Register Fleet Telemetry",             run: :do_request_telemetry },
    { key: :"7", label: "Verify commands (start/temp/navigate)", run: :do_command_tester   },
    { key: :"8", label: "Verify telemetry flow",                run: :do_check_telemetry  },
  ].freeze

  # Step 7's command tests all call TeslaControl methods directly — the
  # exact same code path prod uses. We do not build a parallel command
  # pipeline; if it works here, it works in prod.
  COMMAND_TESTS = [
    { key: :a, label: "TeslaControl.me.wake_up",    fn: -> { ::TeslaControl.me.wake_up }, effect: "Wakes the car if asleep." },
    { key: :b, label: "TeslaControl.me.start_car",  fn: -> { ::TeslaControl.me.start_car }, effect: "Climate / pre-conditioning on." },
    { key: :c, label: "TeslaControl.me.set_temp F", fn: :set_temp, effect: "Sets driver+passenger to °F." },
    { key: :d, label: "TeslaControl.me.navigate",   fn: :navigate, effect: "Pushes a destination to the car. No driving." },
    { key: :e, label: "TeslaControl.me.honk",       fn: -> { ::TeslaControl.me.honk }, effect: "HONKS. Loud." },
  ].freeze

  class << self
    # ── Public entrypoints ────────────────────────────────────────────────
    def run
      with_quiet_db do
        banner("Tesla Fleet API Setup")
        if Rails.env.production?
          say red("This wizard is designed for LOCAL use only.")
          say red("Production IPs are blocked by auth.tesla.com.")
          say red("Run from a dev console; tokens will be synced to prod via Step 5.")
          return
        end
        say "✓ = step previously completed (cached locally, no network calls made)"
        say "Pick a number to run a step. #{cyan('m')} = re-show menu, #{cyan('q')} = quit."
        say "Other helpers: #{cyan('TeslaSetup.proxies')} (startup), #{cyan('TeslaSetup.reset!')} (clear local state)"
        render_menu
        loop do
          choice = ask("Choose").to_s.strip.downcase.to_sym
          break if [:q, :quit, :exit, :""].include?(choice)
          if [:m, :menu, :"?", :s, :status].include?(choice)
            render_menu
            next
          end

          step = STEPS.find { |s| s[:key] == choice }
          if step.nil?
            say red("  ✗ unknown option: #{choice} — #{cyan('m')} for menu, #{cyan('q')} to quit")
            next
          end
          send(step[:run])
          after_step(step)
        end
      end
    end

    def status
      with_quiet_db { render_menu }
    end

    # Generates a one-off prodExec script that copies the currently-cached
    # dev tokens into prod's user cache. Same as the post-Step-5 prompt,
    # but callable anytime: `TeslaSetup.write_token_sync!`.
    def write_token_sync!
      with_quiet_db { write_prod_token_sync_script }
    end

    # Wipes every piece of local state this wizard owns so the next run starts
    # from scratch. Asks for explicit confirmation. Does NOT touch Tesla's
    # side (partner registration, paired key, OAuth grants stay as-is — those
    # are properties on Tesla's servers; re-running the wizard is idempotent).
    def reset!
      with_quiet_db do
        banner("Reset TeslaSetup state")
        say "This will clear:"
        say "  • Partner client_credentials token cache (DataStorage)"
        say "  • Per-step completion timestamps (DataStorage)"
        say "  • #{red('User OAuth tokens')} in #{red(Rails.env)} DB (cache[:oauth][:tesla_api])"
        say
        say "Does NOT touch: Tesla partner-account, paired vehicle key,"
        say "                or prod-side tokens (if synced)."
        say
        confirm = ask("Type #{green('reset')} to confirm").to_s.strip.downcase
        return say(yellow("  Cancelled.")) unless confirm == "reset"

        DataStorage.where(name: PARTNER_TOKEN_DS_KEY.to_s).delete_all
        DataStorage.where(name: PARTNER_TOKEN_EXP_KEY.to_s).delete_all
        STEPS.each { |s|
          DataStorage.where(name: completion_key(s[:key]).to_s).delete_all
        }

        cache = User.me.caches.find_by(key: :oauth)
        if cache && cache.data.is_a?(Hash) && cache.data["tesla_api"].present?
          cache.data["tesla_api"] = (cache.data["tesla_api"] || {}).except(
            "access_token", "refresh_token", "id_token",
          )
          cache.save!
        end

        @api = nil
        @partner_token = nil

        say green("  ✓ Reset complete. Run TeslaSetup.run to start over.")
      end
    end

    # Prints both proxy startup commands together. The Go signer + Ruby relay
    # together form the "double proxy" — Go signs commands, Ruby is the
    # publicly-reachable bridge that prod calls to refresh tokens / send
    # commands without having to reach localhost:8752 directly.
    def proxies
      banner("Double-proxy startup")
      say "Two processes, each in its own terminal. Leave both running."
      say
      say "#{cyan('TCP check')}: go=#{proxy_running? ? green('up') : red('down')}  ruby=#{ruby_relay_running? ? green('up') : red('down')}"
      say
      section("1. Go signing proxy (localhost:8752, HTTPS self-signed)")
      say "cd #{VEHICLE_CMD_REPO}"
      say "go run ./cmd/tesla-http-proxy/main.go \\"
      say "  -tls-key  ~/code/Portfolio/_scripts/tesla_keys/tls.pem \\"
      say "  -cert     ~/code/Portfolio/_scripts/tesla_keys/cert.pem \\"
      say "  -key-file #{PRIVATE_KEY_PATH} \\"
      say "  -port 8752 -verbose"
      end_section
      section("2. Ruby relay (0.0.0.0:3142, plain HTTP)")
      say "ruby #{Rails.root}/proxy/listener.rb"
      end_section
    end

    # ── Operations (callable directly OR via menu) ────────────────────────
    def api
      @api ||= Oauth::TeslaApi.new(User.me)
    end

    def partner_token(force: false)
      if !force && (cached = DataStorage[PARTNER_TOKEN_DS_KEY]).present?
        exp = DataStorage[PARTNER_TOKEN_EXP_KEY].to_i
        return cached if exp > Time.current.to_i
      end

      json = Api.post(PARTNER_TOKEN_URL, {
        grant_type:    :client_credentials,
        client_id:     api.client_id,
        client_secret: api.client_secret,
        scope:         api.scopes,
        audience:      AUDIENCE,
      }, { user_agent: "Jarvis-1.0" })

      raise "No access_token in partner response: #{json.inspect}" if json[:access_token].blank?

      DataStorage[PARTNER_TOKEN_DS_KEY]  = json[:access_token]
      DataStorage[PARTNER_TOKEN_EXP_KEY] = (Time.current + PARTNER_TOKEN_TTL).to_i
      json[:access_token]
    end

    def register_partner
      api.post(:partner_accounts, { domain: DOMAIN }, partner_auth_headers)
    end

    def verify_public_key
      res = api.get("partner_accounts/public_key?domain=#{DOMAIN}", {}, partner_auth_headers)
      tesla_key  = res.dig(:response, :public_key).to_s.downcase
      served_key = served_public_key_hex.to_s.downcase
      { match: tesla_key.present? && tesla_key == served_key, tesla: tesla_key, served: served_key }
    end

    def served_public_key_hex
      pem = RestClient.get(PUBLIC_KEY_URL).body
      OpenSSL::PKey::EC.new(pem).public_key.to_bn.to_s(16)
    end

    # Uses partner client_credentials token, bypasses the Rails proxy entirely.
    def paired?
      res = Api.request(
        method:  :post,
        url:     "#{FLEET_API_URL}vehicles/fleet_status",
        payload: { vins: [Tesla.vin] },
        headers: partner_auth_headers.merge(content_type: "application/json", user_agent: "Jarvis-1.0"),
      )
      vins = res.dig(:response, :key_paired_vins) || []
      vins.include?(Tesla.vin)
    end

    # Calls GET /vehicles with the USER token. This is what creates the
    # partner ↔ VIN linkage on Tesla's side; until it runs, partner-level
    # fleet_status returns 404 not_found.
    def register_vehicles
      raise "No user access_token — run Step 5 first" if api.access_token.blank?

      res = api.get(:vehicles)
      vins = (res.dig(:response) || []).map { |v| v[:vin] }
      vins
    end

    # ── Persistent completion tracking ────────────────────────────────────
    private

    def completion_key(step_key)
      :"tesla_setup_step_#{step_key}_at"
    end

    def mark_completed(step_key)
      DataStorage[completion_key(step_key)] = Time.current.to_i
    end

    def completed_at(step_key)
      ts = DataStorage[completion_key(step_key)]
      ts.present? ? Time.at(ts.to_i) : nil
    end

    # After each step finishes: hint at the next step, then re-render the menu
    # so the user can see updated ✓ marks and pick what to do next without
    # having to remember the menu commands.
    def after_step(step)
      idx = STEPS.find_index { |s| s[:key] == step[:key] }
      done = step_completed?(step[:key])
      following = STEPS[(idx + 1)..]&.find { |s| !step_completed?(s[:key]) } if done
      following ||= STEPS[idx + 1] if done
      say
      if done && following
        say cyan("→ Next: pick #{cyan(following[:key])} (#{following[:label]})")
      elsif done
        say green("✓ All steps complete!")
      else
        say yellow("→ Step did not complete. Re-run #{step[:key]} or pick another option.")
      end
      render_menu
    end

    def step_completed?(key)
      completed_at(key).present?
    end

    # ── Menu rendering (no network) ───────────────────────────────────────
    def render_menu
      say
      say cyan("─" * 72)
      STEPS.each { |s|
        ts = completed_at(s[:key])
        mark = ts ? green("✓") : "·"
        when_str = ts ? dim("(#{ts.strftime('%Y-%m-%d %H:%M')})") : ""
        say "  #{mark}  #{cyan(s[:key].to_s.rjust(2))}.  #{s[:label]}  #{when_str}"
      }
      say "         #{cyan(' m')}.  Re-show this menu"
      say "         #{cyan(' q')}.  Quit"
      say cyan("─" * 72)
    end

    # ── Menu actions ──────────────────────────────────────────────────────
    def do_check_portal
      banner("Dev portal checklist")
      say "Confirm at #{cyan('https://developer.tesla.com')} (Ardesian app):"
      say "    Allowed Origin:        #{green("https://#{DOMAIN}")}"
      say "    Allowed Redirect URI:  #{green("https://#{DOMAIN}/webhooks/auth")}"
      say "    Fleet API scopes:      Vehicle Information, Vehicle Location,"
      say "                           Vehicle Commands, Vehicle Charging Management"
      say
      ok = check("Public key URL serving 200 + EC PEM") { served_public_key_hex.present? }
      mark_completed(:"1") if ok
    end

    def do_register_partner
      banner("Register partner_account")
      res = register_partner
      acct = res[:response] || {}
      say "  account_id:  #{green(acct[:account_id])}"
      say "  domain:      #{green(acct[:domain])}"
      say "  created:     #{acct[:created_at]}"
      say "  updated:     #{acct[:updated_at]}"
      say green("  ✓ Partner account registered")
      mark_completed(:"2")
    end

    def do_verify_public_key
      banner("Verify Tesla-stored public_key")
      r = verify_public_key
      if r[:match]
        say green("  ✓ Tesla's stored key matches #{PUBLIC_KEY_URL}")
        mark_completed(:"3")
      else
        say red("  ✗ Mismatch!")
        say "    Tesla:  #{r[:tesla][0, 32]}…#{r[:tesla][-8..]}"
        say "    Served: #{r[:served][0, 32]}…#{r[:served][-8..]}"
        say yellow("  Fix: re-upload PEM at the URL, or re-register the partner.")
      end
    end

    def do_pair_vehicle
      banner("Pair vehicle key (BLE)")
      say "Pre-flight checklist:"
      say "  • Laptop within ~3 ft of the car"
      say "  • Laptop Bluetooth ON, phone Bluetooth OFF"
      say "  • Car awake — open driver door if unsure"
      say "  • Terminal has macOS Bluetooth permission + has been quit/reopened"
      say
      section("PASTE INTO TERMINAL (next to the car)")
      say "cd #{VEHICLE_CMD_REPO}"
      say "go run ./cmd/tesla-control -ble \\"
      say "  -vin #{Tesla.vin} \\"
      say "  -key-file #{PRIVATE_KEY_PATH} \\"
      say "  add-key-request #{PUBLIC_KEY_PATH} owner cloud_key"
      end_section
      say "On success the tool prints: #{green('Sent add-key request…')}"
      say "Then approve the request in the #{cyan('Tesla phone app')}."
      ask("Press Enter once approved")

      ok = check("Vehicle in key_paired_vins (via partner token)") { paired? }
      if !ok && api.access_token.present?
        say yellow("  fleet_status 404 → trying GET /vehicles to activate partner ↔ VIN linkage…")
        begin
          vins = register_vehicles
          say "  vehicles visible to partner: #{vins.inspect}"
          ok = check("Vehicle in key_paired_vins (after linkage)") { paired? }
        rescue StandardError => e
          say red("  ✗ GET /vehicles failed: #{e.class}: #{e.message}")
        end
      end

      # fleet_status is an unreliable reporting endpoint. The canonical proof
      # of pairing is whether a signed command via the Go proxy works.
      unless ok
        say
        say yellow("  fleet_status remains 404 — but that endpoint is known to lag/misreport.")
        say "  Definitive verification: send a real signed command through the Go proxy."
        say "  In a separate terminal:"
        section("RUN THE GO PROXY (separate terminal)")
        say "cd #{VEHICLE_CMD_REPO}"
        say "go run ./cmd/tesla-http-proxy/main.go \\"
        say "  -tls-key  ~/code/Portfolio/_scripts/tesla_keys/tls.pem \\"
        say "  -cert     ~/code/Portfolio/_scripts/tesla_keys/cert.pem \\"
        say "  -key-file #{PRIVATE_KEY_PATH} \\"
        say "  -port 8752 -verbose"
        end_section
        confirm = ask("Proxy running? Run flash_lights smoke test now? [y/N]").to_s.strip.downcase
        if confirm == "y"
          ok = check("flash_lights via local Go proxy") { smoke_test_flash_lights }
        end
      end

      mark_completed(:"4") if ok
      return if ok

      say
      if api.access_token.blank?
        say yellow("  No user access_token yet — complete Step 5 (OAuth), then re-run Step 4.")
      else
        say yellow("  Possible causes:")
        say yellow("    • Pairing not finalized — re-run Go command and tap your NFC keycard")
        say yellow("    • Go proxy not actually running on localhost:8752")
        say yellow("    • Car asleep — open driver door and retry")
      end
    end

    # ── Step 7: Command verification ──────────────────────────────────────
    # Every command here calls a TeslaControl method directly. Same code path
    # prod uses (TeslaControl → proxy_post → Ruby relay → Go proxy → Fleet API).
    # The wizard does not synthesize commands.
    def do_command_tester
      banner("Verify commands (via TeslaControl — same path prod uses)")
      preflight_summary
      say

      say cyan("─" * 72)
      COMMAND_TESTS.each { |t|
        say "  #{cyan(t[:key])}.  #{t[:label]}  #{dim('— ' + t[:effect])}"
      }
      say "  #{cyan('z')}.  Back to main menu"
      say cyan("─" * 72)

      loop do
        choice = ask("Command").to_s.strip.downcase.to_sym
        return if choice == :z || choice == :"" || choice == :q
        t = COMMAND_TESTS.find { |x| x[:key] == choice }
        if t.nil?
          say red("  ✗ unknown — type one of: #{COMMAND_TESTS.map { |x| x[:key] }.join(', ')}, or z")
          next
        end
        run_tesla_control_test(t)
      end
    end

    # Shows the state of the moving parts. No assertions; just info.
    def preflight_summary
      say "  Go proxy (localhost:8752):     #{proxy_running? ? green('reachable') : red('unreachable')}"
      say "  Ruby relay (localhost:3142):   #{ruby_relay_running? ? green('reachable') : red('unreachable')}"
      say "  DataStorage[:local_ip]:        #{cyan(DataStorage[:local_ip].to_s.presence || red('unset'))}"
      say "  TeslaControl will POST to:     https://#{DataStorage[:local_ip]}:3142/api/1/…"
      say "  user access_token cached:      #{api.access_token.present? ? green('yes') : red('no')}"
    end

    def run_tesla_control_test(test)
      label, value = case test[:fn]
                     when :set_temp
                       v = Float(ask("Target temp °F").to_s.strip) rescue nil
                       v.nil? ? (return say(red("  ✗ Invalid temperature"))) : ["#{v}°F", v]
                     when :navigate
                       addr = ask("Destination address").to_s.strip
                       addr.empty? ? (return say(red("  ✗ Empty address"))) : [addr.truncate(40), addr]
                     else
                       [nil, nil]
                     end

      say
      say yellow("About to call: #{green(test[:label])}#{label ? " (#{label})" : ''}")
      say "Effect:        #{test[:effect]}"
      confirm = ask("Send? [y/N]").to_s.strip.downcase
      return say(yellow("  Cancelled.")) unless confirm == "y"

      res = with_live_requests do
        if test[:fn].is_a?(Proc)
          test[:fn].call
        else
          ::TeslaControl.me.public_send(test[:fn], value)
        end
      end
      say "  result: #{res.inspect}"
    rescue StandardError => e
      say red("  ✗ #{e.class}: #{e.message}")
    end

    # Flips TeslaControl out of dev-no-op mode for the duration of the block.
    # Without this, every TeslaControl call from a dev console hits the
    # perform_requests? early-return and never reaches the proxy chain.
    def with_live_requests
      ::TeslaControl.force_live_dev = true
      yield
    ensure
      ::TeslaControl.force_live_dev = false
    end

    # TCP check — no auth/TLS dance, just confirms the proxy is accepting connections.
    def proxy_running?
      socket = TCPSocket.new("localhost", 8752)
      socket.close
      true
    rescue StandardError
      false
    end

    def ruby_relay_running?
      socket = TCPSocket.new("localhost", 3142)
      socket.close
      true
    rescue StandardError
      false
    end

    # ── Step 8: Telemetry verification ────────────────────────────────────
    def do_check_telemetry
      banner("Verify telemetry flow")
      say "This does NOT send anything to Tesla. It only reads local state."
      say
      cfg = api.check_telemetry rescue nil
      synced = cfg.is_a?(Hash) && cfg.dig(:response, :synced)
      say "  Tesla-side registration synced: #{synced ? green('yes') : red('no')}"

      cached = User.me.caches.get(:car_data) || {}
      ts_ms  = cached[:timestamp]
      if ts_ms.present?
        age = Time.current - Time.at(ts_ms / 1000)
        say "  car_data cache last updated: #{Time.at(ts_ms / 1000).iso8601} (#{age.round}s ago)"
        if age < 5.minutes
          say green("  ✓ Telemetry is recent. Webhooks are flowing.")
          mark_completed(:"8")
        else
          say yellow("  ⚠ Cache is stale. Drive the car (or wake + open door) to trigger pushes.")
          say "  Watch for hits on POST /webhooks/tesla_telemetry in prod logs."
        end
      else
        say red("  ✗ No car_data cache yet. Telemetry hasn't pushed.")
        say "  Verify: (1) Step 6 was run, (2) ardesian.com:4443 is reachable + TLS valid,"
        say "          (3) car is online and being driven/woken."
      end
    end

    # Sends a signed flash_lights via the local Go proxy. Success means the
    # full command path works end-to-end: user token + partner signing key +
    # paired-on-vehicle + Fleet API + car. This is what we actually care about.
    def smoke_test_flash_lights
      res = Api.request(
        method:  :post,
        url:     "https://localhost:8752/api/1/vehicles/#{Tesla.vin}/command/flash_lights",
        headers: {
          Authorization: "Bearer #{api.access_token}",
          content_type:  "application/json",
        },
        ssl_ca_file: "_scripts/tesla_keys/cert.pem",
      )
      res.is_a?(Hash) && res.dig(:response, :result) == true
    end

    def do_third_party_auth
      banner("Third-party auth (user access_token)")
      url = api.auth_url
      section("OPEN IN BROWSER, log in, approve")
      say url
      end_section
      say "Tesla redirects to:"
      say "  #{cyan("https://#{DOMAIN}/webhooks/auth?code=NA_…&state=…")}"
      say
      say "Paste either the full redirect URL or just the #{green('code')} value."
      input = ask("Code or URL")
      if input.to_s.strip.empty?
        say yellow("  Skipped.")
        return
      end

      code = extract_code(input.strip)
      if code.blank?
        say red("  ✗ Could not extract a `code` from input")
        return
      end
      api.code = code
      ok = api.access_token.present?
      say(ok ? green("  ✓ access_token + refresh_token stored (dev DB)") : red("  ✗ Exchange returned no token"))
      return unless ok

      # Discover vehicles with the user token — this is what creates the
      # partner ↔ VIN association on Tesla's side. Until this runs, partner
      # endpoints like fleet_status return 404 not_found for our VIN.
      vehicles_seen = check("Register vehicles with partner (GET /vehicles)") {
        res = api.get(:vehicles)
        vins = (res.dig(:response) || []).map { |v| v[:vin] }
        say "  vehicles visible: #{vins.inspect}"
        vins.include?(Tesla.vin)
      }
      say yellow("  WARN: our VIN (#{Tesla.vin}) not in user's vehicle list") unless vehicles_seen

      mark_completed(:"5")

      say
      confirm = ask("Write a prodExec script to sync these tokens to prod? [y/N]").to_s.strip.downcase
      write_prod_token_sync_script if confirm == "y"
    end

    # Writes a one-off script that the user runs manually via prodExec to
    # push tokens to prod. Only callable in development — refuses to write
    # the file otherwise so a compromised prod console can't spoof tokens
    # into someone's cache.
    def write_prod_token_sync_script
      unless Rails.env.development?
        say red("  ✗ Refusing to write token-sync script outside development (env=#{Rails.env}).")
        return
      end

      ts = Time.current.strftime("%Y%m%d_%H%M%S")
      path = Rails.root.join("lib/scripts/tesla_sync_tokens_#{ts}.rb").to_s

      File.write(path, <<~RUBY)
        # Push freshly-exchanged Tesla tokens into prod's user cache.
        # Generated by TeslaSetup on #{Time.current.utc.iso8601}.
        # Run with: prodExec #{path.sub("#{Rails.root}/", "")}

        cache = User.me.caches.find_or_create_by!(key: :oauth)
        cache.dig_set(:tesla_api, :access_token,  #{api.access_token.to_s.inspect})
        cache.dig_set(:tesla_api, :refresh_token, #{api.refresh_token.to_s.inspect})
        cache.dig_set(:tesla_api, :id_token,      #{api.id_token.to_s.inspect})

        puts "Tesla tokens written to prod."
      RUBY

      say
      section("PROD TOKEN SYNC SCRIPT")
      say "Wrote: #{green(path.sub("#{Rails.root}/", ""))}"
      say "Run:   #{green("prodExec #{path.sub("#{Rails.root}/", "")}")}"
      say yellow("  Delete the script after running (plaintext tokens).")
      end_section
    end

    def do_request_telemetry
      banner("Register Fleet Telemetry")
      say "Tesla will be told to push telemetry to: #{green('ardesian.com:4443')}"
      say "Requires a fresh user access_token (Step 5)."
      say
      say "Pre-flight: verify the TLS endpoint's cert matches what Tesla will trust."
      out = `bash _scripts/tesla/check_server_cert.sh _scripts/tesla/validate_server.json 2>&1`
      say "  #{out.strip.gsub("\n", "\n  ")}"
      say
      confirm = ask("Send the telemetry-config change to Tesla now? [y/N]").to_s.strip.downcase
      return say(yellow("  Skipped.")) unless confirm == "y"

      # Direct call to fleet-api (skip the local-proxy hop used by api.request_telemetry)
      res = Api.request(
        method:  :post,
        url:     "#{FLEET_API_URL}vehicles/fleet_telemetry_config",
        payload: {
          vins:   [Tesla.vin],
          config: {
            alert_types: ["service"],
            fields:      TeslaService.fields(30.minutes),
            ca:          File.read("_scripts/tesla_keys/cert.pem"),
            hostname:    DOMAIN,
            port:        4443,
          },
        },
        headers: {
          Authorization: "Bearer #{api.access_token}",
          content_type:  "application/json",
          user_agent:    "Jarvis-1.0",
        },
      )
      say "  response: #{res.inspect}"
      ok = res.is_a?(Hash) && res[:error].blank?
      mark_completed(:"6") if ok
    end

    # ── Helpers ───────────────────────────────────────────────────────────
    def extract_code(input)
      if input.include?("code=")
        Rack::Utils.parse_query(input.split("?", 2).last)["code"].to_s
      else
        input
      end
    rescue StandardError
      input
    end

    def partner_auth_headers
      { Authorization: "Bearer #{partner_token}" }
    end

    def with_quiet_db
      loggers = [
        defined?(ActiveRecord::Base) ? ActiveRecord::Base.logger : nil,
        defined?(ActionController::Base) ? ActionController::Base.logger : nil,
        Rails.logger,
      ].compact.uniq
      old_levels = loggers.map(&:level)
      loggers.each { |l| l.level = Logger::ERROR }
      yield
    ensure
      loggers&.zip(old_levels || [])&.each { |l, lvl| l.level = lvl }
    end

    def check(label)
      ok = yield
      say(ok ? green("  ✓ #{label}") : red("  ✗ #{label}"))
      ok
    rescue StandardError => e
      say red("  ✗ #{label} — #{e.class}: #{e.message}")
      false
    end

    def banner(title)
      say
      say cyan("━" * (title.length + 4))
      say cyan("  #{title}")
      say cyan("━" * (title.length + 4))
    end

    def section(title)
      padded = "  #{title}  "
      say
      say magenta(padded.center(72, "═"))
    end

    def end_section
      say magenta("═" * 72)
      say
    end

    def ask(prompt)
      print yellow("  ▸ #{prompt}: ")
      $stdout.flush
      $stdin.gets.to_s.chomp
    end

    def say(msg="") = $stdout.puts(msg)
    def green(s)    = "\e[32m#{s}\e[0m"
    def red(s)      = "\e[31m#{s}\e[0m"
    def yellow(s)   = "\e[33m#{s}\e[0m"
    def cyan(s)     = "\e[36m#{s}\e[0m"
    def magenta(s)  = "\e[35m#{s}\e[0m"
    def dim(s)      = "\e[90m#{s}\e[0m"
  end
end
