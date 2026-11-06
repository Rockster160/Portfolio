# Pictures of real pages, for a pull request to show what changed. The Feature
# Builder writes a throwaway spec under tmp/screenshot_specs/ tagged
# `screenshot: true`, signs a factory user in, visits the page and calls
# `screenshot!`. Everything on screen comes from factories, never the dev
# database: the repo is public and so is every image in a PR.
#
# A system spec rather than a request spec because only a browser runs the JS
# and applies the CSS, which is most of what a screenshot is for. The system
# spec's shared connection is what lets the Puma thread see the example's
# unsaved-to-disk records.
require "selenium-webdriver"
require "capybara/selenium/logger_suppressor"

# Capybara 3.37 wraps Selenium's logger with `initialize(*)` and a bare
# `super`, which hands Selenium 4.10's keyword arguments over as one extra
# positional hash, and starting chromedriver dies on "wrong number of
# arguments". This goes around the wrapper to Selenium's own initialize with
# the keywords intact, and sets the one flag the wrapper existed to set.
module SeleniumLoggerKeywords
  def initialize(*, **)
    @suppress_for_capybara = false
    original = ::Selenium::WebDriver::Logger.instance_method(:initialize)
    original = original.super_method until original.owner == ::Selenium::WebDriver::Logger
    original.bind_call(self, *, **)
  end
end
Selenium::WebDriver::Logger.prepend(SeleniumLoggerKeywords)

module ScreenshotHelper
  # Where the PNGs land. The builder points this at a folder of its own so a
  # second build can't pick up the first one's pictures.
  def self.dir
    ENV["BUILDER_SCREENSHOTS_DIR"].presence || Rails.root.join("tmp/screenshots").to_s
  end

  # The phone the app is mostly used on, at its CSS size. Chrome draws it at
  # twice that, so the image stays sharp on a retina screen reviewing the PR.
  PHONE = [430, 932].freeze

  # The `webdrivers` gem fetches a chromedriver to match the installed Chrome
  # over Net::HTTP, which the suite's WebMock refuses. These are the only hosts
  # it reads from, and only a screenshot example is let through to them.
  CHROMEDRIVER_HOSTS = [
    "googlechromelabs.github.io",
    "storage.googleapis.com",
    "edgedl.me.gvt1.com",
  ].freeze

  # Every page is served from a name under `localhost`, which Chrome always
  # resolves to this machine, so no hosts file or DNS is involved. It takes two
  # labels for Rails to see a subdomain on the second.
  HOST      = "http://portfolio.localhost".freeze
  BYTE_HOST = "http://byte.portfolio.localhost".freeze

  # Byte only answers on its own subdomain, so a Byte example starts here, as
  # its first step. Keep each example on one host: signing in on the main site
  # first leaves a second set of sign-in cookies that sends Byte to its about
  # page instead.
  def on_byte!(user)
    Capybara.app_host = BYTE_HOST
    screenshot_sign_in(user)
  end

  PASSWORD = "password123".freeze

  # Byte opens for its owner and nobody else (User#byte_access?). The test
  # database's owner gets a password the form can type, inside the example's
  # transaction, so it is gone again when the example ends.
  def screenshot_owner
    User.me.tap { |owner| owner.update!(password: PASSWORD, password_confirmation: PASSWORD) }
  end

  def screenshot_sign_in(user, password: PASSWORD)
    visit "/login"
    fill_in "user[username]", with: user.username
    fill_in "user[password]", with: password
    click_on "Login"
  end

  # Saves the current page as `<name>.png` and returns the path. `width` and
  # `height` are CSS pixels; a desktop shot is `width: 1280, height: 800`.
  def screenshot!(name, width: PHONE.first, height: PHONE.last)
    page.driver.browser.manage.window.resize_to(width, height)
    FileUtils.mkdir_p(ScreenshotHelper.dir)
    path = File.join(ScreenshotHelper.dir, "#{name.to_s.parameterize}.png")
    page.save_screenshot(path) # rubocop:disable Lint/Debugger
    path
  end
end

RSpec.configure do |config|
  config.include ScreenshotHelper, :screenshot

  config.before(:each, :screenshot) {
    WebMock.disable_net_connect!(allow_localhost: true, allow: ScreenshotHelper::CHROMEDRIVER_HOSTS)
    Capybara.app_host = ScreenshotHelper::HOST
    Capybara.always_include_port = true
    driven_by(:selenium, using: :headless_chrome, screen_size: ScreenshotHelper::PHONE) { |options|
      options.add_argument("--hide-scrollbars")
      options.add_argument("--force-device-scale-factor=2")
    }
  }

  config.after(:each, :screenshot) {
    Capybara.app_host = nil
    Capybara.always_include_port = false
    WebMock.disable_net_connect!(allow_localhost: true)
  }
end
