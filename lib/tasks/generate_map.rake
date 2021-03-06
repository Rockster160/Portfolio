namespace :generate do
  task :map do
    # N=NW
    # n=N
    # E=NE
    # e=E
    # S=SE
    # s=S
    # W=SW
    # w=W
    # 1=grass-1
    # 2=grass-2
    # 3=grass-3
    # 4=grass-4
    @max = 63
    def generateGrass(x, y)
      return "N" if x == 0 && y == 0
      return "E" if x == @max && y == 0
      return "S" if x == @max && y == @max
      return "W" if x == 0 && y == @max
      return "n" if y == 0
      return "e" if x == @max
      return "s" if y == @max
      return "w" if x == 0
      rand_block = rand(15)
      return "1" if rand_block <= 5
      return "2" if rand_block <= 9
      return "3" if rand_block <= 12
      return "4" if rand_block <= 14
    end

    grass = 64.times.map do |y|
      64.times.map do |x|
        generateGrass(x, y)
      end.join("")
    end.join(",")

    spikes = collision = 64.times.map do |y|
      64.times.map do |x|
        next "0" if x == 0 || y == 0 || x == @max || y == @max
        rand(15) == 0 ? "1" : "0"
      end.join("")
    end.join(",")

    collision = spikes

    File.write("lib/assets/little_world_map.map", [grass, spikes, collision].join("\n"))
  end
end
