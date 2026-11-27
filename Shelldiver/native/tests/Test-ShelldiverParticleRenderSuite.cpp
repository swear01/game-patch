#include <windows.h>
#include "json.hpp"
#include <algorithm>
#include <array>
#include <cassert>
#include <cmath>
#include <cstring>
#include <cstdint>
#include <map>
#include <set>
#include <string>
#include <string_view>
#include <vector>

using Json = nlohmann::json;
using AurieStatus = int;
struct AurieModule {};
bool AurieSuccess(AurieStatus status) { return status == 0; }
AurieStatus MmCreateHook(AurieModule*, const char*, void*, void*, void**) { return -1; }

enum { VALUE_UNDEFINED, VALUE_BOOL, VALUE_REAL, VALUE_INT32, VALUE_INT64, VALUE_REF, VALUE_STRING };
struct CInstance;
struct RValue
{
    union { std::int64_t m_i64; int m_i32; double m_Real; CInstance* self; };
    int m_Kind = VALUE_UNDEFINED;
    std::string text;
    RValue() : m_i64(0) {}
    explicit RValue(bool value) : m_i32(value), m_Kind(VALUE_BOOL) {}
    explicit RValue(double value) : m_Real(value), m_Kind(VALUE_REAL) {}
    explicit RValue(CInstance* value) : self(value), m_Kind(VALUE_REF) {}
    double ToDouble() const { return m_Kind == VALUE_REAL ? m_Real : m_i32; }
    int ToInt32() const { return static_cast<int>(ToDouble()); }
    bool ToBoolean() const { return ToDouble() != 0; }
    std::string ToString() const { return text; }
};
struct CInstance { std::map<std::string, RValue> fields; };

namespace ShelldiverVisualBudget
{
struct StockSignature { std::size_t rva; std::array<unsigned char,8> bytes; };
template<std::size_t N>
bool VerifyStockSignatures(const unsigned char*, const std::array<StockSignature,N>&) { return false; }
}

std::uint64_t now = 100'000'000;
std::uint64_t WallTicks() { return now; }
const void* mockReturnAddress = nullptr;
#define _ReturnAddress() mockReturnAddress

template<class T>
void Store(unsigned char* bytes, std::size_t offset, const T& value)
{
    std::memcpy(bytes + offset, &value, sizeof(value));
}

constexpr std::size_t drawFlagAddress = 0x10D186B;
struct YYTKInterface
{
    CInstance global;
    CInstance player;
    CInstance* expectedPlayer = &player;
    unsigned char* bytes = nullptr;
    int drawWrites = 0;
    int particleWrites = 0;
    std::string actualRoom = "rm_ocean_magma_03";
    std::map<int, unsigned char*> systems;

    AurieStatus GetGlobalInstance(CInstance** out) { *out = &global; return 0; }
    AurieStatus GetBuiltin(const char* name, CInstance*, int, RValue& out)
    {
        const auto key=std::string_view(name);
        if (key=="room") { out=RValue(actualRoom=="rm_main_island"?4.0:20.0); return 0; }
        if (key=="id") { out=RValue(100005.0); return 0; }
        return -1;
    }
    AurieStatus GetInstanceObject(int id, CInstance*& out)
    {
        out = id==100005 ? expectedPlayer : nullptr;
        return out ? 0 : -1;
    }
    AurieStatus GetInstanceMember(RValue instance, const char* name, RValue*& out)
    {
        const auto found=instance.self->fields.find(name);
        out=found==instance.self->fields.end()?nullptr:&found->second;
        return out ? 0 : -1;
    }
    RValue CallBuiltin(const char* name, const std::vector<RValue>& args)
    {
        const auto key=std::string_view(name);
        if (key=="room_get_name"){
            RValue result;
            result.m_Kind=VALUE_STRING;
            result.text=actualRoom;
            return result;
        }
        if (key=="draw_enable_drawevent"){
            bytes[drawFlagAddress]=args[0].ToBoolean();
            ++drawWrites;
        }
        return {};
    }
    AurieStatus CallBuiltinEx(RValue&, const char* name, CInstance*, CInstance*, const std::vector<RValue>& args)
    {
        assert(args.at(0).m_Kind==VALUE_REF && (args.at(0).m_i64>>32)==0x04000004);
        const auto found=systems.find(args.at(0).m_i32);
        if(found==systems.end()) return -1;
        const auto key=std::string_view(name);
        assert(key=="part_system_automatic_update" || key=="part_system_automatic_draw");
        found->second[key=="part_system_automatic_update"?0x34:0x35]=args[1].ToBoolean();
        ++particleWrites;
        return 0;
    }
};

constexpr int NULL_INDEX = -1;
YYTKInterface* game = nullptr;
std::string room = "rm_ocean_magma_03";
CInstance inputObject, fish;
CInstance* input = &inputObject;
RValue* TryMember(CInstance* object,const char* name)
{
    RValue* found=nullptr;
    return object && AurieSuccess(game->GetInstanceMember(RValue(object),name,found)) ? found : nullptr;
}
std::string CurrentRoom(CInstance*) { return game->actualRoom; }

#include "ShelldiverParticleBudget.hpp"
#include "ShelldiverDrawCadence.hpp"

unsigned heartbeatCalls=0, stockUpdateCalls=0, stockSubmitCalls=0;
void ShelldiverDrawCadence::PublishUpdateHeartbeat() { ++heartbeatCalls; }
void FakeUpdate()
{
    const auto flag=game->bytes[drawFlagAddress];
    assert(flag==1);
    ShelldiverDrawCadence::ObservePlayer(&game->player);
    ShelldiverDrawCadence::ObserveWarning(&fish);
    ++stockUpdateCalls;
}
bool FakeSubmit(bool draw)
{
    ++stockSubmitCalls;
    return draw;
}

int main()
{
    std::vector<unsigned char> image(0x1120000);
    YYTKInterface mock;
    game=&mock;
    mock.bytes=image.data();
    mock.global.fields.insert({
        {"pause",RValue(false)},{"transitioning",RValue(false)},{"in_cutscene",RValue(false)},
        {"player_inventory_open",RValue(false)},{"skill_tree_ui",RValue(false)}
    });
    mock.player.fields.insert({{"can_use_tool",RValue(true)},{"is_inventory_full",RValue(false)},
        {"oxygen",RValue(900.0)},{"oxygen_max",RValue(1000.0)}});
    input->fields.insert({{"interact",RValue(false)},{"open_inventory",RValue(false)},{"open_skilltree",RValue(false)}});
    fish.fields.insert({{"explosion",RValue(false)},{"jellyfish_explosion_icon_alpha",RValue(0.0)},
        {"jellyfish_attack_delay",RValue(0.0)}});

    const char* names[36]{};
    names[28]="ps_skill_can_buy";
    names[27]="ps_skill_buy";
    const char** assets[36]{};
    for(int i=0;i<36;i++) assets[i]=&names[i];
    std::array<unsigned char,0x38> highlight{}, preserved{};
    std::array<unsigned char,0x38> cashEffect{};
    const unsigned char* systems[]={highlight.data(),preserved.data(),cashEffect.data()};
    Store(image.data(),ShelldiverParticleBudget::assetVectorRva,reinterpret_cast<std::uintptr_t>(assets));
    Store(image.data(),ShelldiverParticleBudget::assetVectorRva+8,reinterpret_cast<std::uintptr_t>(assets+36));
    Store(image.data(),ShelldiverParticleBudget::systemsRva+0x30,systems+0);
    Store(image.data(),ShelldiverParticleBudget::systemsRva+0x38,std::size_t(3));
    Store(highlight.data(),0,17);
    Store(highlight.data(),4,28);
    Store(preserved.data(),0,18);
    Store(preserved.data(),4,28);
    Store(cashEffect.data(),0,19);
    Store(cashEffect.data(),4,27);
    highlight[0x34]=1;
    preserved[0x35]=1;
    cashEffect[0x34]=1;
    mock.systems={{17,highlight.data()},{18,preserved.data()},{19,cashEffect.data()}};
    ShelldiverParticleBudget::stockImage=image.data();
    ShelldiverParticleBudget::particleGame=&mock;
    assert(ShelldiverParticleBudget::Supported());
    ShelldiverParticleBudget::Observe(now);
    assert(mock.particleWrites==0);

    mock.actualRoom="rm_main_island";
    mock.global.fields["skill_tree_ui"]=RValue(true);
    assert(ShelldiverParticleBudget::SetSkillHighlightBudget(0));
    assert(highlight[0x34]==1 && preserved[0x35]==1 && mock.particleWrites==0);
    mock.global.fields["skill_tree_ui"]=RValue(false);
    ShelldiverParticleBudget::Observe(++now);
    assert(!highlight[0x34] && !preserved[0x35] && cashEffect[0x34] && mock.particleWrites==2);
    mock.global.fields["skill_tree_ui"]=RValue(true);
    ShelldiverParticleBudget::Observe(++now);
    assert(highlight[0x34] && !highlight[0x35] && !preserved[0x34] && preserved[0x35] && cashEffect[0x34]);
    mock.actualRoom="rm_ocean_magma_03";
    ShelldiverParticleBudget::Observe(++now);
    assert(!highlight[0x34] && !preserved[0x35]);
    assert(ShelldiverParticleBudget::SetSkillHighlightBudget(100));
    assert(highlight[0x34] && preserved[0x35] && cashEffect[0x34]);
    assert(ShelldiverParticleBudget::Status(true)["censusReadable"]==true);

    using namespace ShelldiverDrawCadence;
    drawImage=image.data();
    drawModule=reinterpret_cast<AurieModule*>(1);
    stockUpdate=&FakeUpdate;
    stockSubmit=&FakeSubmit;
    image[drawFlagRva]=1;
    Store(image.data(),timingModeRva,2);
    assert(SetMode(Mode::Display60));
    const auto runUpdate=[&]{
        mockReturnAddress=drawImage+updateReturnRva;
        Update();
    };
    const auto runSubmit=[&](bool drawn){
        mockReturnAddress=drawImage+submitReturnRva;
        return Submit(drawn);
    };
    runUpdate();
    assert(image[drawFlagRva]==1 && nextDrawDue>now);
    ++now;
    runUpdate();
    assert(!image[drawFlagRva] && ownsDisabledDraw && skippedDraws==1);
    assert(!runSubmit(false) && image[drawFlagRva] && !ownsDisabledDraw);
    fish.fields["jellyfish_attack_delay"]=RValue(1.0);
    ++now;
    runUpdate();
    assert(image[drawFlagRva] && guardedDraws==1);
    fish.fields["jellyfish_attack_delay"]=RValue(0.0);
    mock.global.fields["transitioning"]=RValue(true);
    ++now;
    runUpdate();
    assert(image[drawFlagRva] && guardedDraws==2);
    mock.global.fields["transitioning"]=RValue(false);
    input->fields["interact"]=RValue(true);
    ++now;
    runUpdate();
    assert(image[drawFlagRva] && guardedDraws==3);
    input->fields["interact"]=RValue(false);
    ++now;
    runUpdate();
    assert(!image[drawFlagRva] && ownsDisabledDraw);
    mock.actualRoom="rm_main_island";
    ++now;
    runUpdate();
    assert(image[drawFlagRva] && !ownsDisabledDraw && guardedDraws==4);
    assert(SetMode(Mode::Stock));
    ++now;
    runUpdate();
    assert(image[drawFlagRva] && !ownsDisabledDraw && stockUpdateCalls==8 && heartbeatCalls==8);
    puts("PASS: default, exact PSYS28 closure, untouched adjacent PSYS, genuine UI reopen, restore flags, native Update heartbeat, 60Hz skip, warning, transition, return, unknown room, restore-before-next-Update");
}
