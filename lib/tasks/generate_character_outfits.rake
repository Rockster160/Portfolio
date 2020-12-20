namespace :outfits do
  task :generate do
    images = Dir.glob("../Portfolio/app/assets/images/rpg/**/*.png")
    permitted = {}
    images.each do |img_path|
      tree = img_path.gsub("../Portfolio/app/assets/images/rpg/", "").gsub(".png", "").split("/")
      current_tree = permitted
      tree.each_with_index do |branch, idx|
        if idx == tree.length - 1
          current_tree << branch
          current_tree.uniq!
        elsif idx == tree.length - 2
          current_tree[branch.to_sym] ||= []
          current_tree = current_tree[branch.to_sym]
        else
          current_tree[branch.to_sym] ||= {}
          current_tree = current_tree[branch.to_sym]
        end
      end
    end
    formatted = pp(permitted.to_json)
    File.write("lib/assets/valid_character_outfits.rb", formatted)
  end
end
