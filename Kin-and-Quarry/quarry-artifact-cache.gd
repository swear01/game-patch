extends RefCounted

const RARITIES := ["extraordinary", "rare", "uncommon", "common"]
const MISC_RATES := [0.08, 0.3, 0.9, 2.4]
const LAST_LAYER := 14

var ranges: Dictionary = {}
var _candidates: Dictionary = {}
var _pool: Array

func setup(definitions: Dictionary, collection: Dictionary, drop_rates: Dictionary, misc_minima: Dictionary, pool: Array) -> bool:
	# The caller owns an uninterrupted rebuild. This Array is the actual
	# game pool, so selected artifacts are removed from it in stock order.
	_pool = pool
	var available := {}
	for artifact in pool:
		if available.has(artifact):
			return false
		available[artifact] = true
	var seen_ids := {}
	for material in definitions:
		var miscellaneous: bool = material == "miscellaneous"
		var owned_amount := 0.0
		if collection.has(material):
			owned_amount = float(collection[material]["amount"])
		var divisor := 100000 if miscellaneous else 1000
		var bonus := 1.8
		match material:
			"miscellaneous": bonus = 0.002
			"tin": bonus = 5.0
			"copper": bonus = 7.0
			"zinc": bonus = 6.0
		var forgiveness := 1.0 + int(owned_amount / divisor) * bonus
		var bounds := PackedFloat64Array([0.0])
		var cumulative := 0.0
		var material_rarities: Dictionary = definitions[material]
		var ranked: Array = []
		for rank in RARITIES.size():
			var rarity: String = RARITIES[rank]
			var rate: float = MISC_RATES[rank] if miscellaneous else drop_rates[rarity]
			cumulative += rate * forgiveness
			bounds.append(cumulative)
			var choices: Array = []
			if miscellaneous:
				for layer in range(LAST_LAYER + 1):
					choices.append([])
			var entries: Dictionary = material_rarities.get(rarity, {})
			for artifact in entries:
				# Stock erases the first occurrence globally. Reject ambiguous
				# IDs rather than assuming which material would claim a duplicate.
				if seen_ids.has(artifact):
					return false
				seen_ids[artifact] = true
				if not available.has(artifact) or entries[artifact]["owned"]:
					continue
				if miscellaneous:
					var minima: Dictionary = misc_minima[rarity]
					if not minima.has(artifact) or not (minima[artifact] is int):
						return false
					for layer in range(maxi(0, minima[artifact]), LAST_LAYER + 1):
						choices[layer].append(artifact)
				else:
					choices.append(artifact)
			ranked.append(choices)
		ranges[material] = bounds
		_candidates[material] = ranked
	return true

func choose(material: String, layer: int, bounds: PackedFloat64Array) -> Variant:
	# Always draw for supported materials, including exhausted pools. Match
	# the exact cumulative ranges before applying stock lower-rarity fallback.
	var chance := randf_range(0.0, 100.0)
	var start := -1
	for rank in RARITIES.size():
		if chance >= bounds[rank] and chance < bounds[rank + 1]:
			start = rank
			break
	if start < 0:
		return null
	var ranks: Array = _candidates[material]
	var miscellaneous := material == "miscellaneous"
	for rank in range(start, RARITIES.size()):
		var choices: Array = ranks[rank][clampi(layer, 0, LAST_LAYER)] if miscellaneous else ranks[rank]
		if choices.is_empty():
			continue
		var artifact: String = choices.pick_random()
		_pool.erase(artifact)
		if miscellaneous:
			for layer_choices: Array in ranks[rank]:
				layer_choices.erase(artifact)
		else:
			choices.erase(artifact)
		return [artifact, rank]
	return null
