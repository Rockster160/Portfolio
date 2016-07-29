module CoordCalculator

  def distance_between(loc1, loc2)
    loc1, loc2 = loc1.map(&:to_f), loc2.map(&:to_f)
    rad_per_deg = Math::PI/180
    rkm = 6371                  # Earth radius in kilometers
    rm = rkm * 1000             # Radius in meters

    dlat_rad = (loc2[0]-loc1[0]) * rad_per_deg  # Delta, converted to rad
    dlng_rad = (loc2[1]-loc1[1]) * rad_per_deg

    lat1_rad, lng1_rad = loc1.map {|i| i * rad_per_deg }
    lat2_rad, lng2_rad = loc2.map {|i| i * rad_per_deg }

    a = Math.sin(dlat_rad/2)**2 + Math.cos(lat1_rad) * Math.cos(lat2_rad) * Math.sin(dlng_rad/2)**2
    c = 2 * Math::atan2(Math::sqrt(a), Math::sqrt(1-a))

    meters = rm * c
    feet = meters * 3.28084
  end

  def directions(from_loc, to_loc)
    calc_cardinal_direction(from_loc, to_loc)
  end

  def bearing(from_loc, to_loc)
    brng = calc_bearing(from_loc, to_loc)
    dist = distance_between(from_loc, location)
    "#{brng.round(2)}º #{dist.round(2)}ft"
  end

  def calc_cardinal_direction(from_loc, to_loc)
    from_lat, from_lng = from_loc
    to_lat, to_lng = to_loc
    # N = + Lat
    # E = + Lng
    # S = - Lat
    # W = - Lng
    lat_distance = distance_between([from_lat, from_lng], [to_lat, from_lng])
    lng_distance = distance_between([from_lat, from_lng], [from_lat, to_lng])
    lat_cardinal_direction = from_lat < to_lat ? 'N' : 'S'
    lng_cardinal_direction = from_lng < to_lng ? 'E' : 'W'
    lat_distance_str = "#{lat_distance.round(2)}ft #{lat_cardinal_direction}"
    lng_distance_str = "#{lng_distance.round(2)}ft #{lng_cardinal_direction}"
    [lat_distance_str, lng_distance_str].join(', ')
  end

  def calc_bearing(from_loc, to_loc)
    from_lat, from_lng = from_loc
    to_lat, to_lng = to_loc
    delta_lng = (from_lng - to_lng)

    y = Math.sin(delta_lng) * Math.cos(to_lat)
    x = Math.cos(from_lat) * Math.sin(to_lat) - Math.sin(from_lat) * Math.cos(to_lat) * Math.cos(delta_lng)

    brng = Math.atan2(y, x)

    brng = to_deg(brng)
    brng = (brng + 360) % 360
    brng = 360 - brng

    return brng# º
  end

  def to_deg(rad)
    (180 / Math::PI) * rad
  end
  def to_rad(ang)
    (ang/180) * Math::PI
  end

end
