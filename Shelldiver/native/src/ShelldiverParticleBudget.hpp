#pragma once

namespace ShelldiverParticleBudget
{
using ShelldiverVisualBudget::StockSignature;

constexpr int skillHighlightAsset = 28;
constexpr std::uintptr_t systemsRva = 0xCEF6F0;
constexpr std::uintptr_t assetVectorRva = 0x10D46B8;
constexpr std::uint64_t refreshTicks = 5'000'000;
constexpr std::size_t maximumRegistrySlots = 25'000;

constexpr std::array<StockSignature, 7> particleSignatures{{
    {0x64A1AC, {0x88, 0x58, 0x35, 0x48, 0x83, 0xC4, 0x20, 0x5B}},
    {0x64A1DC, {0x88, 0x58, 0x34, 0x48, 0x83, 0xC4, 0x20, 0x5B}},
    {0x64C4AB, {0x4C, 0x63, 0x50, 0x18, 0x44, 0x8B, 0xC3, 0x44}},
    {0x64CF99, {0x4C, 0x8B, 0x0D, 0x60, 0x27, 0x6A, 0x00, 0x4C}},
    {0x6D54D9, {0x48, 0xB9, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00}},
    {0x6DA192, {0x48, 0x63, 0x4B, 0x04, 0x85, 0xC9, 0x78, 0x2B}},
    {0x6DA1A1, {0x4C, 0x8B, 0x05, 0x10, 0xA5, 0x9F, 0x00, 0x49}}
}};

template <class T>
T ReadField(const unsigned char* bytes, std::size_t offset)
{
    T value{};
    std::memcpy(&value, bytes + offset, sizeof(value));
    return value;
}

struct System
{
    const unsigned char* address;
    int id;
    int asset;
    const unsigned char* const* emitters;
    int emitterCount;
    bool automaticUpdate;
    bool automaticDraw;
};

struct SavedSystem
{
    const unsigned char* address;
    const unsigned char* const* emitters;
    bool automaticUpdate;
    bool automaticDraw;
};

const unsigned char* stockImage = nullptr;
YYTKInterface* particleGame = nullptr;
bool sleepSkillHighlights = false;
std::map<int, SavedSystem> sleeping;
std::uint64_t nextRefresh = 0;
std::uint64_t roomToken = 0;
int roomKind = -1;
bool isIsland = false;
bool isExpedition = false;
bool previousSleep = false;
std::uint64_t sleepWrites = 0;
std::uint64_t wakeWrites = 0;
std::uint64_t failedWrites = 0;

const char* const* const* AssetVector()
{
    return ReadField<const char* const* const*>(stockImage, assetVectorRva);
}

std::size_t AssetCount()
{
    const auto first = ReadField<std::uintptr_t>(stockImage, assetVectorRva);
    const auto last = ReadField<std::uintptr_t>(stockImage, assetVectorRva + sizeof(std::uintptr_t));
    if (!first || last < first || (last - first) % sizeof(std::uintptr_t))
        return 0;
    return (last - first) / sizeof(std::uintptr_t);
}

bool Supported()
{
    if (!stockImage || !particleGame || AssetCount() != 36)
        return false;
    const auto entry = AssetVector()[skillHighlightAsset];
    return entry && *entry && std::string_view(*entry) == "ps_skill_can_buy";
}

void Install(YYTKInterface* gameInterface)
{
    const auto* image = reinterpret_cast<const unsigned char*>(GetModuleHandleW(nullptr));
    if (ShelldiverVisualBudget::VerifyStockSignatures(image, particleSignatures))
    {
        stockImage = image;
        particleGame = gameInterface;
    }
}

template <class Visitor>
bool ForEachSystem(Visitor visit)
{
    if (!Supported())
        return false;

    const auto* list = stockImage + systemsRva;
    const auto lateCount = ReadField<std::size_t>(list, 0x10);
    const auto indexedCount = ReadField<std::size_t>(list, 0x38);
    if (lateCount > maximumRegistrySlots || indexedCount > maximumRegistrySlots)
        return false;

    for (const auto offset : {std::size_t{0x30}, std::size_t{0x08}})
    {
        const auto count = ReadField<std::size_t>(list, offset + 8);
        const auto entries = ReadField<const unsigned char* const*>(list, offset);
        if (count && !entries)
            return false;

        for (std::size_t index = 0; index < count; ++index)
        {
            const auto* address = entries[index];
            if (!address)
                continue;
            const int id = ReadField<int>(address, 0);
            const int asset = ReadField<int>(address, 4);
            const int emitterCount = ReadField<int>(address, 0x18);
            if (id < 0 || asset < -1 || asset >= 36 || emitterCount < 0 || emitterCount > 64)
                continue;

            visit(System{
                address, id, asset,
                ReadField<const unsigned char* const*>(address, 0x10), emitterCount,
                address[0x34] != 0, address[0x35] != 0
            });
        }
    }
    return true;
}

bool SetAutomatic(const System& system, bool update, bool draw)
{
    // This is the typed reference produced by the stock part_system_create wrapper.
    RValue handle;
    handle.m_Kind = VALUE_REF;
    handle.m_i64 = std::int64_t{0x0400000400000000LL} | static_cast<std::uint32_t>(system.id);
    RValue ignored;

    if (system.automaticUpdate != update)
        particleGame->CallBuiltinEx(ignored, "part_system_automatic_update", nullptr, nullptr, {handle, RValue(update)});
    if (system.automaticDraw != draw)
        particleGame->CallBuiltinEx(ignored, "part_system_automatic_draw", nullptr, nullptr, {handle, RValue(draw)});

    return (system.address[0x34] != 0) == update && (system.address[0x35] != 0) == draw;
}

bool SameSystem(const System& current, const SavedSystem& previous)
{
    return current.address == previous.address && current.emitters == previous.emitters;
}

void Apply(bool sleep)
{
    std::set<int> verified;
    const bool complete = ForEachSystem([&](const System& system) {
        if (system.asset != skillHighlightAsset)
            return;
        verified.insert(system.id);

        auto record = sleeping.find(system.id);
        if (record != sleeping.end() && !SameSystem(system, record->second))
        {
            sleeping.erase(record);
            record = sleeping.end();
        }

        if (sleep)
        {
            if (!system.automaticUpdate && !system.automaticDraw)
                return;
            if (record == sleeping.end())
                sleeping.emplace(system.id, SavedSystem{system.address, system.emitters,
                    system.automaticUpdate, system.automaticDraw});
            if (SetAutomatic(system, false, false))
                ++sleepWrites;
            else
                ++failedWrites;
        }
        else if (record != sleeping.end())
        {
            if (SetAutomatic(system, record->second.automaticUpdate, record->second.automaticDraw))
            {
                sleeping.erase(record);
                ++wakeWrites;
            }
            else
                ++failedWrites;
        }
    });

    if (complete)
        std::erase_if(sleeping, [&](const auto& entry) { return !verified.contains(entry.first); });
}

bool SkillTreeClosed(CInstance* global)
{
    RValue* flag = nullptr;
    if (!AurieSuccess(particleGame->GetInstanceMember(RValue(global), "skill_tree_ui", flag)) || !flag)
        return false;
    switch (flag->m_Kind)
    {
    case VALUE_BOOL:
    case VALUE_REAL:
    case VALUE_INT32:
    case VALUE_INT64:
        return !flag->ToBoolean();
    default:
        return false;
    }
}

void Observe(std::uint64_t now, bool force = false)
{
    if (!sleepSkillHighlights && sleeping.empty())
        return;
    if (!Supported())
        return;

    CInstance* global = nullptr;
    RValue nativeRoom;
    if (!AurieSuccess(particleGame->GetGlobalInstance(&global)) || !global ||
        !AurieSuccess(particleGame->GetBuiltin("room", global, NULL_INDEX, nativeRoom)))
    {
        if (!sleeping.empty())
            Apply(false);
        roomKind = -1;
        previousSleep = false;
        return;
    }

    const auto identity = ReadField<std::uint64_t>(reinterpret_cast<const unsigned char*>(&nativeRoom), 0);
    const int kind = nativeRoom.m_Kind;
    const bool changedRoom = identity != roomToken || kind != roomKind;
    if (changedRoom)
    {
        const auto name = particleGame->CallBuiltin("room_get_name", {nativeRoom});
        roomToken = identity;
        roomKind = kind;
        const auto room = name.m_Kind == VALUE_STRING ? name.ToString() : std::string{};
        isIsland = room == "rm_main_island" || room == "rm_main_island_demo";
        isExpedition = room.starts_with("rm_ocean_");
    }

    const bool shouldSleep = sleepSkillHighlights && (isExpedition || (isIsland && SkillTreeClosed(global)));
    if (force || changedRoom || shouldSleep != previousSleep || now >= nextRefresh)
    {
        Apply(shouldSleep);
        previousSleep = shouldSleep;
        nextRefresh = now + refreshTicks;
    }
}

bool SetSkillHighlightBudget(int density)
{
    if ((density != 0 && density != 100) || (density == 0 && !Supported()))
        return false;
    sleepSkillHighlights = density == 0;
    Observe(WallTicks(), true);
    return true;
}

Json Status(bool census)
{
    Json data = {
        {"supported", Supported()}, {"sleepSkillHighlightsOutsideTree", sleepSkillHighlights},
        {"currentlySleeping", sleeping.size()}, {"systemsSlept", sleepWrites},
        {"activeClosedContext", previousSleep},
        {"systemsRestored", wakeWrites}, {"failures", failedWrites}
    };
    if (!census)
        return data;

    struct Totals { unsigned systems{}, updating{}, particles{}, autoParticles{}; };
    std::map<int, Totals> totals;
    const bool readable = ForEachSystem([&](const System& system) {
        auto& total = totals[system.asset];
        ++total.systems;
        if (system.automaticUpdate)
            ++total.updating;
        if (!system.emitters)
            return;
        for (int index = 0; index < system.emitterCount; ++index)
        {
            const auto* emitter = system.emitters[index];
            if (!emitter)
                continue;
            const int count = ReadField<int>(emitter, 0x10);
            if (count < 0 || count > 20'000)
                continue;
            total.particles += count;
            if (system.automaticUpdate)
                total.autoParticles += count;
        }
    });

    data["censusReadable"] = readable;
    auto& rows = data["assets"] = Json::array();
    if (readable)
    {
        const auto names = AssetVector();
        for (const auto& [asset, counts] : totals)
        {
            const char* name = asset >= 0 && names[asset] && *names[asset] ? *names[asset] : "";
            rows.push_back({{"asset", asset}, {"name", name}, {"systems", counts.systems},
                {"autoSystems", counts.updating}, {"particles", counts.particles},
                {"autoParticles", counts.autoParticles}});
        }
    }
    return data;
}
} // namespace ShelldiverParticleBudget
