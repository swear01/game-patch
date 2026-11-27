#include <YYToolkit/YYTK_Shared.hpp>
#include "json.hpp"

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <intrin.h>
#include <map>
#include <set>
#include <stdexcept>
#include <string_view>

namespace YYTK
{
// The variable descriptor layout from the matching Zeus SDK's internal Tool.hpp.
using VariableGetter = bool(*)(CInstance*, int, RValue*);
struct RVariableRoutine
{
    const char* name;
    VariableGetter getter;
    VariableGetter setter;
    bool canSet;
};
static_assert(sizeof(RVariableRoutine) == 32);
}
using namespace Aurie;
using namespace YYTK;
using Json = nlohmann::json;
using Clock = std::chrono::steady_clock;

namespace
{
YYTKInterface* game = nullptr;
std::filesystem::path mailbox;
CInstance* input = nullptr;
std::set<std::string, std::less<>> inputFields;
std::set<std::string> observedEvents;
std::set<std::string> menuButtons;
std::string continueId;
std::uint64_t continueDeadlineFrame = 0;
Json sceneObserved = Json::object();
std::map<std::string, Json> activeInput;
std::string room;
std::string inputError;
Clock::time_point nextSnapshot{};
std::uint64_t frame = 0;
std::uint64_t inputEvents = 0;
std::uint64_t appliedInputFrames = 0;
int framesLeft = 0;
int inputLength = 0;
TRoutine originalKeyPressed = nullptr;
std::uint64_t nativeReturnFrame = 0;
std::uint64_t nativeReturnReads = 0;
TRoutine originalGuiX = nullptr;
TRoutine originalGuiY = nullptr;
TRoutine originalMouseDown = nullptr;
TRoutine originalMousePressed = nullptr;
TRoutine originalMouseReleased = nullptr;
VariableGetter originalWorldX = nullptr;
VariableGetter originalWorldY = nullptr;
std::uint64_t pointerPositionReads = 0;
std::uint64_t pointerButtonReads = 0;

// This Windows monotonic clock is independent of the game's configured clock multiplier.
std::uint64_t WallTicks()
{
    ULONGLONG ticks = 0;
    QueryUnbiasedInterruptTime(&ticks);
    return ticks;
}

#include "ShelldiverPresentCadence.hpp"

std::uint64_t lastSnapshotTicks = 0;
std::uint64_t lastSnapshotFrame = 0;
std::uint64_t snapshotCount = 0;
std::uint64_t inputDrawEvents = 0;
std::atomic_uint64_t nonTestPresentCalls{0};
std::uint64_t snapshotCycles = 0;
std::uint64_t sceneCycles = 0;
std::uint64_t controlCycles = 0;
bool measureBridge = false;
bool measureNativeVisual = false;

struct EventCycles
{
    std::uint64_t calls = 0;
    std::uint64_t cycles = 0;
};
EventCycles oceanDrawProfile, lightDrawProfile, coralStepProfile;

EventCycles* NativeVisualProfile(std::string_view name)
{
    if (!measureNativeVisual) return nullptr;
    if (name == "gml_Object_o_visual_setup_Draw_73") return &oceanDrawProfile;
    if (name == "gml_Object_o_light_control_Draw_0") return &lightDrawProfile;
    if (name == "gml_Object_par_bubble_coral_Step_0") return &coralStepProfile;
    return nullptr;
}

struct SampleThreadCycles
{
    std::uint64_t& total;
    ULONGLONG started = 0;
    explicit SampleThreadCycles(std::uint64_t& accumulator, bool enabled = measureBridge) : total(accumulator)
    {
        if (enabled) QueryThreadCycleTime(GetCurrentThread(), &started);
    }
    ~SampleThreadCycles()
    {
        ULONGLONG ended = 0;
        if (started && QueryThreadCycleTime(GetCurrentThread(), &ended) && ended >= started)
            total += ended - started;
    }
};

// Observe a single real bubble in world coordinates; no projectile fields are written.
CInstance* flightInstance = nullptr;
std::uint64_t nextFlightFrame = 0;
std::uint64_t flightStartFrame = 0;
std::uint64_t flightLastFrame = 0;
std::uint64_t flightStartTicks = 0;
double flightX = 0, flightY = 0, flightLength = 0;
Json recentFlight = nullptr;

void ObserveBubbleFlight(CInstance* self, bool created)
{
    if (!measureBridge || !self) return;
    if (created)
    {
        if (frame < nextFlightFrame) return;
        flightInstance = self;
        flightStartFrame = 0;
        nextFlightFrame = frame + 90;
        return;
    }
    if (self != flightInstance || (flightStartFrame && flightLastFrame == frame)) return;
    RValue x, y;
    if (!AurieSuccess(game->GetBuiltin("x", self, NULL_INDEX, x)) ||
        !AurieSuccess(game->GetBuiltin("y", self, NULL_INDEX, y))) return;
    const double px = x.ToDouble(), py = y.ToDouble();
    if (!flightStartFrame || frame != flightLastFrame + 1)
    {
        flightStartFrame = frame;
        flightStartTicks = WallTicks();
        flightLength = 0;
    }
    else flightLength += std::hypot(px-flightX, py-flightY);
    flightX = px;
    flightY = py;
    flightLastFrame = frame;
    if (frame >= flightStartFrame + 16)
    {
        const auto elapsed = WallTicks() - flightStartTicks;
        if (elapsed && flightLength > 1)
            recentFlight = {{"startFrame",flightStartFrame},{"endFrame",frame},{"worldPixels",flightLength},
                            {"realSeconds",elapsed / 10000000.0},{"steps", frame-flightStartFrame}};
        flightInstance = nullptr;
    }
}

struct GuiPointer
{
    double guiX = 0;
    double guiY = 0;
    double worldX = 0;
    double worldY = 0;
    std::uint64_t press = 0;
    std::uint64_t release = 0;
    std::uint64_t expire = 0;
    int button = 1;

    bool Active() const { return expire && frame <= expire; }
};
GuiPointer pointer;

struct UnderwaterTarget
{
    double x;
    double y;
    std::uint64_t observedFrame;
    bool resource;
    std::uint64_t track = 0;
    double life = -1;
    double lifeMax = -1;
    bool hasLife = false;
    bool immune = false;
    bool exploding = false;
    double distanceSquared = 0;
};
std::uint64_t nextTargetTrack = 0;
std::map<CInstance*, UnderwaterTarget> targets;

const std::set<std::string, std::less<>> allowedInputs{
    "up", "down", "left", "right", "jump", "interact", "interact_hold",
    "use_bubble_gun", "use_plasma_gun", "reload_tool", "open_inventory",
    "open_skilltree", "pause", "back", "ui_back", "enter", "enter_pressed", "enter_released", "start",
    "up_menu", "down_menu", "left_menu", "right_menu", "up_menu_pressed",
    "down_menu_pressed", "left_menu_pressed", "right_menu_pressed",
    "jl_horizontal", "jl_vertical", "jr_horizontal", "jr_vertical",
    "zoom_in", "zoom_out", "is_moving_any", "is_moving_horizontal"
};
const std::array<std::pair<const char*, const char*>, 13> sceneObjects{{
    {"player", "o_turtle_player"}, {"submarineTravel", "o_submarine_travel"},
    {"submarineLeave", "o_submarine_leave"}, {"shop", "o_jellyfish_store"},
    {"chest", "o_store_chest"}, {"upgradeArea", "o_upgrade_area"},
    {"hammock", "o_hammock"}, {"alchemyStation", "o_alchemy_station"}, {"alchemyChest", "o_alchemy_chest"},
    {"menu", "o_menu"}, {"submarineStorage", "o_submarine_storage"},
    {"bubbleGun", "o_bubble_gun"}, {"plasmaGun", "o_plasma_gun"}
}};
const std::array globalNumbers{
    "shell_coins", "store_shell_coins", "alchemy_shell_coins", "store_flask_coins", "scrap_coins", "crystal_coins",
    "mushroom_coins", "obsidian_coins", "flask_coins", "total_skill_levels_upgraded",
    "all_skill_levels", "last_biome_visited", "cam_x", "cam_y", "skill_ui_xoffset", "skill_ui_yoffset",
    "scrap_collected", "bubble_ammo", "plasma_ammo", "submarine_leave_x", "submarine_leave_y"
};
const std::array globalFlags{
    "pause", "hammock_available", "alchemy_station_available", "in_cutscene", "is_on_final_cutscene", "has_revealed_hammock", "has_played_hammock_cutscene",
    "submarine_storage_available", "is_plasma_tool_available", "shellphone_unlocked",
    "files_loaded", "is_tutorial_finished", "xbox_loading_user", "transitioning",
    "is_inventory_full", "player_inventory_open", "player_has_jellyfish_to_store", "player_has_jellyfish_to_take"
};
const std::array playerFields{
    "oxygen", "oxygen_max", "hsp", "vsp", "bubble_ammo", "plasma_ammo", "bubbles", "bubbles_max", "new_fish_bubble_amount",
    "aim_dir", "aim_guide_dir", "aim_force", "is_inventory_full", "inventory_full", "oxygen_real", "tool_use_index",
    "tool_use_timer", "tool_use_dir", "can_use_tool", "interact_available"
};

const std::array submarineFields{
    "range", "interact_available", "interact_on_hold", "can_be_used",
    "player_is_close_by", "can_interact", "submarine_leave_x", "submarine_leave_y",
    "submarine_xoffset", "submarine_yoffset", "current_page", "selected"
};
const std::array weaponFields{
    "ammo", "ammo_amount", "ammo_amount_max", "ammo_amount_saved", "ammo_before_reloading",
    "ammo_to_spend", "can_use_tool", "reload", "tool_use_timer", "tool_use_index",
    "current_ammo_number", "is_selected", "is_firing_laser", "firing_laser_progress",
    "delay_fire_rate", "total_fire_rate"
};
std::uint64_t bubbleProjectiles = 0;
std::uint64_t plasmaProjectiles = 0;
std::filesystem::path EnvironmentPath(const wchar_t* name)
{
    DWORD length = GetEnvironmentVariableW(name, nullptr, 0);
    if (!length)
        throw std::runtime_error("The game process is missing its user profile directory.");
    std::wstring path(length, L'\0');
    DWORD copied = GetEnvironmentVariableW(name, path.data(), length);
    if (!copied || copied >= length)
        throw std::runtime_error("The game process could not resolve its user profile directory.");
    path.resize(copied);
    return std::filesystem::path(path);
}

void WriteJson(const wchar_t* filename, const Json& value)
{
    auto destination = mailbox / filename;
    auto temporary = destination;
    temporary += L".pending";
    {
        std::ofstream output(temporary, std::ios::binary | std::ios::trunc);
        output.exceptions(std::ios::badbit | std::ios::failbit);
        output << value.dump();
    }
    if (!MoveFileExW(temporary.c_str(), destination.c_str(), MOVEFILE_REPLACE_EXISTING))
        throw std::runtime_error("Could not publish the game mailbox response.");
}

std::string UtcNow()
{
    SYSTEMTIME utc{};
    GetSystemTime(&utc);
    char text[32]{};
    std::snprintf(text, sizeof(text), "%04u-%02u-%02uT%02u:%02u:%02u.%03uZ",
                  unsigned(utc.wYear), unsigned(utc.wMonth), unsigned(utc.wDay),
                  unsigned(utc.wHour), unsigned(utc.wMinute), unsigned(utc.wSecond),
                  unsigned(utc.wMilliseconds));
    return text;
}

RValue* TryMember(CInstance* object, const char* name)
{
    RValue* value = nullptr;
    if (object != nullptr && AurieSuccess(game->GetInstanceMember(RValue(object), name, value)))
        return value;
    return nullptr;
}

RValue* TryStructMember(const RValue* object, const char* name)
{
    RValue* value = nullptr;
    if (object && object->m_Kind == VALUE_OBJECT &&
        AurieSuccess(game->GetInstanceMember(*object, name, value)))
        return value;
    return nullptr;
}

void AddNumber(Json& object, const char* key, const RValue& value)
{
    switch (value.m_Kind)
    {
    case VALUE_REAL:
    case VALUE_INT32:
    case VALUE_INT64:
    case VALUE_BOOL:
        if (auto number = value.ToDouble(); std::isfinite(number))
            object[key] = number;
        break;
    default:
        break;
    }
}

std::string CurrentRoom(CInstance* global)
{
    RValue roomIndex;
    if (!global || !AurieSuccess(game->GetBuiltin("room", global, NULL_INDEX, roomIndex)))
        return room;
    auto roomName = game->CallBuiltin("room_get_name", {roomIndex});
    return roomName.m_Kind == VALUE_STRING ? roomName.ToString() : room;
}

Json ReadMenuValue(RValue& value, bool includeArray)
{
    if (value.m_Kind == VALUE_BOOL)
        return value.ToBoolean();
    if (value.m_Kind == VALUE_STRING)
        return value.ToString();
    if (value.m_Kind == VALUE_INT32 || value.m_Kind == VALUE_INT64 || value.m_Kind == VALUE_REAL)
    {
        const double number = value.ToDouble();
        return std::isfinite(number) ? Json(number) : Json(nullptr);
    }
    if (value.m_Kind == VALUE_ARRAY && includeArray)
    {
        Json entries = Json::array();
        size_t size = 0;
        if (AurieSuccess(game->GetArraySize(value, size)))
        {
            for (size_t index = 0; index < size && index < 12; ++index)
            {
                RValue* entry = nullptr;
                if (AurieSuccess(game->GetArrayEntry(value, index, entry)) && entry)
                    entries.push_back(ReadMenuValue(*entry, false));
            }
        }
        return entries;
    }
    return nullptr;
}

Json ReadMenu(CInstance* global, const char* name = "main_menu")
{
    Json result = Json::object();
    if (auto* menu = TryMember(global, name); menu && menu->m_Kind == VALUE_OBJECT)
    {
        game->EnumInstanceMembers(*menu, [&](const char* key, RValue* value)
        {
            if (key && value && result.size() < 36)
            {
                auto field = ReadMenuValue(*value, true);
                result[key] = field.is_null() ? Json(value->GetKindName()) : std::move(field);
            }
            return true;
        });
    }
    return result;
}

void CaptureUnderwaterTarget(std::string_view eventName, CInstance* self)
{
    if (!self || !room.starts_with("rm_ocean_"))
        return;
    const bool resource = eventName == "gml_Object_par_resource_block_Step_0";
    if (!resource && eventName != "gml_Object_par_jellyfish_Step_0")
        return;

    RValue x;
    RValue y;
    if (AurieSuccess(game->GetBuiltin("x", self, NULL_INDEX, x)) &&
        AurieSuccess(game->GetBuiltin("y", self, NULL_INDEX, y)))
    {
        const auto px = x.ToDouble(), py = y.ToDouble();
        auto& target = targets[self];
        // A recycled instance or a stock room wrap begins a fresh pursuit.
        if (!target.track || frame-target.observedFrame > 30 || target.resource != resource ||
            std::abs(px-target.x) > 120 || std::abs(py-target.y) > 120)
            target.track = ++nextTargetTrack;
        target.x = px;
        target.y = py;
        target.observedFrame = frame;
        target.resource = resource;
        if (!resource)
        {
            auto readLife = [&](const char* key) {
                auto* value = TryMember(self, key);
                if (!value || (value->m_Kind != VALUE_REAL && value->m_Kind != VALUE_INT32 &&
                               value->m_Kind != VALUE_INT64)) return -1.0;
                return value->ToDouble();
            };
            auto flag = [&](const char* key) {
                auto* value = TryMember(self, key);
                return value && (value->m_Kind == VALUE_BOOL || value->m_Kind == VALUE_REAL ||
                                 value->m_Kind == VALUE_INT32 || value->m_Kind == VALUE_INT64) && value->ToBoolean();
            };
            const auto* life = TryMember(self, "life");
            target.hasLife = life && (life->m_Kind == VALUE_REAL || life->m_Kind == VALUE_INT32 || life->m_Kind == VALUE_INT64);
            target.life = target.hasLife ? std::max(0.0,life->ToDouble()) : -1.0;
            target.lifeMax = readLife("life_max");
            target.immune = flag("invulnerable");
            target.exploding = flag("explosion");
        }
    }
}

Json ReadUnderwaterTargets()
{
    if (!room.starts_with("rm_ocean_"))
    {
        targets.clear();
        return Json::object();
    }

    std::erase_if(targets, [](const auto& entry) {
        return frame - entry.second.observedFrame > 30;
    });
    const auto player = sceneObserved.value("player", Json::object());
    const double playerX = player.value("x", 0.0);
    const double playerY = player.value("y", 0.0);
    std::vector<UnderwaterTarget> ordered;
    ordered.reserve(targets.size());
    for (const auto& [object, target] : targets)
    {
        if (!std::isfinite(target.x) || !std::isfinite(target.y)) continue;
        auto& item = ordered.emplace_back(target);
        const double dx=item.x-playerX, dy=item.y-playerY;
        item.distanceSquared = dx*dx + dy*dy;
    }
    std::sort(ordered.begin(), ordered.end(), [](const auto& left, const auto& right) {
        return left.distanceSquared < right.distanceSquared;
    });
    Json jellyfish = Json::array();
    Json resources = Json::array();
    for (const auto& target : ordered)
    {
        auto& list = target.resource ? resources : jellyfish;
        if (list.size() >= 24) continue;
        Json info={{"x", target.x}, {"y", target.y}, {"distance", std::sqrt(target.distanceSquared)},
                   {"track", target.track}, {"observedFrame", target.observedFrame}};
        if (!target.resource && target.hasLife && target.lifeMax > 0)
        {
            info["invulnerable"] = target.immune;
            info["explosion"] = target.exploding;
            info["life"] = target.life;
            info["lifeMax"] = target.lifeMax;
        }
        list.push_back(std::move(info));
    }
    return {{"jellyfish", jellyfish}, {"resources", resources}};
}

Json ReadInventory(CInstance* global, const char* name)
{
    auto* all = TryMember(global, "_all_inventories");
    auto* inventory = TryStructMember(all, name);
    if (!inventory)
        inventory = TryMember(global, name);
    auto* slots = TryStructMember(inventory, "slots");
    size_t count = 0;
    if (!slots || slots->m_Kind != VALUE_ARRAY || !AurieSuccess(game->GetArraySize(*slots, count)))
        return nullptr;

    Json result = {{"slotCount", count}, {"slots", Json::array()}};
    if (auto* capacity = TryStructMember(inventory, "slot_capacity"))
        AddNumber(result, "slotCapacity", *capacity);
    double total = 0;
    double jellyfish = 0;
    for (size_t index = 0; index < count && index < 48; ++index)
    {
        RValue* slot = nullptr;
        if (!AurieSuccess(game->GetArrayEntry(*slots, index, slot)) || !slot)
            continue;
        auto* quantity = TryStructMember(slot, "quantity");
        if (!quantity)
            continue;
        Json item = {{"index", index}};
        AddNumber(item, "quantity", *quantity);
        double amount = item.value("quantity", 0.0);
        if (amount <= 0)
            continue;

        for (auto key : {"id", "type"})
            if (auto* field = TryStructMember(slot, key))
                AddNumber(item, key, *field);
        total += amount;
        if (item.value("type", -1.0) == 0.0)
            jellyfish += amount;
        result["slots"].push_back(std::move(item));
    }
    result["total"] = total;
    result["jellyfish"] = jellyfish;
    return result;
}

#include "ShelldiverSkillTelemetry.hpp"

void CaptureScene(std::string_view eventName, CInstance* self)
{
    if (!self)
        return;

    const char* label = nullptr;
    if (eventName == "gml_Object_o_menu_Step_1")
        label = "menu";
    else if (eventName == "gml_Object_par_player_Step_0")
        label = "player";
    else if (eventName == "gml_Object_o_submarine_leave_Step_0")
        label = "submarineLeave";
    else if (eventName == "gml_Object_o_submarine_travel_Step_0")
        label = "submarineTravel";
    else if (eventName == "gml_Object_o_submarine_storage_Step_0")
        label = "submarineStorage";
    else if (eventName == "gml_Object_o_upgrade_area_Draw_64")
        label = "upgradeArea";
    else if (eventName == "gml_Object_o_bubble_gun_Step_2")
        label = "bubbleGun";
    else if (eventName == "gml_Object_o_plasma_gun_Step_2")
        label = "plasmaGun";
    else if (eventName.ends_with("_Create_0"))
    {
        for (auto [name, asset] : sceneObjects)
        {
            if (eventName == std::string("gml_Object_") + asset + "_Create_0")
            {
                label = name;
                break;
            }
        }
    }
    if (!label)
        return;

    Json entry = Json::object();
    for (auto key : {"x", "y", "id"})
    {
        RValue value;
        if (AurieSuccess(game->GetBuiltin(key, self, NULL_INDEX, value)))
            AddNumber(entry, key, value);
    }
    if (std::string_view(label) == "player")
    {
        for (auto key : playerFields)
            if (auto* value = TryMember(self, key))
                AddNumber(entry, key, *value);
    }
    const std::string_view entity(label);
    if (entity.starts_with("submarine"))
    {
        for (auto key : {"xstart", "ystart", "bbox_left", "bbox_right", "bbox_top", "bbox_bottom",
                         "image_xscale", "image_yscale", "sprite_width", "sprite_height"})
        {
            RValue value;
            if (AurieSuccess(game->GetBuiltin(key, self, NULL_INDEX, value)))
                AddNumber(entry, key, value);
        }
        for (auto key : submarineFields)
        {
            if (auto* value = TryMember(self, key))
            {
                auto field = ReadMenuValue(*value, false);
                if (!field.is_null())
                    entry[key] = std::move(field);
                else if (std::string_view(key) == "can_interact")
                    entry["can_interactKind"] = value->GetKindName();
            }
        }
    }
    if (entity == "upgradeArea")
        for (auto key : {"ui_xoffset", "ui_yoffset", "ui_zoom_factor", "ui_xoffset_increment", "ui_yoffset_increment"})
            if (auto* value = TryMember(self, key))
                AddNumber(entry, key, *value);

    if (entity == "bubbleGun" || entity == "plasmaGun")
        for (auto key : weaponFields)
            if (auto* value = TryMember(self, key))
                AddNumber(entry, key, *value);

    entry["frame"] = frame;
    entry["event"] = eventName;
    sceneObserved[label] = std::move(entry);
}

Json ReadScene()
{
    Json scene = sceneObserved;
    if (room.starts_with("rm_ocean_"))
        for (auto key : {"submarineTravel", "shop", "chest", "hammock", "alchemyStation", "alchemyChest", "upgradeArea"})
            scene.erase(key);
    else
        for (auto key : {"submarineLeave", "bubbleGun", "plasmaGun"})
            scene.erase(key);

    const auto player = scene.value("player", Json::object());
    if (player.contains("x") && player.contains("y"))
    {
        for (auto key : {"submarineTravel", "submarineLeave", "submarineStorage"})
        {
            auto item = scene.find(key);
            if (item != scene.end() && item->contains("x") && item->contains("y"))
            {
                const auto dx = player.at("x").get<double>() - item->at("x").get<double>();
                const auto dy = player.at("y").get<double>() - item->at("y").get<double>();
                (*item)["distanceToPlayer"] = std::hypot(dx, dy);
            }
        }
    }
    return scene;
}

Json ReadInput()
{
    Json values = Json::object();
    for (const auto& key : inputFields)
    {
        if (auto* value = TryMember(input, key.c_str()))
        {
            if (value->m_Kind == VALUE_BOOL)
                values[key] = value->ToBoolean();
            else
                AddNumber(values, key.c_str(), *value);
        }
    }
    return values;
}

void PublishSnapshot()
{
    CInstance* global = nullptr;
    game->GetGlobalInstance(&global);
    room = CurrentRoom(global);
    Json numbers = Json::object();
    Json flags = Json::object();
    for (auto key : globalNumbers)
        if (auto* value = TryMember(global, key))
            AddNumber(numbers, key, *value);
    for (auto key : globalFlags)
        if (auto* value = TryMember(global, key))
            flags[key] = value->ToBoolean();
    AddNumber(numbers, "gameFps", game->CallBuiltin("game_get_speed", {RValue(0.0)}));
    RValue actualFps;
    if (global && AurieSuccess(game->GetBuiltin("fps_real", global, NULL_INDEX, actualFps)))
        AddNumber(numbers, "actualFps", actualFps);

    WriteJson(L"snapshot.json", {
        {"pid", GetCurrentProcessId()}, {"frame", frame}, {"writtenUtc", UtcNow()},
        {"room", room}, {"inputReady", !inputFields.empty()}, {"inputFields", inputFields},
        {"inputHook", "native-input-begin-step"}, {"inputEvents", inputEvents},
        {"activeInputFrames", framesLeft}, {"appliedInputFrames", appliedInputFrames},
        {"inputValues", ReadInput()}, {"inputError", inputError}, {"numbers", numbers},
        {"flags", flags}, {"scene", ReadScene()}, {"mainMenu", ReadMenu(global)},
        {"menuInputs", ReadMenu(global, "menu_inputs")},
        {"inventories", {
            {"player", ReadInventory(global, "player_inventory")},
            {"store", ReadInventory(global, "store_inventory")},
            {"submarine", ReadInventory(global, "submarine_inventory")}
        }},
        {"projectiles", {{"bubble", bubbleProjectiles}, {"plasma", plasmaProjectiles}}},
        {"targets", ReadUnderwaterTargets()},
        {"observedEvents", observedEvents}, {"nativeReturnHook", originalKeyPressed != nullptr},
        {"nativeReturnReads", nativeReturnReads}, {"menuButtons", menuButtons},
        {"guiPointer", {
            {"active", pointer.Active()}, {"guiX", pointer.guiX}, {"guiY", pointer.guiY},
            {"worldX", pointer.worldX}, {"worldY", pointer.worldY},
            {"positionReads", pointerPositionReads}, {"buttonReads", pointerButtonReads},
            {"guiHooks", originalGuiX && originalGuiY},
            {"worldHooks", originalWorldX && originalWorldY},
            {"buttonHooks", originalMousePressed != nullptr}
        }}
    });
}

void StopInput()
{
    activeInput.clear();
    framesLeft = 0;
    inputLength = 0;
}

void StartInput(int count, const Json& values)
{
    if (count < 1 || count > 600 || !values.is_object() || values.empty())
        throw std::runtime_error("Expected 1 to 600 frames and a nonempty input values object.");

    std::map<std::string, Json> next;
    for (const auto& [key, value] : values.items())
    {
        if (!inputFields.contains(key))
            throw std::runtime_error("Unknown native input field: " + key);
        if (!value.is_boolean() && (!value.is_number() || std::abs(value.get<double>()) > 1))
            throw std::runtime_error("Expected a boolean or a value from -1 to 1 for " + key);
        next.emplace(key, value);
    }

    activeInput = std::move(next);
    framesLeft = count;
    inputLength = count;
    inputError.clear();
}

void KeyPressed(RValue& result, CInstance* self, CInstance* other, int count, RValue* arguments)
{
    originalKeyPressed(result, self, other, count, arguments);
    if (nativeReturnFrame && nativeReturnFrame == frame && count == 1 && arguments &&
        arguments[0].ToInt32() == VK_RETURN)
    {
        result = RValue(true);
        ++nativeReturnReads;
    }
}

void PressMenuEnter()
{
    if (room != "rm_main_menu")
        throw std::runtime_error("Menu Enter requires the main menu room.");

    Json values = Json::object();
    for (auto key : {"enter", "enter_pressed", "start"})
        if (inputFields.contains(key))
            values[key] = true;
    if (!values.empty())
        StartInput(1, values);
    else if (!originalKeyPressed)
        throw std::runtime_error("No menu input channel is available.");

    // Only GameMaker's own query reads see Return, during this single frame.
    nativeReturnFrame = frame;
}

void QueuePointer(const Json& params, bool click)
{
    const bool world = params.contains("worldX") || params.contains("worldY");
    double x = params.at(world ? "worldX" : "x").get<double>();
    double y = params.at(world ? "worldY" : "y").get<double>();
    const int button = params.value("button", 1);
    const int hold = params.value("holdFrames", click ? 1 : 60);
    if (!std::isfinite(x) || !std::isfinite(y) ||
        (!world && (x < 0 || x > 1 || y < 0 || y > 1)) ||
        (world && (std::abs(x) > 1000000 || std::abs(y) > 1000000)) ||
        button < 1 || button > 2 || hold < 1 || hold > 600)
        throw std::runtime_error("Expected normalized x/y or finite worldX/worldY, button 1-2 and holdFrames 1-600.");
    if ((!originalGuiX || !originalGuiY) && (!originalWorldX || !originalWorldY))
        throw std::runtime_error("Native pointer position readers are unavailable.");
    if (click && !originalMousePressed)
        throw std::runtime_error("Native pointer button readers are unavailable.");

    double guiWidth = game->CallBuiltin("display_get_gui_width", {}).ToDouble();
    double guiHeight = game->CallBuiltin("display_get_gui_height", {}).ToDouble();
    if (!std::isfinite(guiWidth) || guiWidth <= 0 || !std::isfinite(guiHeight) || guiHeight <= 0)
        throw std::runtime_error("The game has no initialized GUI dimensions.");

    CInstance* global = nullptr;
    game->GetGlobalInstance(&global);
    auto* cameraX = TryMember(global, "cam_x");
    auto* cameraY = TryMember(global, "cam_y");
    double viewWidth = guiWidth;
    double viewHeight = guiHeight;
    RValue camera;
    if (global && AurieSuccess(game->GetBuiltin("view_camera", global, 0, camera)) &&
        camera.ToDouble() >= 0)
    {
        auto width = game->CallBuiltin("camera_get_view_width", {camera}).ToDouble();
        auto height = game->CallBuiltin("camera_get_view_height", {camera}).ToDouble();
        if (std::isfinite(width) && width > 0)
            viewWidth = width;
        if (std::isfinite(height) && height > 0)
            viewHeight = height;
    }

    const double originX = cameraX ? cameraX->ToDouble() : 0;
    const double originY = cameraY ? cameraY->ToDouble() : 0;
    if (world)
    {
        x = (x - originX) / viewWidth;
        y = (y - originY) / viewHeight;
    }
    pointer.guiX = x * guiWidth;
    pointer.guiY = y * guiHeight;
    pointer.worldX = originX + x * viewWidth;
    pointer.worldY = originY + y * viewHeight;
    pointer.press = click ? frame + 5 : 0;
    pointer.release = click ? pointer.press + hold : 0;
    pointer.expire = click ? pointer.release + 3 : frame + hold;
    pointer.button = button;
}

void WritePointerPosition(RValue& result, double position)
{
    if (pointer.Active())
    {
        result = RValue(position);
        ++pointerPositionReads;
    }
}

void GuiX(RValue& result, CInstance* self, CInstance* other, int count, RValue* arguments)
{
    originalGuiX(result, self, other, count, arguments);
    WritePointerPosition(result, pointer.guiX);
}

void GuiY(RValue& result, CInstance* self, CInstance* other, int count, RValue* arguments)
{
    originalGuiY(result, self, other, count, arguments);
    WritePointerPosition(result, pointer.guiY);
}

bool WorldX(CInstance* self, int index, RValue* result)
{
    auto ok = originalWorldX(self, index, result);
    if (ok && result)
        WritePointerPosition(*result, pointer.worldX);
    return ok;
}

bool WorldY(CInstance* self, int index, RValue* result)
{
    auto ok = originalWorldY(self, index, result);
    if (ok && result)
        WritePointerPosition(*result, pointer.worldY);
    return ok;
}

void WritePointerButton(RValue& result, int count, RValue* arguments, bool pressed)
{
    if (pointer.Active() && pointer.press && count == 1 && arguments &&
        (arguments[0].ToInt32() == pointer.button || arguments[0].ToInt32() == -1))
    {
        result = RValue(pressed || result.ToBoolean());
        ++pointerButtonReads;
    }
}

void MouseDown(RValue& result, CInstance* self, CInstance* other, int count, RValue* arguments)
{
    originalMouseDown(result, self, other, count, arguments);
    WritePointerButton(result, count, arguments, frame >= pointer.press && frame < pointer.release);
}

void MousePressed(RValue& result, CInstance* self, CInstance* other, int count, RValue* arguments)
{
    originalMousePressed(result, self, other, count, arguments);
    WritePointerButton(result, count, arguments, frame == pointer.press);
}

void MouseReleased(RValue& result, CInstance* self, CInstance* other, int count, RValue* arguments)
{
    originalMouseReleased(result, self, other, count, arguments);
    WritePointerButton(result, count, arguments, frame == pointer.release);
}

void HookBuiltin(AurieModule* module, const char* name, TRoutine detour, TRoutine& original)
{
    void* target = nullptr;
    if (AurieSuccess(game->GetNamedRoutinePointer(name, &target)) && target)
        MmCreateHook(module, name, target, reinterpret_cast<void*>(detour),
                     reinterpret_cast<void**>(&original));
}

#include "ShelldiverVisualBudget.hpp"
#include "ShelldiverParticleBudget.hpp"
#include "ShelldiverDrawCadence.hpp"

void ShelldiverDrawCadence::PublishUpdateHeartbeat()
{
    const auto now = WallTicks();
    const auto elapsed = now - lastSnapshotTicks;
    if (elapsed >= 1200000 || (elapsed >= 200000 && frame - lastSnapshotFrame >= 12))
    {
        SampleThreadCycles counter(snapshotCycles);
        lastSnapshotTicks = now;
        lastSnapshotFrame = frame;
        ++snapshotCount;
        PublishSnapshot();
    }
}

void HookVariable(AurieModule* module, const char* name, VariableGetter detour,
                  VariableGetter& original)
{
    size_t index = 0;
    RVariableRoutine* variable = nullptr;
    if (AurieSuccess(game->GetBuiltinVariableIndex(name, index)) &&
        AurieSuccess(game->GetBuiltinVariableInformation(index, variable)) &&
        variable && variable->getter)
        MmCreateHook(module, name, reinterpret_cast<void*>(variable->getter),
                     reinterpret_cast<void*>(detour), reinterpret_cast<void**>(&original));
}

void PublishResult(const std::string& id, const std::string& action, bool ok,
                   const std::string& error, Json data = nullptr)
{
    Json result = {
        {"id", id}, {"action", action}, {"ok", ok},
        {"error", ok ? Json(nullptr) : Json(error)}, {"frame", frame}
    };
    if (!data.is_null())
        result["data"] = std::move(data);
    WriteJson(L"result.json", result);
}

void ObserveMenuButton(CInstance* object)
{
    if (!object || room != "rm_main_menu")
        return;

    bool continueButton = false;
    for (auto key : {"text_base", "text"})
    {
        if (auto* value = TryMember(object, key); value && value->m_Kind == VALUE_STRING)
        {
            auto label = value->ToString();
            if (!label.empty() && label.size() <= 120 && menuButtons.size() < 24)
                menuButtons.emplace(label);
            if (label == "Continue" || label == "continue_button")
                continueButton = true;
        }
    }
    if (!continueButton || continueId.empty())
        return;

    CInstance* global = nullptr;
    if (!AurieSuccess(game->GetGlobalInstance(&global)))
        return;
    const auto* loaded = TryMember(global, "files_loaded");
    const auto* tutorialFinished = TryMember(global, "is_tutorial_finished");
    const auto* xboxLoading = TryMember(global, "xbox_loading_user");
    const auto* transitioning = TryMember(global, "transitioning");
    if (!loaded || !loaded->ToBoolean() || !tutorialFinished || !tutorialFinished->ToBoolean() ||
        !xboxLoading || xboxLoading->ToBoolean() || !transitioning || transitioning->ToBoolean())
        return;

    auto* method = TryMember(object, "action");
    if (!method || !game->CallBuiltin("is_method", {*method}).ToBoolean())
        return;

    auto id = std::move(continueId);
    continueId.clear();
    RValue result;
    auto status = game->CallBuiltinEx(result, "method_call", object, object, {*method});
    PublishResult(id, "continue", AurieSuccess(status),
                  AurieSuccess(status) ? "" : AurieStatusToString(status));
}

void ProcessCommand()
{
    if (!continueId.empty() && frame >= continueDeadlineFrame)
    {
        auto id = std::move(continueId);
        continueId.clear();
        PublishResult(id, "continue", false, "No ready bound Continue button was observed.");
    }

    auto path = mailbox / L"command.json";
    std::ifstream stream(path, std::ios::binary);
    if (!stream)
        return;
    Json request = Json::parse(stream, nullptr, false);
    stream.close();
    std::filesystem::remove(path);
    std::string id;
    std::string action;
    bool ok = true;
    std::string error;
    Json data = nullptr;
    try
    {
        id = request.at("id").get<std::string>();
        action = request.at("action").get<std::string>();
        const auto& params = request.at("parameters");
        if (id.empty() || !params.is_object())
            throw std::runtime_error("Expected an ID and a parameters object.");
        if (action == "input")
            StartInput(params.at("frames").get<int>(), params.at("values"));
        else if (action == "stop")
        {
            StopInput();
            pointer.expire = 0;
        }
        else if (action == "click" || action == "aim")
            QueuePointer(params, action == "click");
        else if (action == "visualbudget")
        {
            auto bubbleDensity = params.value("density", ShelldiverVisualBudget::densityPercent);
            auto coralDensity = params.value("coralDensity", ShelldiverVisualBudget::coralDensityPercent);
            auto highlightDensity = ShelldiverParticleBudget::sleepSkillHighlights ? 0 : 100;
            const auto effects = params.find("effects");
            if (effects != params.end())
            {
                if (!effects->is_object())
                    throw std::runtime_error("Expected named Shelldiver cosmetic effect densities.");
                for (auto effect = effects->begin(); effect != effects->end(); ++effect)
                {
                    if (!effect->is_number_integer())
                        throw std::runtime_error("Cosmetic effect densities must be integers.");
                    if (effect.key() == "ps_bubble_projectile_trail") bubbleDensity = effect->get<int>();
                    else if (effect.key() == "ps_coral_bubble") coralDensity = effect->get<int>();
                    else if (effect.key() == "ps_skill_can_buy") highlightDensity = effect->get<int>();
                    else throw std::runtime_error("Shelldiver effect is outside the verified cosmetic list.");
                }
            }
            if ((highlightDensity != 0 && highlightDensity != 100) ||
                (highlightDensity == 0 && !ShelldiverParticleBudget::Supported()) ||
                !ShelldiverVisualBudget::SetDensities(bubbleDensity, coralDensity))
                throw std::runtime_error("Unsupported Shelldiver visual density or game build.");
            const bool selectedSleep = highlightDensity == 0;
            if (selectedSleep != ShelldiverParticleBudget::sleepSkillHighlights)
                ShelldiverParticleBudget::SetSkillHighlightBudget(highlightDensity);
            data = ShelldiverVisualBudget::Stats();
            data["nativeParticles"] = ShelldiverParticleBudget::Status(params.value("nativeCensus", false));
        }
        else if (action == "drawcadence")
        {
            if (params.contains("mode"))
            {
                using ShelldiverDrawCadence::Mode;
                const auto requested = params.at("mode").get<std::string>();
                if (requested != "stock" && requested != "60hz")
                    throw std::runtime_error("Choose stock or 60hz native Draw.");
                if (requested == "60hz" && ShelldiverPresentCadence::mode == ShelldiverPresentCadence::Mode::Display60)
                    throw std::runtime_error("Turn off the Present cap before enabling the native Draw cadence.");
                if (!ShelldiverDrawCadence::SetMode(requested == "60hz" ? Mode::Display60 : Mode::Stock))
                    throw std::runtime_error("Verified Magma III system timing and native Draw hooks are required.");
            }
            data = ShelldiverDrawCadence::Status();
        }
        else if (action == "presentation")
        {
            if (params.contains("mode"))
            {
                const auto selected = params.at("mode").get<std::string>();
                using ShelldiverPresentCadence::Mode;
                if (selected == "stock")
                    ShelldiverPresentCadence::SetMode(Mode::Stock);
                else if (selected == "measure")
                    ShelldiverPresentCadence::SetMode(Mode::Measure);
                else if (selected == "60hz")
                {
                    if (ShelldiverDrawCadence::drawMode == ShelldiverDrawCadence::Mode::Display60)
                        throw std::runtime_error("Turn off the native Draw cadence before enabling the Present cap.");
                    const auto timing = game->CallBuiltin("display_get_timing_method", {});
                    if (timing.m_Kind == VALUE_UNDEFINED || timing.ToDouble() != 2.0 ||
                        !ShelldiverPresentCadence::StockMode2Presentation() || !ShelldiverPresentCadence::resizeWatchInstalled)
                        throw std::runtime_error("A verified stock GameMaker system-timing game is required.");
                    ShelldiverPresentCadence::SetMode(Mode::Display60);
                }
                else
                    throw std::runtime_error("Choose stock, measure, or 60hz presentation mode.");
            }
            data = ShelldiverPresentCadence::Stats();
        }
        else if (action == "timing")
        {
            const auto previous = game->CallBuiltin("display_get_timing_method", {});
            if (previous.m_Kind == VALUE_UNDEFINED)
                throw std::runtime_error("GameMaker did not return its timing method.");
            const int previousMethod = static_cast<int>(previous.ToDouble());
            if (params.contains("method"))
            {
                const int method = params.at("method").get<int>();
                if (method < 0 || method > 3)
                    throw std::runtime_error("Unknown Shelldiver display timing method.");
                if (method != 2 && ShelldiverPresentCadence::mode == ShelldiverPresentCadence::Mode::Display60)
                    ShelldiverPresentCadence::SetMode(ShelldiverPresentCadence::Mode::Measure);
                if (method != 2 && ShelldiverDrawCadence::drawMode == ShelldiverDrawCadence::Mode::Display60)
                    ShelldiverDrawCadence::SetMode(ShelldiverDrawCadence::Mode::Stock);
                game->CallBuiltin("display_set_timing_method", { RValue(double(method)) });
                const auto current = game->CallBuiltin("display_get_timing_method", {});
                if (current.m_Kind == VALUE_UNDEFINED || current.ToDouble() != method)
                    throw std::runtime_error("The engine did not confirm the timing change.");
            }
            if (params.contains("measureBridge"))
                measureBridge = params.at("measureBridge").get<bool>();
            if (params.contains("measureNativeVisual"))
                measureNativeVisual = params.at("measureNativeVisual").get<bool>();
            ULONGLONG mainCycles = 0;
            QueryThreadCycleTime(GetCurrentThread(), &mainCycles);
            data = {
                {"previousMethod", previousMethod}, {"measuringBridge", measureBridge},
                {"nativeFrame", frame}, {"mainCycles", mainCycles}, {"wallTicks100ns", WallTicks()},
                {"inputDrawEvents", inputDrawEvents},
                {"nonTestPresentCalls", nonTestPresentCalls.load(std::memory_order_relaxed)},
                {"measuringNativeVisual", measureNativeVisual},
                {"oceanDraw", {{"calls", oceanDrawProfile.calls}, {"cycles", oceanDrawProfile.cycles}}},
                {"lightDraw", {{"calls", lightDrawProfile.calls}, {"cycles", lightDrawProfile.cycles}}},
                {"coralStep", {{"calls", coralStepProfile.calls}, {"cycles", coralStepProfile.cycles}}},
                {"lastObservedBubbleFlight", recentFlight}, {"snapshots", snapshotCount}, {"snapshotCycles", snapshotCycles},
                {"sceneCycles", sceneCycles}, {"controlCycles", controlCycles},
                {"method", game->CallBuiltin("display_get_timing_method", {}).ToDouble()},
                {"sleepMarginMs", game->CallBuiltin("display_get_sleep_margin", {}).ToDouble()}
            };
        }
        else if (action == "speed")
        {
            int fps = params.at("fps").get<int>();
            if (fps < 60 || fps > 1500)
                throw std::runtime_error("Speed requires a target FPS from 60 to 1500.");
            game->CallBuiltin("game_set_speed", {RValue(double(fps)), RValue(0.0)});
            auto confirmedFps = game->CallBuiltin("game_get_speed", {RValue(0.0)});
            if (confirmedFps.m_Kind == VALUE_UNDEFINED || std::abs(confirmedFps.ToDouble() - fps) > 0.01)
                throw std::runtime_error("The game did not select the requested frame rate.");
        }
        else if (action == "skills")
            data = ReadSkillCatalog();
        else if (action == "title-enter")
            PressMenuEnter();
        else if (action == "continue")
        {
            auto save = EnvironmentPath(L"APPDATA") / L"Shelldiver" / L"save" / L"Game.json";
            if (room != "rm_main_menu" || !std::filesystem::exists(save) ||
                !params.value("selectionVerified", false))
                throw std::runtime_error("Continue requires an existing save and the visible Continue button.");
            continueId = id;
            continueDeadlineFrame = frame + 120;
            return;
        }
        else
            throw std::runtime_error("Unsupported action: " + action);
    }
    catch (const std::exception& failure)
    {
        ok = false;
        error = failure.what();
    }
    PublishResult(id, action, ok, error, std::move(data));
}

void ApplyInput()
{
    if (!framesLeft)
        return;
    for (const auto& [key, value] : activeInput)
    {
        if (framesLeft != inputLength && key.ends_with("_pressed"))
            continue;
        auto* slot = TryMember(input, key.c_str());
        if (!slot)
        {
            inputError = "Native input field disappeared: " + key;
            StopInput();
            return;
        }
        if (slot->m_Kind == VALUE_BOOL)
            *slot = RValue(value.is_boolean() ? value.get<bool>() : value.get<double>() != 0.0);
        else
            *slot = RValue(value.is_boolean() ? (value.get<bool>() ? 1.0 : 0.0) : value.get<double>());
    }
    --framesLeft;
    ++appliedInputFrames;
}

void OnObjectCall(FWCodeEvent& event)
{
    auto [self, other, code, flags, result] = event.Arguments();
    if (!code || !code->GetName())
        return;

    std::string_view name(code->GetName());
    if (observedEvents.size() < 40 || name.find("o_input_") != std::string_view::npos)
        observedEvents.emplace(name);
    if (name == "gml_Object_o_bubble_projectile_Create_0")
    {
        ++bubbleProjectiles;
        if (measureBridge) ObserveBubbleFlight(self, true);
    }
    else if (measureBridge && name == "gml_Object_o_bubble_projectile_Step_0")
        ObserveBubbleFlight(self, false);
    else if (name == "gml_Object_o_plasma_projectile_Create_0")
        ++plasmaProjectiles;

    try
    {
        if (auto* profile = NativeVisualProfile(name); profile && !event.CalledOriginal())
        {
            SampleThreadCycles counter(profile->cycles, true);
            ShelldiverVisualBudget::Apply(event, self, name);
            if (!event.CalledOriginal())
                event.Call();
            ++profile->calls;
        }
        else
        {
            ShelldiverVisualBudget::Apply(event, self, name);
        }
        if (name != "gml_Object_o_input_Step_1")
        {
            if (ShelldiverDrawCadence::collectingGuards)
            {
                if (name == "gml_Object_par_player_Step_0")
                    ShelldiverDrawCadence::ObservePlayer(self);
                else if (name == "gml_Object_par_jellyfish_magma_Step_0")
                    ShelldiverDrawCadence::ObserveWarning(self);
            }
            if (name == "gml_Object_o_upgrade_area_Draw_64" && ShelldiverParticleBudget::sleepSkillHighlights)
                ShelldiverParticleBudget::Observe(WallTicks());
            if (name == "gml_Object_o_input_Draw_64")
            {
                ++inputDrawEvents;
                if (!ShelldiverDrawCadence::stockUpdate)
                    ShelldiverDrawCadence::PublishUpdateHeartbeat();
            }
            else if (name == "gml_Object_o_button_Step_0" &&
                     (frame % 15 == 0 || !continueId.empty()))
            {
                ObserveMenuButton(self);
            }
            else if (name.ends_with("_Create_0") || frame % 15 == 0)
            {
                SampleThreadCycles counter(sceneCycles);
                CaptureScene(name, self);
                CaptureUnderwaterTarget(name, self);
            }
            return;
        }

        ++frame;
        ++inputEvents;
        if (input != self || inputFields.empty())
        {
            input = self;
            inputFields.clear();
            for (const auto& key : allowedInputs)
                if (TryMember(input, key.c_str()))
                    inputFields.insert(key);
        }
        {
            SampleThreadCycles counter(controlCycles);
            ProcessCommand();
        }
        if (ShelldiverParticleBudget::sleepSkillHighlights || !ShelldiverParticleBudget::sleeping.empty())
            ShelldiverParticleBudget::Observe(WallTicks());
        if (framesLeft > 0)
        {
            if (!event.CalledOriginal())
                event.Call();
            ApplyInput();
        }
    }
    catch (const std::exception& failure)
    {
        inputError = failure.what();
        StopInput();
    }
}

void OnFrame(FWFrame& event)
{
    const auto& [swapChain, syncInterval, flags] = event.Arguments();
    if (swapChain && !(flags & DXGI_PRESENT_TEST))
        nonTestPresentCalls.fetch_add(1, std::memory_order_relaxed);
    ShelldiverPresentCadence::Observe(event, [] {
        if (room != "rm_ocean_magma_03" || !inputEvents)
            return false;
        CInstance* global = nullptr;
        if (!AurieSuccess(game->GetGlobalInstance(&global)) || !global)
            return false;
        RValue roomId;
        if (!AurieSuccess(game->GetBuiltin("room", global, NULL_INDEX, roomId)) ||
            roomId.m_Kind == VALUE_UNDEFINED)
            return false;
        const auto observedRoom = game->CallBuiltin("room_get_name", {roomId});
        if (observedRoom.m_Kind != VALUE_STRING || observedRoom.ToString() != "rm_ocean_magma_03")
            return false;
        for (const auto* name : {"transitioning", "pause", "in_cutscene", "player_inventory_open"})
        {
            const auto* flag = TryMember(global, name);
            if (!flag || flag->ToBoolean())
                return false;
        }
        const auto timing = game->CallBuiltin("display_get_timing_method", {});
        if (timing.m_Kind == VALUE_UNDEFINED || timing.ToDouble() != 2.0)
            return false;
        const auto player = sceneObserved.find("player");
        return player != sceneObserved.end() && player->value("can_use_tool", 0.0) == 1.0 &&
               player->value("oxygen", 0.0) > 0.0;
    });
    if (inputEvents || Clock::now() < nextSnapshot)
        return;
    nextSnapshot = Clock::now() + std::chrono::milliseconds(500);
    try
    {
        WriteJson(L"snapshot.json", {
            {"pid", GetCurrentProcessId()}, {"frame", frame}, {"writtenUtc", UtcNow()},
            {"room", room}, {"inputReady", false}, {"inputEvents", inputEvents},
            {"observedEvents", observedEvents}, {"inputError", inputError}
        });
    }
    catch (const std::exception&)
    {
    }
}
} // namespace

EXPORTED AurieStatus ModuleInitialize(AurieModule* module, const std::filesystem::path&)
{
    game = YYTK::GetInterface();
    if (!game)
        return AURIE_MODULE_DEPENDENCY_NOT_RESOLVED;
    try
    {
        mailbox = EnvironmentPath(L"LOCALAPPDATA") / L"ShelldiverAutoplay" / L"2026-11-27" / L"mailbox";
        std::filesystem::create_directories(mailbox);
    }
    catch (const std::exception& failure)
    {
        DbgPrintEx(LOG_SEVERITY_DEBUG, "[ShelldiverAutoplay] %s", failure.what());
        return AURIE_MODULE_INITIALIZATION_FAILED;
    }
    ShelldiverVisualBudget::Install(game);
    ShelldiverParticleBudget::Install(game);
    ShelldiverDrawCadence::Install(module);
    auto status = game->CreateCallback(module, EVENT_OBJECT_CALL, OnObjectCall, 0);
    if (!AurieSuccess(status))
        return status;
    status = game->CreateCallback(module, EVENT_RESIZE, ShelldiverPresentCadence::NoteResize, 0);
    ShelldiverPresentCadence::resizeWatchInstalled = AurieSuccess(status);
    status = game->CreateCallback(module, EVENT_FRAME, OnFrame, -1000);
    if (!AurieSuccess(status))
        return status;

    void* keyPressed = nullptr;
    if (AurieSuccess(game->GetNamedRoutinePointer("keyboard_check_pressed", &keyPressed)) && keyPressed)
    {
        auto hookStatus = MmCreateHook(module, "ShelldiverAutoplay.KeyPressed", keyPressed,
                                       reinterpret_cast<void*>(KeyPressed),
                                       reinterpret_cast<void**>(&originalKeyPressed));
        if (!AurieSuccess(hookStatus))
            DbgPrintEx(LOG_SEVERITY_DEBUG, "[ShelldiverAutoplay] Key reader unavailable: %s",
                       AurieStatusToString(hookStatus));
    }
    HookBuiltin(module, "device_mouse_x_to_gui", GuiX, originalGuiX);
    HookBuiltin(module, "device_mouse_y_to_gui", GuiY, originalGuiY);
    HookBuiltin(module, "mouse_check_button", MouseDown, originalMouseDown);
    HookBuiltin(module, "mouse_check_button_pressed", MousePressed, originalMousePressed);
    HookBuiltin(module, "mouse_check_button_released", MouseReleased, originalMouseReleased);
    HookVariable(module, "mouse_x", WorldX, originalWorldX);
    HookVariable(module, "mouse_y", WorldY, originalWorldY);
    DbgPrintEx(LOG_SEVERITY_DEBUG, "[ShelldiverAutoplay] Bridge initialized.");
    return AURIE_SUCCESS;
}













