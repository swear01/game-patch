"""Verify the completed native campaign and export a portable summary."""
import argparse
import json
from pathlib import Path
import re

from recover_route import read_run


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--steam-client-count", type=int, nargs=2, metavar=("UNLOCKED", "AVAILABLE"))
    args = parser.parse_args()
    export = json.loads(args.run.with_name("rooms.json").read_text(encoding="utf-8-sig"))
    rooms = {int(room["name"][-2:]): room for room in export["rooms"]
             if re.fullmatch("rm_level_[0-9]{2}", room["name"])}
    events = list(read_run(args.run))
    clears = [event for event in events if event["event"] == "clear"]
    assert [event["level"] for event in clears] == list(range(1, 32))
    assert events[-1]["event"] == "ending" and events[-1]["room"] == "rm_level_end"
    stages = []
    indexes = {"eng": set(), "jp": set()}
    for event in clears:
        level = event["level"]
        instances = rooms[level]["instances"]
        symbols = event["symbols"]
        assert set(map(int, symbols)) == {
            item["id"] for item in instances if item["name"] in ("obj_bonus_eng", "obj_bonus_jp")
        }
        for symbol in symbols.values():
            indexes[symbol["alphabet"]].add(symbol["index"])
        stages.append({"level": level, "keys_required_by_door": sum(item["name"] == "obj_key" for item in instances),
                       "native_symbol_pickups": list(symbols.values()),
                       "registered_steam_level_achievement_read": event["steam_achievement"] if level <= 30 else None})
    assert indexes["eng"] == set(range(1, 27)) and indexes["jp"] == set(range(1, 106))
    assert all(stage["registered_steam_level_achievement_read"] for stage in stages[:30])
    result = {"ending": "rm_level_end", "level_count": len(stages),
              "symbol_pickup_count": sum(len(stage["native_symbol_pickups"]) for stage in stages),
              "unique_japanese_symbols": len(indexes["jp"]), "unique_english_symbols": len(indexes["eng"]),
              "levels": stages}
    if args.steam_client_count:
        unlocked, available = args.steam_client_count
        result["steam_client_achievements"] = {"unlocked": unlocked, "available": available}
    assert result["symbol_pickup_count"] == 132
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Verified {len(stages)} native stage clears, 132 pickups, and rm_level_end.")


if __name__ == "__main__":
    main()
