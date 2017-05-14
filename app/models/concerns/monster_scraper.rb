require 'capybara/poltergeist'
# MonsterScraper.scrape
module MonsterScraper
  class << self
    # http://summonerswar.wikia.com/wiki/Fire_Monsters
    # http://summonerswar.wikia.com/wiki/Water_Monsters
    # http://summonerswar.wikia.com/wiki/Wind_Monsters
    # http://summonerswar.wikia.com/wiki/Dark_Monsters
    # http://summonerswar.wikia.com/wiki/Light_Monsters

    def scrape(opts={})
      setup_capybara
      puts "Visiting page..."
      page.visit("https://swarfarm.com/bestiary/")

      page_num = 1
      @monster_urls = []
      last_page = page.all(".pager-btn").map(&:text).uniq.map(&:to_i).max

      @monster_urls += awakened_monster_urls
      until page_num > last_page
        puts "Rows: #{@monster_urls.count} Page: #{page_num}/#{last_page}"
        page_num += 1
        page.evaluate_script("$('#id_page').val(#{page_num})")
        page.evaluate_script("update_inventory()")
        wait_for_element(".pager-btn[data-page='#{page_num}'].active")
        @monster_urls += awakened_monster_urls
      end
      puts "Rows: #{@monster_urls.count}"
      @monster_urls.uniq!
      @monster_urls.each do |monster_url|
        Monster.find_or_create_by(url: monster_url).reload_data
      end
    end

    def update_monster_data(monster)
      setup_capybara
      return unless monster.try(:url).present?
      puts "Visiting Monster page..."
      page.visit(monster.url)
      binding.pry

      # $('.tab-pane')
    end

    private

    def page; @_page; end
    def wait_for_element(element_selector, max_time=60)
      start = Time.now
      print "Waiting"
      until page.all(element_selector).any? || (Time.now > start + max_time.seconds)
        print "."
        sleep 0.5
      end
      puts "Found in #{(Time.now - start).to_f.round(2)} seconds"
    end

    def setup_capybara
      return if Capybara.current_driver == :poltergeist || page
      puts "Setting up Capybara"
      Capybara.register_driver :poltergeist do |app|
        Capybara::Poltergeist::Driver.new(app, js_errors: false, phantomjs_options: ["--load-images=no"])
      end
      Capybara.default_driver = :poltergeist
      @_page = Capybara.current_session
    end

    def awakened_monster_urls
      page.all("#bestiary_table tbody tr").map do |tr|
        url_from_row(tr) if tr.all("td.monster-awakens").first.text.blank?
      end.compact
    end

    def url_from_row(row)
      row.first("td a")['href']
    end

  end
end
