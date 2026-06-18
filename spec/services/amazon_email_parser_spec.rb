# Fixtures cover the modern Amazon shipment email format (rio-card / rexMultiOrderCard):
#   50638 - Shipped, single item, "Arriving overnight 4 AM – 8 AM"
#   50641 - Delivered, grocery (no quoted name in subject)
#   50684 - Shipped, multi-item, "Arriving today 5 PM – 10 PM"
#   50685 - Ordered, single item, "Arriving tomorrow"
#   50687 - Delivered, multi-item (transition partner for 50684)
#   50688 - Delivered, multi-item, "and 1 more item" subject
#   50695 - Shipped, single item, "Arriving tomorrow"
#   50711 - Delivered, single item, "Delivered today"
#   50714 - Shipped, single item, "Arriving overnight" (was missing from first reparse)
#   50720 - Delivered, grocery format, "Delivered today" (no item text in card link)
#   50724 - Delivery update / delayed, "Estimated to arrive by June 11"
#   50729 - "Delivered: Order # 111-9960600-8061807" but card actually holds order 114-4609559
RSpec.describe AmazonEmailParser do
  include ActiveSupport::Testing::TimeHelpers

  CASES = [
    {id: 50_638, subject: 'Shipped: "GOXAWEE Metal Stand Up Weed..."',                       order: "111-4126442-3377044", asins: ["B0GF24P6J3"],                    delivered: false, date_offset: 1, time_range: "4-8AM"},
    {id: 50_641, subject: "Delivered: Your Amazon grocery items | Order: ⁦#111-5515311-2607449⁩", order: "111-5515311-2607449", asins: ["B000P6G12U"],                    delivered: true,  date_offset: 0, time_range: nil},
    {id: 50_684, subject: 'Shipped: ⁦2⁩ "Red Raspberries, 6 oz" and ⁦1⁩ more item',          order: "114-5001928-1633007", asins: ["B000P6G12U", "B000P717MI"],      delivered: false, date_offset: 0, time_range: "5-10PM"},
    {id: 50_685, subject: 'Ordered: "Amazon Basics Multipurpose..."',                         order: "111-0453665-0021069", asins: ["B01FV0F75G"],                    delivered: false, date_offset: 1, time_range: nil},
    {id: 50_687, subject: "Delivered: Your Amazon grocery items | Order: ⁦#114-5001928-1633007⁩", order: "114-5001928-1633007", asins: ["B000P6G12U", "B000P717MI"],      delivered: true,  date_offset: 0, time_range: nil},
    {id: 50_688, subject: 'Delivered: "Pet Botanics 10 oz. Pouch..." and ⁦1⁩ more item',     order: "114-3328324-3906607", asins: ["B00065VGWK", "B0144BMLFM"],      delivered: true,  date_offset: 0, time_range: nil},
    {id: 50_695, subject: 'Shipped: "Romeda 90 Pcs Ceiling Hooks..."',                        order: "111-3078388-1633869", asins: ["B0CJR8TQFT"],                    delivered: false, date_offset: 1, time_range: nil},
    {id: 50_711, subject: 'Delivered: "Romeda 90 Pcs Ceiling Hooks..."',                      order: "111-3078388-1633869", asins: ["B0CJR8TQFT"],                    delivered: true,  date_offset: 0, time_range: nil},
    {id: 50_714, subject: 'Shipped: "Strawberries, 1 Lb"',                                    order: "111-0023085-0653859", asins: ["B000P6J0SM"],                    delivered: false, date_offset: 1, time_range: "4-8AM"},
    {id: 50_720, subject: "Delivered: Your Amazon grocery items | Order: ⁦#111-0023085-0653859⁩", order: "111-0023085-0653859", asins: ["B000P6J0SM"],                    delivered: true,  date_offset: 0, time_range: nil},
    {id: 50_724, subject: 'Delivery update: "CELSIUS PEACH VIBE..." and ⁦1⁩ more item',       order: "114-4609559-9905031", asins: ["B07BY3HJPT", "B086ZL794C"],      delivered: false, date_offset: 3, time_range: nil},
    {id: 50_729, subject: "Delivered: Order ⁦# 111-9960600-8061807⁩",                         order: "114-4609559-9905031", asins: ["B086ZL794C", "B07BY3HJPT"],      delivered: true,  date_offset: 0, time_range: nil},
  ]

  def parse(email_id, subject)
    email = double(
      "Email",
      id:      email_id,
      to_html: html_fixture("email_body_#{email_id}", raw: true),
      subject: subject,
    )
    AmazonEmailParser.parse(email)
  end

  before do
    AmazonOrder.clear
    allow(AmazonOrder).to receive(:broadcast).and_return(nil)
    allow(AmazonOrder).to receive(:save).and_return(nil)
    allow(RestClient).to receive(:get).and_return(nil)
    allow(Jarvis).to receive(:cmd).and_return(nil)
    allow(ChatGPT).to receive(:short_name_from_order).and_return("ShortName")
    allow(ChatGPT).to receive(:short_names_from_orders) { |titles| Array.new(titles.size) { "ShortName" } }
    allow(SlackNotifier).to receive(:err).and_return(nil)
    allow(SlackNotifier).to receive(:notify).and_return(nil)
    allow_any_instance_of(AmazonEmailParser).to receive(:retrieve_full_name).and_return(nil)
    # Catalog uses MeCache which persists across tests (real user backing). Isolate.
    allow(AmazonItemCatalog).to receive(:all).and_return({})
    allow(AmazonItemCatalog).to receive(:set).and_return(nil)
  end

  around do |example|
    travel_to(DateTime.new(2026, 6, 8, 12, 0, 0)) { example.run }
  end

  CASES.each do |c|
    context "email #{c[:id]} (#{c[:subject][0..40]})" do
      before { parse(c[:id], c[:subject]) }

      it "creates one AmazonOrder per ASIN with correct order_id" do
        orders = AmazonOrder.by_order(c[:order])
        expect(orders.map(&:item_id)).to match_array(c[:asins])
        orders.each do |item|
          expect(item.order_id).to eq(c[:order])
          expect(item.email_ids).to include(c[:id])
          expect(item.errors).to be_none
        end
      end

      it "sets delivered=#{c[:delivered]} based on email status" do
        AmazonOrder.by_order(c[:order]).each do |item|
          expect(!!item.delivered).to eq(c[:delivered])
        end
      end

      it "sets delivery_date to #{c[:date_offset]} day(s) from now" do
        expected = (Date.current + c[:date_offset]).iso8601
        AmazonOrder.by_order(c[:order]).each do |item|
          expect(item.delivery_date).to eq(expected)
        end
      end

      it "sets time_range=#{c[:time_range].inspect}" do
        AmazonOrder.by_order(c[:order]).each do |item|
          expect(item.time_range).to eq(c[:time_range])
        end
      end
    end
  end

  describe "AI naming resilience" do
    let(:c) { CASES.find { |row| row[:id] == 50_695 } }

    it "still creates AmazonOrders when ChatGPT raises (quota exceeded)" do
      allow(ChatGPT).to receive(:short_names_from_orders).and_raise(StandardError, "insufficient_quota")
      parse(c[:id], c[:subject])
      orders = AmazonOrder.by_order(c[:order])
      expect(orders.map(&:item_id)).to match_array(c[:asins])
      expect(orders.first.delivery_date).to be_present
    end

    it "skips the ChatGPT call entirely when skip_ai_naming: true" do
      expect(ChatGPT).not_to receive(:short_names_from_orders)
      email = double("Email", id: c[:id], to_html: html_fixture("email_body_#{c[:id]}", raw: true), subject: c[:subject])
      AmazonEmailParser.parse(email, skip_ai_naming: true)
      orders = AmazonOrder.by_order(c[:order])
      expect(orders.map(&:item_id)).to match_array(c[:asins])
    end

    it "asks ChatGPT for ALL items in one batched call (not one per ASIN)" do
      skip "GPT call is currently disabled inside prefetch_names! (Disabling GPT for now - need to update API Tokens)"
      c = CASES.find { |row| row[:id] == 50_684 } # 2 ASINs in one email
      expect(ChatGPT).to receive(:short_names_from_orders).once.with(
        an_instance_of(Array).and(satisfy { |titles| titles.size == 2 }),
      ).and_return(["Raspberries", "Blackberries"])
      parse(c[:id], c[:subject])
    end
  end

  describe "per-item names" do
    before { allow(ChatGPT).to receive(:short_name_from_order) { |full, _| full } }

    it "names each item from its own card link, not the email's subject quote" do
      c = CASES.find { |row| row[:id] == 50_684 }
      parse(c[:id], c[:subject])
      orders = AmazonOrder.by_order(c[:order]).index_by(&:item_id)
      expect(orders["B000P6G12U"].listed_name).to match(/Red Raspberries/i)
      expect(orders["B000P717MI"].listed_name).to match(/Blackberries/i)
      expect(orders["B000P6G12U"].listed_name).not_to eq(orders["B000P717MI"].listed_name)
    end

    it "falls back to the subject-quoted name when ChatGPT raises and only one ASIN ships" do
      allow(ChatGPT).to receive(:short_names_from_orders).and_raise(StandardError, "insufficient_quota")
      c = CASES.find { |row| row[:id] == 50_695 }
      parse(c[:id], c[:subject])
      item = AmazonOrder.by_order(c[:order]).first
      expect(item.listed_name).to be_present
    end
  end

  describe "staggered delivery" do
    def synthetic_delivery_email(email_id, order_id, asins, link_texts)
      links = asins.zip(link_texts).map { |asin, text|
        %(<a href="https://www.amazon.com/dp/#{asin}">#{text}</a>)
      }.join
      html = <<~HTML
        <html><body>
          <div class="rio-card">
            Order # #{order_id}. Your package was delivered today.
            #{links}
          </div>
        </body></html>
      HTML
      double("Email", id: email_id, to_html: html, subject: %(Delivered: "#{link_texts.first}"))
    end

    it "marks only the items present in the delivery email, not the whole order" do
      shipped = CASES.find { |row| row[:id] == 50_684 }
      parse(shipped[:id], shipped[:subject])
      expect(AmazonOrder.by_order(shipped[:order]).map(&:delivered)).to all(be_falsey)

      partial = synthetic_delivery_email(99_001, shipped[:order], [shipped[:asins].first], ["Red Raspberries, 6 oz"])
      AmazonEmailParser.parse(partial)

      orders = AmazonOrder.by_order(shipped[:order]).index_by(&:item_id)
      expect(orders[shipped[:asins].first].delivered).to eq(true)
      expect(orders[shipped[:asins].last].delivered).to be_falsey
      expect(orders[shipped[:asins].last].email_ids).not_to include(99_001)
    end

    it "does not update delivery_date for items absent from the email" do
      shipped = CASES.find { |row| row[:id] == 50_684 }
      parse(shipped[:id], shipped[:subject])
      original_dates = AmazonOrder.by_order(shipped[:order]).index_by(&:item_id).transform_values(&:delivery_date)

      partial = synthetic_delivery_email(99_002, shipped[:order], [shipped[:asins].first], ["Red Raspberries, 6 oz"])
      AmazonEmailParser.parse(partial)

      orders = AmazonOrder.by_order(shipped[:order]).index_by(&:item_id)
      expect(orders[shipped[:asins].last].delivery_date).to eq(original_dates[shipped[:asins].last])
    end
  end

  describe "delivery notice with no item card" do
    let(:order_id) { "111-9960600-8061807" }

    def delivery_notice_email(id, oid, also_in_html: nil)
      html = <<~HTML
        <html><body>
          <div>Order # #{oid}. Your package was delivered.</div>
          #{also_in_html ? "<div>Track other order #{also_in_html}</div>" : ""}
        </body></html>
      HTML
      double("Email", id: id, to_html: html, subject: "Delivered: Order # #{oid}")
    end

    it "does not create a phantom item when no items are known for the order" do
      jarvis_calls = []
      allow(Jarvis).to receive(:cmd) { |msg| jarvis_calls << msg }

      AmazonEmailParser.parse(delivery_notice_email(99_101, order_id))

      expect(AmazonOrder.by_order(order_id)).to be_empty
      expect(jarvis_calls.last).to include("99101")
    end

    it "does NOT auto-mark pre-existing items delivered (siblings may still ship later)" do
      existing = AmazonOrder.create(order_id: order_id, item_id: "B0AAAAAAAA", name: "Existing item")
      allow(Jarvis).to receive(:cmd).and_return(nil)

      AmazonEmailParser.parse(delivery_notice_email(99_102, order_id))

      expect(existing.delivered).to be_falsey
      expect(existing.email_ids).not_to include(99_102)
    end

    it "anchors order_id to the order-card text, ignoring stray ids elsewhere in the html" do
      stray_oid = "999-1111111-2222222"
      shipped = CASES.find { |row| row[:id] == 50_684 }
      email = double(
        "Email",
        id:      99_103,
        to_html: html_fixture("email_body_#{shipped[:id]}", raw: true) + "<div>#{stray_oid}</div>",
        subject: shipped[:subject],
      )
      AmazonEmailParser.parse(email)
      expect(AmazonOrder.by_order(shipped[:order])).not_to be_empty
      expect(AmazonOrder.by_order(stray_oid)).to be_empty
    end
  end

  describe "AmazonItemCatalog reuse across orders" do
    before do
      allow(AmazonItemCatalog).to receive(:all).and_return({})
      allow(AmazonItemCatalog).to receive(:set).and_return(nil)
    end

    it "writes the GPT-cleaned name into the catalog when an ASIN is parsed for the first time" do
      skip "GPT call is currently disabled inside prefetch_names! (Disabling GPT for now - need to update API Tokens)"
      allow(ChatGPT).to receive(:short_names_from_orders).and_return(["Strawberries"])
      c = CASES.find { |row| row[:id] == 50_714 }
      expect(AmazonItemCatalog).to receive(:set).with(
        "B000P6J0SM",
        hash_including(name: "Strawberries"),
      )
      parse(c[:id], c[:subject])
    end

    it "reuses a previously-cached name (e.g. a manual rename) instead of the card text" do
      allow(AmazonItemCatalog).to receive(:get).with("B000P6J0SM").and_return(
        { name: "Strawbz", listed_name: "Strawberries, 1 Lb" },
      )
      c = CASES.find { |row| row[:id] == 50_714 }
      parse(c[:id], c[:subject])
      expect(AmazonOrder.by_order(c[:order]).first.name).to eq("Strawbz")
    end

    it "seeds the catalog with listed_name/full_name even when skip_ai_naming is true" do
      email = double(
        "Email",
        id:      50_714,
        to_html: html_fixture("email_body_50714", raw: true),
        subject: 'Shipped: "Strawberries, 1 Lb"',
      )
      expect(AmazonItemCatalog).to receive(:set).with(
        "B000P6J0SM",
        hash_including(:listed_name),
      )
      AmazonEmailParser.parse(email, skip_ai_naming: true)
    end

    it "applies the cached rename to a brand-new AmazonOrder created under a different order_id" do
      # Simulate "you renamed B000P6J0SM to 'Strawbz' last year, then ordered the same SKU again under a fresh order".
      allow(AmazonItemCatalog).to receive(:get).with("B000P6J0SM").and_return({ name: "Strawbz" })
      synthetic_html = <<~HTML
        <html><body>
          <div class="rio-card">
            Order # 222-1111111-2222222
            Arriving overnight 4 AM – 8 AM
            <a href="https://www.amazon.com/dp/B000P6J0SM">Strawberries, 1 Lb</a>
          </div>
        </body></html>
      HTML
      AmazonEmailParser.parse(double(
        "Email",
        id:      99_500,
        to_html: synthetic_html,
        subject: 'Shipped: "Strawberries, 1 Lb"',
      ))

      item = AmazonOrder.find("222-1111111-2222222", "B000P6J0SM")
      expect(item).to be_present
      expect(item.name).to eq("Strawbz")
    end

    it "does NOT write `name:` into the catalog from safe_name - only the rename channel and GPT prefetch should" do
      sets_with_name = []
      allow(AmazonItemCatalog).to receive(:set) { |_, **kwargs|
        sets_with_name << kwargs if kwargs.key?(:name)
      }
      c = CASES.find { |row| row[:id] == 50_714 }
      AmazonEmailParser.parse(double(
        "Email",
        id:      c[:id],
        to_html: html_fixture("email_body_#{c[:id]}", raw: true),
        subject: c[:subject],
      ), skip_ai_naming: true)
      expect(sets_with_name).to be_empty,
        "safe_name must never write `name:` to the catalog (would clobber a rename)"
    end

    it "skips the ChatGPT batch call when every ASIN in the email is already cached" do
      allow(AmazonItemCatalog).to receive(:get).with("B000P6J0SM").and_return(
        { name: "Strawbz" },
      )
      expect(ChatGPT).not_to receive(:short_names_from_orders)
      c = CASES.find { |row| row[:id] == 50_714 }
      parse(c[:id], c[:subject])
    end
  end

  describe "multi-order emails (one rio-card listing items from two distinct order_ids)" do
    # 50734 is an "Ordered" email whose rio-card glues together two orders:
    #   Order 111-4536894-1373807 -> Pet Botanics (B0144BMLFM) + Ceramic Bowls (B0GFLZQHVM)  arriving today 5-10 PM
    #   Order 111-0441897-6436244 -> Litter Genie  (B0FDLFSZ1S)                              arriving Tuesday
    # The card is what Amazon emails as "Litter Genie + 2 more items" - subject is misleading.
    it "attributes each ASIN to the order_id printed in its own sub-block" do
      email = double(
        "Email",
        id:      50_734,
        to_html: html_fixture("email_body_50734", raw: true),
        subject: 'Ordered: "Litter Genie Easy Roll..." and 2 more items',
      )
      AmazonEmailParser.parse(email)

      pet_botanics  = AmazonOrder.find("111-4536894-1373807", "B0144BMLFM")
      bowls         = AmazonOrder.find("111-4536894-1373807", "B0GFLZQHVM")
      litter_genie  = AmazonOrder.find("111-0441897-6436244", "B0FDLFSZ1S")

      expect(pet_botanics).to be_present, "Pet Botanics should land under its own order id"
      expect(bowls).to        be_present, "Ceramic Bowls should land under the same order as Pet Botanics"
      expect(litter_genie).to be_present, "Litter Genie should land under its OWN distinct order id, not the Pet Botanics one"

      # The bug we just fixed: the litter genie used to be stamped with 111-4536894 and then
      # the openAmz link opened the wrong order in the dashboard.
      expect(AmazonOrder.find("111-4536894-1373807", "B0FDLFSZ1S")).to be_nil
    end

    it "uses each sub-block's own date/time so siblings on different schedules aren't confused" do
      email = double(
        "Email",
        id:      50_734,
        to_html: html_fixture("email_body_50734", raw: true),
        subject: 'Ordered: "Litter Genie Easy Roll..." and 2 more items',
      )
      AmazonEmailParser.parse(email)

      pet_botanics = AmazonOrder.find("111-4536894-1373807", "B0144BMLFM")
      litter_genie = AmazonOrder.find("111-0441897-6436244", "B0FDLFSZ1S")

      expect(pet_botanics.delivery_date).to eq(Date.current.iso8601)        # "Arriving today"
      expect(pet_botanics.time_range).to eq("5-10PM")
      expect(litter_genie.delivery_date).not_to eq(pet_botanics.delivery_date)
      expect(litter_genie.time_range).to be_nil # "Arriving Tuesday" - no time range
    end
  end

  describe "Amazon re-IDs an item between Ordered and Shipped (consolidated shipments)" do
    # 50780 "Ordered: JUKMO Tactical Belt" -> order_id 114-1846143-1178640
    # 50789 "Shipped: JUKMO + 2 more"     -> order_id 111-5331586-9870663
    # Same physical ASIN B09BZP5YNT, two different Amazon order_ids in two different emails.
    it "merges the shipped row into the existing pending row, adopting the new order_id" do
      AmazonEmailParser.parse(double(
        "Email",
        id:      50_780,
        to_html: html_fixture("email_body_50780", raw: true),
        subject: 'Ordered: "JUKMO Tactical Belt,..."',
      ))
      AmazonEmailParser.parse(double(
        "Email",
        id:      50_789,
        to_html: html_fixture("email_body_50789", raw: true),
        subject: 'Shipped: "JUKMO Tactical Belt,..." and 2 more items',
      ))

      jukmo_rows = AmazonOrder.all.select { |o| o.item_id == "B09BZP5YNT" }
      expect(jukmo_rows.size).to eq(1), "expected a single JUKMO row, not one per email-claimed order_id"
      expect(jukmo_rows.first.order_id).to eq("111-5331586-9870663") # the latest (shipped) order_id wins
      expect(jukmo_rows.first.email_ids).to include(50_780, 50_789)
    end

    it "does NOT merge into a delivered row (preserve genuine re-orders months later)" do
      AmazonEmailParser.parse(double(
        "Email",
        id:      50_780,
        to_html: html_fixture("email_body_50780", raw: true),
        subject: 'Ordered: "JUKMO Tactical Belt,..."',
      ))
      AmazonOrder.find("114-1846143-1178640", "B09BZP5YNT").delivered = true

      AmazonEmailParser.parse(double(
        "Email",
        id:      50_789,
        to_html: html_fixture("email_body_50789", raw: true),
        subject: 'Shipped: "JUKMO Tactical Belt,..." and 2 more items',
      ))

      jukmo_rows = AmazonOrder.all.select { |o| o.item_id == "B09BZP5YNT" }
      expect(jukmo_rows.map(&:order_id)).to match_array(["114-1846143-1178640", "111-5331586-9870663"])
    end
  end

  describe "refund / cancellation / payment-declined emails" do
    it "refund email (50726) has no item card; parser flags it without creating items" do
      jarvis_calls = []
      allow(Jarvis).to receive(:cmd) { |msg| jarvis_calls << msg }
      parse(50_726, 'Advance refund issued for 5Aplusreprap Ender 3 Hotend... and 1 other item.')

      expect(AmazonOrder.all).to be_empty
      expect(jarvis_calls.last).to match(/50726/)
    end

    it "payment-declined email (50704) tags item with status=:declined" do
      parse(50_704, "Payment declined: Update your information so we can ship your order.")
      item = AmazonOrder.by_order("114-6012466-4997868").first
      expect(item.item_id).to eq("B0CHTKNWBL")
      expect(item.status).to eq(:declined)
      expect(item.errors).to be_none # status replaces the "couldn't parse date" error
    end

    it "item-cancelled email (50712) tags item with status=:cancelled" do
      parse(50_712, 'Item cancelled: "Amazon Gift Card Balance..."')
      item = AmazonOrder.by_order("114-6012466-4997868").first
      expect(item.status).to eq(:cancelled)
    end

    it "cancelled is sticky - a later shipped email does not clear it" do
      parse(50_712, 'Item cancelled: "Amazon Gift Card Balance..."')
      parse(50_704, "Shipped: \"Amazon Gift Card Balance Reload\"") # arbitrary normal subject
      item = AmazonOrder.by_order("114-6012466-4997868").first
      expect(item.status).to eq(:cancelled)
    end

    it "declined is cleared once a normal email arrives for the same item" do
      parse(50_704, "Payment declined: Update your information so we can ship your order.")
      parse(50_714, 'Shipped: "Strawberries, 1 Lb"') # different order, just ensures non-matching subject for declined item
      declined_item = AmazonOrder.by_order("114-6012466-4997868").first
      expect(declined_item.status).to eq(:declined) # other order's email doesn't touch this one

      # Now an actual normal email for the declined order should clear it
      parse_subject = 'Shipped: "Amazon Gift Card Balance Reload"'
      parse(50_704, parse_subject)
      expect(declined_item.status).to be_nil
    end
  end

  describe "AmazonOrder#destroy" do
    it "only removes the matching (order_id, item_id) pair" do
      keep    = AmazonOrder.create(order_id: "111-A", item_id: "B000T9YBT8", name: "Sprite in order A")
      destroy = AmazonOrder.create(order_id: "111-B", item_id: "B000T9YBT8", name: "Sprite in order B")
      destroy.destroy
      expect(AmazonOrder.find("111-A", "B000T9YBT8")).to eq(keep)
      expect(AmazonOrder.find("111-B", "B000T9YBT8")).to be_nil
    end
  end

  describe "idempotency and state transitions" do
    it "does not duplicate orders when same email is parsed twice" do
      c = CASES.find { |row| row[:id] == 50_684 }
      parse(c[:id], c[:subject])
      parse(c[:id], c[:subject])
      expect(AmazonOrder.by_order(c[:order]).map(&:item_id)).to match_array(c[:asins])
    end

    it "flips an existing shipped order to delivered when its delivery email arrives" do
      shipped = CASES.find { |row| row[:id] == 50_684 }
      delivered = CASES.find { |row| row[:id] == 50_687 }
      parse(shipped[:id], shipped[:subject])
      AmazonOrder.by_order(shipped[:order]).each { |item| expect(item.delivered).to be_falsey }

      parse(delivered[:id], delivered[:subject])
      AmazonOrder.by_order(delivered[:order]).each do |item|
        expect(item.delivered).to eq(true)
        expect(item.email_ids).to include(shipped[:id], delivered[:id])
      end
    end
  end
end
