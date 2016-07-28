module CoordCalculator

  def distance_between(loc1, loc2)
    loc1, loc2 = loc1.map(&:to_f), loc2.map(&:to_f)
    rad_per_deg = Math::PI/180
    rkm = 6371                  # Earth radius in kilometers
    rm = rkm * 1000             # Radius in meters

    dlat_rad = (loc2[0]-loc1[0]) * rad_per_deg  # Delta, converted to rad
    dlon_rad = (loc2[1]-loc1[1]) * rad_per_deg

    lat1_rad, lon1_rad = loc1.map {|i| i * rad_per_deg }
    lat2_rad, lon2_rad = loc2.map {|i| i * rad_per_deg }

    a = Math.sin(dlat_rad/2)**2 + Math.cos(lat1_rad) * Math.cos(lat2_rad) * Math.sin(dlon_rad/2)**2
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
    from_lat, from_lon = from_loc
    to_lat, to_lon = to_loc
    # N = + Lat
    # E = + Lon
    # S = - Lat
    # W = - Lon
    lat_distance = distance_between([from_lat, from_lon], [to_lat, from_lon])
    lon_distance = distance_between([from_lat, from_lon], [from_lat, to_lon])
    lat_cardinal_direction = from_lat < to_lat ? 'N' : 'S'
    lon_cardinal_direction = from_lon < to_lon ? 'E' : 'W'
    lat_distance_str = "#{lat_distance.round(2)}ft #{lat_cardinal_direction}"
    lon_distance_str = "#{lon_distance.round(2)}ft #{lon_cardinal_direction}"
    [lat_distance_str, lon_distance_str].join(', ')
  end

  def calc_bearing(from_loc, to_loc)
    from_lat, from_lon = from_loc
    to_lat, to_lon = to_loc
    delta_lon = (from_lon - to_lon)

    y = Math.sin(delta_lon) * Math.cos(to_lat)
    x = Math.cos(from_lat) * Math.sin(to_lat) - Math.sin(from_lat) * Math.cos(to_lat) * Math.cos(delta_lon)

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
