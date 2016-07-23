#!/usr/bin/python
import argparse
import logging
import time
import sys

import api
import location

import urllib
import urllib2

def setupLogger():
    logger = logging.getLogger()
    logger.setLevel(logging.INFO)
    ch = logging.StreamHandler()
    ch.setLevel(logging.DEBUG)
    formatter = logging.Formatter('Line %(lineno)d,%(filename)s  - %(asctime)s - %(levelname)s - %(message)s')
    ch.setFormatter(formatter)
    logger.addHandler(ch)


if __name__ == '__main__':
    setupLogger()
    logging.debug('Logger set up')

    parser = argparse.ArgumentParser()
    parser.add_argument("-a", "--auth", help="Auth Service", required=True)
    parser.add_argument("-u", "--username", help="Username", required=True)
    parser.add_argument("-p", "--password", help="Password", required=True)
    parser.add_argument("-l", "--location", help="Location", required=True)
    parser.add_argument("-s", "--client_secret", help="PTC Client Secret")
    args = parser.parse_args()

    if args.auth not in ['ptc', 'google']:
        logging.error('Invalid auth service {}'.format(args.auth))
        sys.exit(-1)

    if args.auth == 'ptc':
        session = api.createPTCSession(args.username, args.password, args.location)
    elif args.auth == 'google':
        session = api.createGoogleSession(args.username, args.password, args.location)

    if session: # do stuff

        # Get profile
        # logging.info("Printing Profile:")
        # profile = session.getProfile()
        # logging.info(profile)

        # Get Map details
        # logging.info("Printing Nearby Pokemon:")
        # closest = float("Inf")
        # pokemonBest = None
        latitude, longitude, _ = session.getLocation()
        from_location = "%f,%f"%(latitude,longitude)
        pokestr = ""
        # radius = [-1, 0, 1]
        radius = [-2, -1, 0, 1, 2]
        for x in radius:
            for y in radius:
                new_lat = latitude + (0.001 * x)
                new_lon = longitude + (0.001 * x)
                session.walkTo(new_lat, new_lon, 50, 40)
                # logging.info("Walk To: %f, %f"%(new_lat,new_lon))
                cells = session.getMapObjects()
                for cell in cells.map_cells:
                    for pokemon in cell.wild_pokemons:
                        pokemon_at_cell = "%i:%f,%f:%i|"%(pokemon.pokemon_data.pokemon_id,pokemon.latitude,pokemon.longitude,pokemon.time_till_hidden_ms)
                        logging.info(pokemon_at_cell)
                        pokestr += pokemon_at_cell
                # logging.info("%i at %f,%f"%(pokemon.pokemon_data.pokemon_id,pokemon.latitude,pokemon.longitude))
                # dist = location.getDistance(latitude, longitude, pokemon.latitude, pokemon.longitude)
                # if dist < closest:
                #     pokemonBest = pokemon

        url = 'http://localhost:3141/pokemon'
        values = {'nearby' : pokestr, 'from' : from_location}
        data = urllib.urlencode(values)
        req = urllib2.Request(url, data)
        response = urllib2.urlopen(req)

        # the_page = response.read()
        # if pokemonBest:
        #     logging.info("Catching nearest pokemon:")
        #     session.walkTo(pokemonBest.latitude, pokemonBest.longitude)
        #     logging.info(session.encounterAndCatch(pokemonBest))

        # Do Inventory stuff
        # logging.info("Get Inventory")
        # logging.info(session.getInventory())

        # Find nearest fort (pokestop)
        # logging.info("Spinnning Nearest Fort")
        # closest = float("Inf")
        # fortBest = None
        # latitude, longitude, _ = session.getLocation()
        # for cell in cells.map_cells:
        #     for fort in cell.forts:
        #         dist = location.getDistance(latitude, longitude, fort.latitude, fort.longitude)
        #         if dist < closest and fort.type == 1:
        #             closest = dist
        #             fortBest = fort

        # No fort, demo == over
        # if fortBest:
        #     # Walk over
        #     session.walkTo(fortBest.latitude, fortBest.longitude)
        #     # Give it a spin
        #     fortResponse = session.getFortSearch(fortBest)
        #     logging.info(fortResponse)

    else:
        logging.critical('Session not created successfully')

logging.info('Complete')
