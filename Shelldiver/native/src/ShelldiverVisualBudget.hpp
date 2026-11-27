#pragma once

namespace ShelldiverVisualBudget
{
// These signatures locate the verified stock bubble trail timer and particle call.
struct StockSignature
{
    std::size_t rva;
    std::array<unsigned char, 8> bytes;
};

constexpr std::array<StockSignature, 3> stockSignatures{{
    {0xE159B, {0x8B, 0x15, 0x37, 0xE5, 0xC9, 0x00, 0x49, 0x8B}},
    {0xE2B06, {0x8B, 0x15, 0xCC, 0xCF, 0xC9, 0x00, 0xFF, 0x50}},
    {0xE2D94, {0xE8, 0x77, 0x52, 0xF6, 0xFF, 0x48, 0x8B, 0xD0}}
}};

constexpr std::array<StockSignature, 4> coralSignatures{{
    {0x3D887F, {0x8B, 0x15, 0x13, 0x32, 0x9A, 0x00, 0xFF, 0x50}},
    {0x3D90E1, {0x48, 0xB8, 0x04, 0x00, 0x00, 0x00, 0x0B, 0x00}},
    {0x3D913A, {0xE8, 0xD1, 0x20, 0x0F, 0x00, 0x48, 0x8B, 0xD0}},
    {0x3DA5C1, {0xE8, 0xDA, 0x4B, 0x10, 0x00, 0x90, 0x48, 0x8B}}
}};

constexpr std::string_view coralStepEvent = "gml_Object_par_bubble_coral_Step_0";
constexpr std::string_view bubbleCreateEvent = "gml_Object_o_bubble_projectile_Create_0";
constexpr double suppressedTrailTimer = -4096.0;
YYTKInterface* visualGame = nullptr;
int densityPercent = 100;
int coralDensityPercent = 100;
bool coralStockVerified = false;
std::uint64_t observedCoralSteps = 0;
std::uint64_t suppressedCoralSteps = 0;
std::uint64_t unavailableCoralSteps = 0;
std::uint64_t observedProjectiles = 0;
std::uint64_t suppressedTrails = 0;
std::uint64_t unavailableTrails = 0;

template <std::size_t N>
bool VerifyStockSignatures(const unsigned char* image, const std::array<StockSignature, N>& signatures)
{
    if (!image)
        return false;
    const auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(image);
    if (dos->e_magic != IMAGE_DOS_SIGNATURE || dos->e_lfanew < static_cast<LONG>(sizeof(IMAGE_DOS_HEADER)) ||
        dos->e_lfanew > 4096)
        return false;
    const auto* nt = reinterpret_cast<const IMAGE_NT_HEADERS64*>(image + dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE ||
        nt->OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR64_MAGIC ||
        nt->OptionalHeader.SizeOfImage < signatures.back().rva + signatures.back().bytes.size())
        return false;

    for (const auto& signature : signatures)
        if (!std::equal(signature.bytes.begin(), signature.bytes.end(), image + signature.rva))
            return false;
    return true;
}

void Install(YYTKInterface* gameInterface)
{
    const auto* image = reinterpret_cast<const unsigned char*>(GetModuleHandleW(nullptr));
    visualGame = VerifyStockSignatures(image, stockSignatures) ? gameInterface : nullptr;
    coralStockVerified = visualGame && VerifyStockSignatures(image, coralSignatures);
}

bool SetDensities(int bubblePercent, int coralPercent)
{
    if (bubblePercent < 0 || bubblePercent > 100 ||
        coralPercent < 0 || coralPercent > 100 ||
        (!visualGame && bubblePercent != 100) ||
        (!coralStockVerified && coralPercent != 100))
        return false;

    densityPercent = bubblePercent;
    coralDensityPercent = coralPercent;
    return true;
}

constexpr bool KeepsTrail(std::uint32_t projectileOrdinal, int percent)
{
    const auto mixed = projectileOrdinal * std::uint32_t{2654435761u};
    const auto bucket = (std::uint64_t{mixed} * 100) >> 32;
    return bucket < static_cast<unsigned int>(percent);
}

double ReadCoralGeneratorCount(const RValue& slot)
{
    switch (slot.m_Kind)
    {
    case VALUE_REAL: return slot.m_Real;
    case VALUE_INT32: return slot.m_i32;
    case VALUE_INT64: return static_cast<double>(slot.m_i64);
    default: return 0.0;
    }
}

struct RestoreCoralGeneratorCount
{
    RValue& value;
    std::uint64_t previousValue = 0;

    explicit RestoreCoralGeneratorCount(RValue& slot) : value(slot)
    {
        std::memcpy(&previousValue, &value, sizeof(previousValue));
        std::memset(&value, 0, sizeof(previousValue));
    }

    ~RestoreCoralGeneratorCount()
    {
        std::memcpy(&value, &previousValue, sizeof(previousValue));
    }
};

void ApplyCoralStep(FWCodeEvent& event, CInstance* self)
{
    ++observedCoralSteps;
    if (!coralStockVerified || coralDensityPercent == 100)
        return;

    // A stable per-instance selection retains complete ambient trails for selected corals.
    const auto address = reinterpret_cast<std::uintptr_t>(self);
    const auto bucketKey = static_cast<std::uint32_t>((address >> 5) ^ (address >> 32));
    if (KeepsTrail(bucketKey, coralDensityPercent))
        return;

    RValue* generators = nullptr;
    if (event.CalledOriginal() ||
        !AurieSuccess(visualGame->GetInstanceMember(RValue(self), "bubble_generators_n", generators)) ||
        !generators)
    {
        ++unavailableCoralSteps;
        return;
    }
    const auto count = ReadCoralGeneratorCount(*generators);
    if (!(count >= 1.0 && count <= 32.0 && count == std::floor(count)))
    {
        ++unavailableCoralSteps;
        return;
    }

    // Stock still ages old particles. A zero loop bound only suppresses new ambient births.
    RestoreCoralGeneratorCount restore(*generators);
    event.Call();
    ++suppressedCoralSteps;
}

void Apply(FWCodeEvent& event, CInstance* self, std::string_view eventName)
{
    if (!visualGame || !self)
        return;
    if (eventName == coralStepEvent)
    {
        ApplyCoralStep(event, self);
        return;
    }
    if (eventName != bubbleCreateEvent)
        return;

    ++observedProjectiles;
    if (densityPercent == 100)
        return;

    if (KeepsTrail(static_cast<std::uint32_t>(observedProjectiles), densityPercent))
        return;

    // Preserve the stock Create event. Its initialized cosmetic timer is the only write.
    if (!event.CalledOriginal())
        event.Call();

    RValue* timer = nullptr;
    if (!AurieSuccess(visualGame->GetInstanceMember(RValue(self), "delay_trail_vfx", timer)) ||
        !timer || timer->m_Kind != VALUE_REAL || timer->m_Real != 0.0)
    {
        ++unavailableTrails;
        return;
    }
    timer->m_Real = suppressedTrailTimer;
    ++suppressedTrails;
}

Json Stats()
{
    return {
        {"supported", visualGame != nullptr},
        {"densityPercent", densityPercent},
        {"coralSupported", coralStockVerified},
        {"coralDensityPercent", coralDensityPercent},
        {"coralStepsObserved", observedCoralSteps},
        {"coralStepsSuppressed", suppressedCoralSteps},
        {"coralStepsUnavailable", unavailableCoralSteps},
        {"bubbleProjectilesObserved", observedProjectiles},
        {"bubbleTrailsSuppressed", suppressedTrails},
        {"bubbleTrailsUnavailable", unavailableTrails}
    };
}
} // namespace ShelldiverVisualBudget
