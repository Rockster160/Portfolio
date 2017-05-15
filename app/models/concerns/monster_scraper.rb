require 'capybara/poltergeist'
# MonsterScraper.scrape
module MonsterScraper
  class << self

    def scrape(opts={})
      setup_capybara
      puts "Visiting page..."
      page.visit("https://swarfarm.com/bestiary/")

      page_num = 1
      @monster_urls = []
      last_page = page.all(".pager-btn").map(&:text).uniq.map(&:to_i).max

      @monster_urls += awakened_monster_urls
      until page_num >= last_page
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
        Monster.find_or_create_by(url: monster_url)
      end
      Monster.where(name: nil).each(&:reload_data)
    end

    def update_monster_data(monster)
      setup_capybara
      return unless monster.try(:url).present?
      puts "Visiting Monster page..."
      page.visit(monster.url)

      monster_section = page.first('.tab-pane')
      monster_name = text_without_children(monster_section.all('.bestiary-name').last, 'h1')
      puts "Found #{monster_name}"

      monster_content = monster_section.all('.clearfix + .row').last
      info = monster_content.all('.col-lg-6')[0]
      stats = monster_content.all('.col-lg-6').last

      monster_attrs = {
        name: monster_name,
        image_url: monster_section.all('.monster-box').last.find('.monster-box-thumb > img')['src'],
        stars: monster_section.all('.monster-box').last.all('.monster-box-thumb span > *').count,
        element: monster_section.all('.bestiary-name h1 img').last['src'].split(/\/|\./).second_to_last,
        archetype: monster_section.all('.bestiary-name h1 small').last.text.squish.downcase,
        health: value_from_tr(stats.all('tr')[1]).to_i,
        attack: value_from_tr(stats.all('tr')[2]).to_i,
        defense: value_from_tr(stats.all('tr')[3]).to_i,
        speed: value_from_tr(stats.all('tr')[4]).to_i,
        crit_rate: value_from_tr(stats.all('tr')[5]).to_i,
        crit_damage: value_from_tr(stats.all('tr')[6]).to_i,
        accuracy: value_from_tr(stats.all('tr')[7]).to_i,
        resistance: value_from_tr(stats.all('tr')[8]).to_i,
        last_updated: DateTime.current
      }.reject { |mk,mv| mv.blank? }
      monster.update(monster_attrs)

      skill_containers = info.all('.row').last.all('[class^=col] .panel')
      skill_containers.each do |skill_container|
        next unless skill_container.all('.panel-heading').any?
        multiplier = skill_container.all('.list-group .list-group-item p').last.try(:text).to_s
        multiplier = multiplier.gsub("(Fixed)", "").gsub(/max hp/i, "HP").squish

        description = skill_container.all('.list-group .list-group-item p').first.try(:text).to_s
        multiplier = description == multiplier ? "" : multiplier
        hit_count = NumbersInWords.in_numbers(description.match(/attacks the enemy \w+ times/i).to_s[18..-7]).to_i
        binding.pry unless skill_container.all('.panel-heading .panel-title strong').any?
        skill_attrs = {
          name: skill_container.find('.panel-heading .panel-title strong').text,
          description: description,
          muliplier_formula: multiplier + (hit_count.to_i > 1 ? " x#{hit_count}" : "")
        }.reject { |mk,mv| mv.blank? }
        monster.monster_skills.find_or_create_by(name: skill_attrs[:name]).update(skill_attrs)
      end

      monster
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

    def text_without_children(parent, selector)
      return unless parent && selector
      child_selectors = parent.all("#{selector} > *").map(&:text).join("|")
      parent.find(selector).text.gsub(/#{child_selectors}/i, "").squish
    end

    def value_from_tr(tr)
      tr.all("td").map(&:text).map(&:presence).compact.last
    end

  end
end
