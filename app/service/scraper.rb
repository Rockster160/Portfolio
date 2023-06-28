require "open-uri"
require "selenium-webdriver"
require "webdrivers"

module Scraper
  module_function

  # USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/92.0.4515.107 Safari/537.36"
  USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/113.0.0.0 Safari/537.36"

  def driver(headless=false)
    @driver ||= begin
      options = Selenium::WebDriver::Chrome::Options.new
      options.add_argument("--headless") if headless
      options.add_argument("--user-agent=#{USER_AGENT}")

      Selenium::WebDriver.for :chrome, options: options
    end
  end

  def screenshot!(filename=nil)
    driver.manage.window.resize_to(1200, 1200)
    driver.save_screenshot("#{[:screenshot, filename].map(&:presence).compact.join("-")}.png")
    `open screenshot.png`
  end

  def wait(sec=10)
    Selenium::WebDriver::Wait.new(timeout: sec) # seconds
  end

  def quit
    driver.quit
    @driver = nil
  end
end
# def wait(sec=10)
#   Selenium::WebDriver::Wait.new(timeout: sec) # seconds
# end
# def driver(headless: false)
#   @driver ||= Scraper.driver(headless)
# end
# def screenshot!(filename=nil)
#   Scraper.screenshot!(filename)
# end
# def show_source
#   src = File.open("source.html", "w+") { |f| f.puts(driver.page_source) }
#   `open source.html`
#   # sleep 3
#   # rm file
# end

# driver.navigate.to "https://auth.tesla.com/oauth2/v3/authorize?client_id=ownerapi&code_challenge=uFnDQOhBRJZb9j_sbG8bWhpSLAtuPTwhylaMkIJIHpU&code_challenge_method=S256&login_hint=rocco11nicholls%40gmail.com&redirect_uri=https%3A%2F%2Fauth.tesla.com%2Fvoid%2Fcallback&response_type=code&scope=openid+email+offline_access&state=f1289496913dacc9b5050e424be86aa8"
# psswd = wait.until { driver.find_element(id: "form-input-credential") }
# psswd.clear
# psswd.send_keys "abcd"
# driver.find_element(id: "form-submit-continue").click
# # driver.find_element(name: "name")
# # driver.find_element(id: "idName")
# # driver.find_element(css: "cssTag")
# # driver.find_element(tag_name: "tagName")
# # driver.find_element(class_name: "className")
# # driver.find_element(partial_link_text: "partialLink")
# # driver.find_element(xpath: "//*[@id="hpG0a"]/a")
