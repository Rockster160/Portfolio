class ConvertJarvisPages < ActiveRecord::Migration[7.0]
  def up
    JarvisPage.find_each do |page|
      page.update(blocks:
        page.blocks.map { |widget|
          widget[:type] ||= :buttons
          widget[:buttons] ||= widget.delete(:blocks)
        }
      )
    end
  end
end
