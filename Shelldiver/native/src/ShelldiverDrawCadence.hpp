#pragma once

namespace ShelldiverDrawCadence
{
using ShelldiverVisualBudget::StockSignature;

enum class Mode { Stock, Display60 };
constexpr std::uintptr_t drawFlagRva = 0x10D186B;
constexpr std::uintptr_t timingModeRva = 0xCE708C;
constexpr std::uintptr_t updateRva = 0x580E50;
constexpr std::uintptr_t updateReturnRva = 0x580D26;
constexpr std::uintptr_t submitRva = 0x6000E0;
constexpr std::uintptr_t submitReturnRva = 0x58253B;
constexpr std::uint64_t drawInterval = 10'000'000 / 60;

constexpr std::array<StockSignature, 8> drawSignatures{{
    {0x523D3B, {0xE8, 0x70, 0xD6, 0xFA, 0xFF, 0x88, 0x05, 0x25}},
    {0x580D21, {0xE8, 0x2A, 0x01, 0x00, 0x00, 0x83, 0x3D, 0xAB}},
    {0x580D5E, {0x80, 0x3D, 0x06, 0x0B, 0xB5, 0x00, 0x00, 0x74}},
    {0x580E50, {0x48, 0x89, 0x5C, 0x24, 0x08, 0x48, 0x89, 0x6C}},
    {0x582536, {0xE8, 0xA5, 0xDB, 0x07, 0x00, 0x48, 0x8B, 0x05}},
    {0x6000E0, {0x48, 0x89, 0x5C, 0x24, 0x08, 0x57, 0x48, 0x83}},
    {0x600134, {0x84, 0xDB, 0x74, 0x21, 0xE8, 0x13, 0xEC, 0xFF}},
    {0x66597F, {0x83, 0xF8, 0x02, 0x75, 0x08, 0xB0, 0x01, 0x48}}
}};

using UpdateRoutine = void(*)();
using SubmitRoutine = bool(*)(bool);
UpdateRoutine stockUpdate = nullptr;
SubmitRoutine stockSubmit = nullptr;
AurieModule* drawModule = nullptr;
const unsigned char* drawImage = nullptr;
DWORD drawThread = 0;
Mode drawMode = Mode::Stock;
bool ownsDisabledDraw = false;
bool collectingGuards = false;
bool warningActiveOrUnknown = false;
int playerId = -1;
std::uint64_t nextDrawDue = 0;
std::uint64_t measuredUpdates = 0;
std::uint64_t renderedSubmissions = 0;
std::uint64_t skippedDraws = 0;
std::uint64_t guardedDraws = 0;
std::uint64_t restoreFailures = 0;

void PublishUpdateHeartbeat();

bool StockSystemTiming()
{
    return drawImage && ShelldiverParticleBudget::ReadField<int>(drawImage, timingModeRva) == 2;
}

bool StockDrawingEnabled()
{
    return drawImage && drawImage[drawFlagRva] != 0;
}

bool SetStockDrawEnabled(bool enabled)
{
    game->CallBuiltin("draw_enable_drawevent", {RValue(enabled)});
    return StockDrawingEnabled() == enabled;
}

void Restore()
{
    if (ownsDisabledDraw)
    {
        if (StockDrawingEnabled() || SetStockDrawEnabled(true))
            ownsDisabledDraw = false;
        else
            ++restoreFailures;
    }
}

bool MatchCall(const void* returnAddress, std::uintptr_t expected)
{
    return drawImage && returnAddress == drawImage + expected && drawThread == GetCurrentThreadId();
}

bool IsNumeric(const RValue* value)
{
    return value && (value->m_Kind == VALUE_REAL || value->m_Kind == VALUE_INT32 ||
        value->m_Kind == VALUE_INT64 || value->m_Kind == VALUE_BOOL);
}

void ObservePlayer(CInstance* self)
{
    if (!collectingGuards || !self || playerId >= 100000)
        return;
    RValue id;
    if (!AurieSuccess(game->GetBuiltin("id", self, NULL_INDEX, id)))
        return;
    if (id.m_Kind == VALUE_REF)
        playerId = id.m_i32;
    else if (IsNumeric(&id))
        playerId = id.ToInt32();
}

void ObserveWarning(CInstance* self)
{
    if (!collectingGuards || warningActiveOrUnknown)
        return;

    const auto* warning = TryMember(self, "jellyfish_explosion_icon_alpha");
    const auto* blast = TryMember(self, "explosion");
    const auto* attack = TryMember(self, "jellyfish_attack_delay");
    warningActiveOrUnknown = !IsNumeric(warning) || !IsNumeric(blast) || !IsNumeric(attack) ||
        !std::isfinite(warning->ToDouble()) || !std::isfinite(attack->ToDouble()) ||
        warning->ToDouble() > 0.0 || attack->ToDouble() > 0.0 || blast->ToBoolean();
}

bool ControlsNeedFullDraw()
{
    if (!input)
        return true;
    for (const auto* key : {"interact", "open_inventory", "open_skilltree"})
    {
        const auto* value = TryMember(input, key);
        if (!IsNumeric(value) || value->ToBoolean())
            return true;
    }
    return false;
}

bool ActiveDiveAfterUpdate()
{
    if (warningActiveOrUnknown || playerId < 100000 || ControlsNeedFullDraw())
        return false;

    CInstance* global = nullptr;
    RValue roomId;
    if (!AurieSuccess(game->GetGlobalInstance(&global)) || !global ||
        !AurieSuccess(game->GetBuiltin("room", global, NULL_INDEX, roomId)))
        return false;
    const auto actualRoom = game->CallBuiltin("room_get_name", {roomId});
    if (actualRoom.m_Kind != VALUE_STRING || actualRoom.ToString() != "rm_ocean_magma_03")
        return false;

    for (const auto* key : {"pause", "transitioning", "in_cutscene", "player_inventory_open"})
    {
        const auto* value = TryMember(global, key);
        if (!IsNumeric(value) || value->ToBoolean())
            return false;
    }

    CInstance* player = nullptr;
    if (!AurieSuccess(game->GetInstanceObject(playerId, player)) || !player)
        return false;
    const auto* oxygen = TryMember(player, "oxygen");
    const auto* maximum = TryMember(player, "oxygen_max");
    const auto* active = TryMember(player, "can_use_tool");
    const auto* full = TryMember(player, "is_inventory_full");
    return IsNumeric(oxygen) && IsNumeric(maximum) && oxygen->ToDouble() > 0.25 * maximum->ToDouble() &&
        IsNumeric(active) && active->ToBoolean() && IsNumeric(full) && !full->ToBoolean();
}

void Update()
{
    if (!MatchCall(_ReturnAddress(), updateReturnRva))
    {
        stockUpdate();
        return;
    }

    try { Restore(); }
    catch (const std::exception&) { ++restoreFailures; }
    const auto started = WallTicks();
    collectingGuards = drawMode == Mode::Display60 && StockSystemTiming() &&
        room == "rm_ocean_magma_03" && started != 0 && started < nextDrawDue;
    playerId = -1;
    warningActiveOrUnknown = false;
    stockUpdate();
    collectingGuards = false;
    ++measuredUpdates;

    try
    {
        PublishUpdateHeartbeat();
        if (drawMode != Mode::Display60 || !StockSystemTiming() || !StockDrawingEnabled())
        {
            nextDrawDue = 0;
            return;
        }

        const auto now = WallTicks();
        if (!now || !nextDrawDue || now >= nextDrawDue)
        {
            nextDrawDue = now && nextDrawDue && now >= nextDrawDue && now - nextDrawDue < drawInterval
                ? nextDrawDue + drawInterval : now + drawInterval;
            return;
        }

        if (!ActiveDiveAfterUpdate())
        {
            ++guardedDraws;
            return;
        }

        // Own this override until the normal native submit returns, with an Update-entry fallback.
        ownsDisabledDraw = true;
        if (SetStockDrawEnabled(false))
            ++skippedDraws;
        else
            ownsDisabledDraw = false;
    }
    catch (const std::exception&)
    {
        try { Restore(); }
        catch (const std::exception&) { ++restoreFailures; }
    }
}

bool Submit(bool draw)
{
    const bool matching = MatchCall(_ReturnAddress(), submitReturnRva);
    const bool result = stockSubmit(draw);
    if (matching)
    {
        if (draw)
            ++renderedSubmissions;
        try { Restore(); }
        catch (const std::exception&) { ++restoreFailures; }
    }
    return result;
}

bool Install(AurieModule* owner)
{
    if (!owner)
        return false;
    const auto* image = reinterpret_cast<const unsigned char*>(GetModuleHandleW(nullptr));
    if (!ShelldiverVisualBudget::VerifyStockSignatures(image, drawSignatures))
        return false;
    drawModule = owner;
    drawImage = image;
    return true;
}

bool SetMode(Mode requested)
{
    if (requested == Mode::Stock)
    {
        Restore();
        drawMode = requested;
        nextDrawDue = 0;
        return true;
    }
    if (!drawModule || !drawImage || !StockSystemTiming())
        return false;

    if (!stockSubmit)
    {
        const auto status = MmCreateHook(drawModule, "ShelldiverDrawCadence.Submit",
            const_cast<unsigned char*>(drawImage + submitRva), reinterpret_cast<void*>(Submit),
            reinterpret_cast<void**>(&stockSubmit));
        if (!AurieSuccess(status) || !stockSubmit)
            return false;
    }
    if (!stockUpdate)
    {
        const auto status = MmCreateHook(drawModule, "ShelldiverDrawCadence.Update",
            const_cast<unsigned char*>(drawImage + updateRva), reinterpret_cast<void*>(Update),
            reinterpret_cast<void**>(&stockUpdate));
        if (!AurieSuccess(status) || !stockUpdate)
            return false;
    }

    drawThread = GetCurrentThreadId();
    drawMode = requested;
    nextDrawDue = 0;
    return true;
}

Json Status()
{
    return {
        {"mode", drawMode == Mode::Display60 ? "60hz" : "stock"},
        {"supported", drawModule != nullptr}, {"updateHookInstalled", stockUpdate != nullptr},
        {"submitHookInstalled", stockSubmit != nullptr}, {"updateHeartbeats", measuredUpdates},
        {"renderedSubmissions", renderedSubmissions}, {"skippedDraws", skippedDraws},
        {"guardedDraws", guardedDraws}, {"restoreFailures", restoreFailures}
    };
}
} // namespace ShelldiverDrawCadence
