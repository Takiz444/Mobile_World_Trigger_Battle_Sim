class_name CityLayout
extends RefCounted
## The city a match is played in: the play area and every box and no-walk
## zone in it. Built from a Tokyo district section (TokyoMap.layout) and
## shared, read-only, by every MatchState on that section.

var bounds := Rect2()            # the zone's bounding box
## The play area itself: a polygon following the streets (CCW).
var zone := PackedVector2Array()
var buildings: Array = []    # CityBox BUILDING
var solids: Array = []       # CityBox SOLID
var decks: Array = []        # CityBox DECK
var blocked: BlockedMask
## The district this section comes from (the renderer draws the rest of it
## around the play area), and the section itself ({district, rect}).
var district: TokyoDistrict
var section: Dictionary = {}
