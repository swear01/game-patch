#pragma once

namespace ShelldiverPresentCadence
{
enum class Mode { Stock, Measure, Display60 };

constexpr std::uint64_t displayInterval = 10000000 / 60;
constexpr UINT ordinaryTearingFlag = 0x200;

std::atomic<Mode> mode{Mode::Stock};
std::atomic<DWORD> gameThread{0};
IDXGISwapChain* chain = nullptr;
DXGI_SWAP_CHAIN_DESC description{};
bool descriptionKnown = false;
DWORD ownerPid = 0;
bool resizeWatchInstalled = false;
bool lastPresentSucceeded = false;
std::uint64_t nextDue = 0;
std::atomic_uint64_t resizeEpoch{0};
std::uint64_t observedResizeEpoch = 0;
std::uint64_t attempts = 0;
std::uint64_t submitted = 0;
std::uint64_t skipped = 0;
std::uint64_t measuredWall = 0;
std::uint64_t measuredCycles = 0;
std::uint64_t failures = 0;
UINT lastSync = 0;
UINT lastFlags = 0;

constexpr std::uint64_t AdvanceDeadline(std::uint64_t deadline, std::uint64_t now)
{
    return deadline != 0 && now >= deadline && now - deadline < displayInterval
        ? deadline + displayInterval : now + displayInterval;
}

bool StockMode2Presentation()
{
    const auto* module = reinterpret_cast<const unsigned char*>(GetModuleHandleW(nullptr));
    if (!module)
        return false;
    const auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(module);
    if (dos->e_magic != IMAGE_DOS_SIGNATURE || dos->e_lfanew < static_cast<LONG>(sizeof(IMAGE_DOS_HEADER)) ||
        dos->e_lfanew > 4096)
        return false;
    const auto* nt = reinterpret_cast<const IMAGE_NT_HEADERS64*>(module + dos->e_lfanew);
    constexpr std::array<unsigned char, 8> pacingBypass{0x8B, 0x05, 0x0C, 0x50, 0x76, 0x00, 0x83, 0xF8};
    constexpr std::array<unsigned char, 8> mode2Present{0xFF, 0x50, 0x40, 0x8B, 0xC8, 0xE8, 0xC2, 0xF8};
    return nt->Signature == IMAGE_NT_SIGNATURE && nt->OptionalHeader.Magic == IMAGE_NT_OPTIONAL_HDR64_MAGIC &&
           nt->OptionalHeader.SizeOfImage > 0x6671FC &&
           std::equal(pacingBypass.begin(), pacingBypass.end(), module + 0x58207A) &&
           std::equal(mode2Present.begin(), mode2Present.end(), module + 0x6671F4);
}

void SetMode(Mode newMode)
{
    gameThread.store(GetCurrentThreadId(), std::memory_order_relaxed);
    nextDue = 0;
    lastPresentSucceeded = false;
    mode.store(newMode, std::memory_order_release);
}

void NoteResize(FWResize&)
{
    resizeEpoch.fetch_add(1, std::memory_order_relaxed);
}

template<class Ready>
void Observe(FWFrame& event, Ready&& ready)
{
    const auto selected = mode.load(std::memory_order_acquire);
    if (selected == Mode::Stock || gameThread.load(std::memory_order_relaxed) != GetCurrentThreadId() || event.CalledOriginal())
        return;
    const auto& [swapChain, sync, flags] = event.Arguments();
    if (!swapChain || (flags & DXGI_PRESENT_TEST))
        return;

    ++attempts;
    lastSync = sync;
    lastFlags = flags;
    const std::uint64_t epoch = resizeEpoch.load(std::memory_order_relaxed);
    if (chain != swapChain || epoch != observedResizeEpoch)
    {
        chain = swapChain;
        observedResizeEpoch = epoch;
        descriptionKnown = SUCCEEDED(swapChain->GetDesc(&description));
        ownerPid = 0;
        if (descriptionKnown && description.OutputWindow)
            GetWindowThreadProcessId(description.OutputWindow, &ownerPid);
        nextDue = 0;
        lastPresentSucceeded = false;
    }

    const auto now = WallTicks();
    const bool normalFlags = flags == 0 || flags == ordinaryTearingFlag;
    const bool bltSwapChain = description.SwapEffect == DXGI_SWAP_EFFECT_DISCARD ||
        description.SwapEffect == DXGI_SWAP_EFFECT_SEQUENTIAL;
    const bool supportedPresentation = descriptionKnown && bltSwapChain && description.Windowed &&
        ownerPid == GetCurrentProcessId() && sync == 0 && normalFlags;
    const bool capped = selected == Mode::Display60 && supportedPresentation &&
                        now != 0 && std::forward<Ready>(ready)();
    BOOL fullscreen = TRUE;
    if (capped && lastPresentSucceeded && nextDue && now < nextDue &&
        SUCCEEDED(swapChain->GetFullscreenState(&fullscreen, nullptr)) && !fullscreen)
    {
        // Draw has completed. Keep the previous visible presentation until a real refresh is due.
        event.Override(S_OK);
        ++skipped;
        return;
    }

    ULONGLONG beforeCycles = 0;
    QueryThreadCycleTime(GetCurrentThread(), &beforeCycles);
    const auto hr = event.Call();
    ULONGLONG afterCycles = 0;
    if (beforeCycles && QueryThreadCycleTime(GetCurrentThread(), &afterCycles) && afterCycles >= beforeCycles)
        measuredCycles += afterCycles - beforeCycles;
    const auto ended = WallTicks();
    if (ended >= now)
        measuredWall += ended - now;
    ++submitted;
    lastPresentSucceeded = hr == S_OK;
    if (!lastPresentSucceeded)
        ++failures;
    nextDue = capped && lastPresentSucceeded ? AdvanceDeadline(nextDue, now) : 0;
}

Json Stats()
{
    const auto selected = mode.load(std::memory_order_acquire);
    const char* modeLabel = selected == Mode::Display60 ? "60hz" : selected == Mode::Measure ? "measure" : "stock";
    return {
        {"mode", modeLabel}, {"stockMode2Presentation", StockMode2Presentation()},
        {"resizeWatchInstalled", resizeWatchInstalled},
        {"observed", attempts}, {"submitted", submitted}, {"skipped", skipped},
        {"submitWallTicks100ns", measuredWall}, {"submitCycles", measuredCycles},
        {"nonSuccessStatuses", failures}, {"lastSyncInterval", lastSync}, {"lastFlags", lastFlags},
        {"windowed", descriptionKnown && description.Windowed}, {"resizeEpoch", observedResizeEpoch},
        {"swapEffect", descriptionKnown ? int(description.SwapEffect) : -1}
    };
}
} // namespace ShelldiverPresentCadence
