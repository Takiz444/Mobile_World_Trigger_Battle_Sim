class_name TestUnits
extends RefCounted
## Fixed unit fixtures for the rules tests: four characters with standard
## stats (no talent points), so combat math (HP 100, ATK 5, AT 8) stays the
## same whatever the playable roster or default talents are.
##   0 melee (Kogetsu, Raygust)   1 shooter (Asteroid, Hound, Viper)
##   2 sniper (Egret, Ibis)       3 scout (Scorpion, Spider, Lead Bullet)


static func legacy() -> Array[UnitData]:
	var c := TriggerLibrary.sample_cards()
	var out: Array[UnitData] = []
	out.append(TriggerLibrary._make_unit("Attacker",
		[c["Kogetsu"], c["Raygust"], c["Asteroid"], c["Shield"]], [c["Shield"], c["Bagworm"]]))
	out.append(TriggerLibrary._make_unit("Shooter",
		[c["Asteroid"], c["Hound"], c["Shield"], c["Spider"]], [c["Shield"], c["Viper"]]))
	out.append(TriggerLibrary._make_unit("Sniper",
		[c["Egret"], c["Ibis"], c["Shield"], c["Bagworm"]], [c["Shield"], c["Grasshopper"]]))
	out.append(TriggerLibrary._make_unit("Scout",
		[c["Scorpion"], c["Spider"], c["Shield"], c["Bagworm"]], [c["Lead Bullet"], c["Grasshopper"]]))
	return out
