// Pal Spawn Groups - mod C++ (UE4SS) para Palworld.
//
// Cada spawner comum de Pals selvagens (BP_PalSpawner_Standard_C) cria um
// grupo sorteado da sua lista em Spawn(SpawnGroup). Este mod:
//   1. limita o tamanho dos grupos comuns (MaxGroupSize, padrão 3);
//   2. logo depois do Spawn original, sorteia outro grupo com a própria
//      LotterySpawnPalListIndex do spawner e chama Spawn de novo, com o
//      spawner deslocado temporariamente (OffsetMin..OffsetMax).
// Nenhum ator novo é criado: os Pals extras entram na lista do próprio
// spawner e somem junto com o Despawn do jogo. Chefes, dungeons, missões e
// spawners raros ficam de fora.

#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <Windows.h>

#include <algorithm>
#include <cmath>
#include <cwctype>
#include <filesystem>
#include <format>
#include <fstream>
#include <random>
#include <string>
#include <vector>

#include <DynamicOutput/DynamicOutput.hpp>
#include <Mod/CppUserModBase.hpp>
#include <Unreal/CoreUObject/UObject/Class.hpp>
#include <Unreal/CoreUObject/UObject/UnrealType.hpp>
#include <Unreal/FFrame.hpp>
#include <Unreal/Hooks/Hooks.hpp>
#include <Unreal/NameTypes.hpp>
#include <Unreal/UObject.hpp>
#include <Unreal/UObjectGlobals.hpp>

using namespace RC;
using namespace RC::Unreal;

namespace
{
    constexpr auto MOD_VERSION = STR("0.1.1");

    // ------------------------------------------------------------------
    // Configuração
    // ------------------------------------------------------------------
    struct Config
    {
        bool Enabled = true;
        int ExtraGroups = 1;       // grupos extras por Spawn (0 a 3)
        int ExtraChance = 100;     // chance (%) de cada grupo extra
        int MaxGroupSize = 3;      // máximo de Pals por grupo (0 = não mexer)
        double OffsetMin = 1500.0; // deslocamento do grupo extra (cm)
        double OffsetMax = 3500.0;
        bool AvoidSameGroup = true;
        bool VerboseLogging = false;
    } g_cfg;

    std::filesystem::path g_modDir;

    auto Trim(std::string s) -> std::string
    {
        auto notSpace = [](unsigned char c) { return !std::isspace(c); };
        s.erase(s.begin(), std::find_if(s.begin(), s.end(), notSpace));
        s.erase(std::find_if(s.rbegin(), s.rend(), notSpace).base(), s.end());
        return s;
    }

    auto ToLowerA(std::string s) -> std::string
    {
        std::transform(s.begin(), s.end(), s.begin(), [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
        return s;
    }

    auto ToLowerW(StringType s) -> StringType
    {
        std::transform(s.begin(), s.end(), s.begin(), [](wchar_t c) { return static_cast<wchar_t>(std::towlower(c)); });
        return s;
    }

    auto Log(const StringType& msg) -> void
    {
        Output::send<LogLevel::Default>(STR("[PalSpawnGroups] {}\n"), msg);
    }

    auto LogV(const StringType& msg) -> void
    {
        if (g_cfg.VerboseLogging) Log(msg);
    }

    auto FindModDir() -> std::filesystem::path
    {
        HMODULE module{};
        GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                           reinterpret_cast<LPCWSTR>(&FindModDir), &module);
        wchar_t buffer[MAX_PATH]{};
        GetModuleFileNameW(module, buffer, MAX_PATH);
        // Mods\PalSpawnGroups\dlls\main.dll -> Mods\PalSpawnGroups
        return std::filesystem::path(buffer).parent_path().parent_path();
    }

    auto LoadConfig() -> void
    {
        std::ifstream file(g_modDir / "config.txt");
        if (!file)
        {
            Log(STR("config.txt não encontrado; usando valores padrão."));
            return;
        }
        std::string line;
        while (std::getline(file, line))
        {
            line = Trim(line);
            if (line.empty() || line[0] == ';' || line[0] == '#') continue;
            auto eq = line.find('=');
            if (eq == std::string::npos) continue;
            auto key = ToLowerA(Trim(line.substr(0, eq)));
            auto value = Trim(line.substr(eq + 1));
            auto lower = ToLowerA(value);
            bool asBool = lower == "true" || lower == "1" || lower == "yes";
            double asNum = std::atof(value.c_str());
            if (key == "enabled") g_cfg.Enabled = asBool;
            else if (key == "extragroups") g_cfg.ExtraGroups = std::clamp(static_cast<int>(asNum), 0, 3);
            else if (key == "extrachance") g_cfg.ExtraChance = std::clamp(static_cast<int>(asNum), 0, 100);
            else if (key == "maxgroupsize") g_cfg.MaxGroupSize = std::clamp(static_cast<int>(asNum), 0, 10);
            else if (key == "offsetmin") g_cfg.OffsetMin = std::max(0.0, asNum);
            else if (key == "offsetmax") g_cfg.OffsetMax = std::max(0.0, asNum);
            else if (key == "avoidsamegroup") g_cfg.AvoidSameGroup = asBool;
            else if (key == "verboselogging") g_cfg.VerboseLogging = asBool;
        }
        if (g_cfg.OffsetMax < g_cfg.OffsetMin) g_cfg.OffsetMax = g_cfg.OffsetMin;
    }

    // ------------------------------------------------------------------
    // Chamada de UFunction por reflexão (parâmetros inicializados e
    // destruídos corretamente, inclusive TArray dentro de structs).
    // ------------------------------------------------------------------
    class ParamBuffer
    {
    public:
        explicit ParamBuffer(UFunction* fn) : m_fn(fn), m_data(std::max<size_t>(fn->GetParmsSize(), 16), 0)
        {
            for (FProperty* p : m_fn->ForEachProperty())
            {
                if (p->HasAnyPropertyFlags(CPF_Parm)) p->InitializeValue_InContainer(m_data.data());
            }
        }
        ~ParamBuffer()
        {
            for (FProperty* p : m_fn->ForEachProperty())
            {
                if (p->HasAnyPropertyFlags(CPF_Parm)) p->DestroyValue_InContainer(m_data.data());
            }
        }
        ParamBuffer(const ParamBuffer&) = delete;
        ParamBuffer& operator=(const ParamBuffer&) = delete;

        auto Prop(const CharType* name) -> FProperty* { return m_fn->FindProperty(FName(name, FNAME_Find)); }
        auto Ptr(const CharType* name) -> uint8*
        {
            auto p = Prop(name);
            return p ? static_cast<uint8*>(p->ContainerPtrToValuePtr<void>(static_cast<void*>(m_data.data()))) : nullptr;
        }
        auto Call(UObject* self) -> void { self->ProcessEvent(m_fn, m_data.data()); }

    private:
        UFunction* m_fn;
        std::vector<uint8> m_data;
    };

    struct RawArray
    {
        uint8* Data;
        int32 Num;
        int32 Max;
    };

    // Offsets de FPalSpawnerGroupInfo / FPalSpawnerOneTribeInfo (structs
    // nativas; lidos por reflexão na primeira vez).
    struct GroupLayout
    {
        bool Ready = false;
        int32 RowName = -1;
        int32 PalList = -1;
        int32 TribeSize = 0;
        int32 Num = -1;
        int32 NumMax = -1;
    } g_layout;

    auto ResolveLayout(FProperty* groupProp) -> bool
    {
        if (g_layout.Ready) return true;
        if (!groupProp) return false;
        auto groupStruct = static_cast<FStructProperty*>(groupProp)->GetStruct();
        if (!groupStruct) return false;
        auto rowProp = groupStruct->FindProperty(FName(STR("OriginalRowName"), FNAME_Find));
        auto listProp = groupStruct->FindProperty(FName(STR("PalList"), FNAME_Find));
        if (!listProp) return false;
        auto inner = static_cast<FArrayProperty*>(listProp)->GetInner();
        if (!inner) return false;
        auto tribeStruct = static_cast<FStructProperty*>(inner)->GetStruct();
        if (!tribeStruct) return false;
        auto numProp = tribeStruct->FindProperty(FName(STR("Num"), FNAME_Find));
        auto numMaxProp = tribeStruct->FindProperty(FName(STR("Num_Max"), FNAME_Find));
        if (!numProp || !numMaxProp) return false;
        g_layout.RowName = rowProp ? rowProp->GetOffset_Internal() : -1;
        g_layout.PalList = listProp->GetOffset_Internal();
        g_layout.TribeSize = inner->GetElementSize();
        g_layout.Num = numProp->GetOffset_Internal();
        g_layout.NumMax = numMaxProp->GetOffset_Internal();
        g_layout.Ready = true;
        Log(std::format(STR("Layout do grupo: PalList +{}, item {} bytes, Num +{}, Num_Max +{}."),
                        g_layout.PalList, g_layout.TribeSize, g_layout.Num, g_layout.NumMax));
        return true;
    }

    // Identifica o grupo pela esp�cie do primeiro Pal (PalId.Key). Os grupos
    // embutidos nos spawners n�o t�m OriginalRowName (fica None).
    auto GroupRowName(uint8* group) -> FName
    {
        if (!group || !g_layout.Ready) return FName();
        auto& list = *reinterpret_cast<RawArray*>(group + g_layout.PalList);
        if (!list.Data || list.Num <= 0 || list.Num > 16) return FName();
        return *reinterpret_cast<FName*>(list.Data);
    }

    // Limita o total de Pals do grupo a MaxGroupSize (pelo menos 1 por espécie).
    auto ClampGroup(uint8* group) -> int
    {
        if (!group || !g_layout.Ready || g_cfg.MaxGroupSize <= 0) return 0;
        auto& list = *reinterpret_cast<RawArray*>(group + g_layout.PalList);
        if (!list.Data || list.Num <= 0 || list.Num > 16) return 0;
        int remaining = g_cfg.MaxGroupSize;
        int changed = 0;
        for (int32 i = 0; i < list.Num; ++i)
        {
            auto entry = list.Data + static_cast<size_t>(i) * g_layout.TribeSize;
            auto& num = *reinterpret_cast<int32*>(entry + g_layout.Num);
            auto& numMax = *reinterpret_cast<int32*>(entry + g_layout.NumMax);
            int reserve = list.Num - 1 - i;
            int cap = std::max(1, remaining - reserve);
            if (numMax > cap) { numMax = cap; ++changed; }
            if (num > numMax) { num = numMax; ++changed; }
            remaining -= std::max(1, numMax);
        }
        return changed;
    }

    auto GroupSize(uint8* group) -> int
    {
        if (!group || !g_layout.Ready) return 0;
        auto& list = *reinterpret_cast<RawArray*>(group + g_layout.PalList);
        if (!list.Data || list.Num <= 0 || list.Num > 16) return 0;
        int total = 0;
        for (int32 i = 0; i < list.Num; ++i)
        {
            total += *reinterpret_cast<int32*>(list.Data + static_cast<size_t>(i) * g_layout.TribeSize + g_layout.NumMax);
        }
        return total;
    }

    // ------------------------------------------------------------------
    // Spawner
    // ------------------------------------------------------------------
    FName g_nameSpawn;
    FName g_nameStandardClass;
    std::mt19937 g_rng{std::random_device{}()};

    struct Stats
    {
        int OriginalSeen = 0;
        int Eligible = 0;
        int Clamped = 0;
        int ExtraSpawned = 0;
        int LotteryFailed = 0;
        int Moved = 0;
        int MoveFailed = 0;
    } g_stats;

    thread_local UObject* t_pendingSpawner = nullptr;
    thread_local FName t_originalRow;
    thread_local bool t_inExtra = false;

    auto IsSpawnFunction(UFunction* fn) -> bool
    {
        if (!fn || fn->GetNamePrivate() != g_nameSpawn) return false;
        auto outer = fn->GetOuterPrivate();
        return outer && outer->GetNamePrivate() == g_nameStandardClass;
    }

    auto HandleCount(UObject* spawner) -> int
    {
        auto arr = spawner->GetValuePtrByPropertyNameInChain<RawArray>(STR("IndividualHandleList"));
        return arr ? arr->Num : -1;
    }

    auto IsEligible(UObject* spawner) -> bool
    {
        auto type = spawner->GetValuePtrByPropertyNameInChain<uint8>(STR("SpawnerType"));
        if (!type || *type != 0) return false; // 0 = Common
        auto className = ToLowerW(spawner->GetClassPrivate()->GetName());
        for (auto bad : {STR("boss"), STR("quest"), STR("debug"), STR("dungeon")})
        {
            if (className.find(bad) != StringType::npos) return false;
        }
        if (auto name = spawner->GetValuePtrByPropertyNameInChain<FName>(STR("SpawnerName")))
        {
            auto sheet = ToLowerW(name->ToString());
            for (auto bad : {STR("boss"), STR("quest"), STR("dungeon")})
            {
                if (sheet.find(bad) != StringType::npos) return false;
            }
        }
        auto fullName = ToLowerW(spawner->GetFullName());
        if (fullName.find(STR("dungeon")) != StringType::npos) return false;
        return true;
    }

    struct Vec3
    {
        double X, Y, Z;
    };

    auto GetLocation(UObject* actor, Vec3& out) -> bool
    {
        auto fn = actor->GetFunctionByNameInChain(STR("K2_GetActorLocation"));
        if (!fn) return false;
        ParamBuffer params(fn);
        params.Call(actor);
        auto ret = params.Ptr(STR("ReturnValue"));
        if (!ret) return false;
        out = *reinterpret_cast<Vec3*>(ret);
        return true;
    }

    auto SetLocation(UObject* actor, const Vec3& loc) -> bool
    {
        auto fn = actor->GetFunctionByNameInChain(STR("K2_SetActorLocation"));
        if (!fn) return false;
        ParamBuffer params(fn);
        auto newLoc = params.Ptr(STR("NewLocation"));
        auto teleport = params.Ptr(STR("bTeleport"));
        if (!newLoc) return false;
        *reinterpret_cast<Vec3*>(newLoc) = loc;
        if (teleport) *teleport = 1;
        params.Call(actor);
        auto ret = params.Ptr(STR("ReturnValue"));
        return ret && *ret != 0;
    }

    auto SpawnExtraGroup(UObject* spawner, int index) -> void
    {
        auto lotteryFn = spawner->GetFunctionByNameInChain(STR("LotterySpawnPalListIndex"));
        auto spawnFn = spawner->GetFunctionByNameInChain(STR("Spawn"));
        if (!lotteryFn || !spawnFn) return;

        ParamBuffer lottery(lotteryFn);
        auto groupProp = lottery.Prop(STR("SpawnGroup"));
        if (!ResolveLayout(groupProp)) return;

        // Sorteio do próprio jogo (respeita horário/clima). Tenta evitar o
        // mesmo grupo do Spawn original.
        uint8* group = nullptr;
        for (int attempt = 0; attempt < 4; ++attempt)
        {
            lottery.Call(spawner);
            auto success = lottery.Ptr(STR("Success"));
            group = lottery.Ptr(STR("SpawnGroup"));
            if (!success || *success == 0 || !group) { group = nullptr; continue; }
            if (!g_cfg.AvoidSameGroup || GroupRowName(group) != t_originalRow) break;
        }
        if (!group)
        {
            ++g_stats.LotteryFailed;
            return;
        }
        ClampGroup(group);

        ParamBuffer spawn(spawnFn);
        auto spawnGroupProp = spawn.Prop(STR("SpawnGroup"));
        auto spawnGroup = spawn.Ptr(STR("SpawnGroup"));
        if (!spawnGroupProp || !spawnGroup) return;
        spawnGroupProp->CopyCompleteValue(spawnGroup, group);

        // Desloca o spawner só durante a chamada, para o grupo extra surgir
        // em outro ponto da área.
        Vec3 original{};
        bool moved = false;
        if (g_cfg.OffsetMax > 0.0 && GetLocation(spawner, original))
        {
            std::uniform_real_distribution<double> angleDist(0.0, 6.283185307179586);
            std::uniform_real_distribution<double> distDist(g_cfg.OffsetMin, g_cfg.OffsetMax);
            double angle = angleDist(g_rng);
            double dist = distDist(g_rng);
            Vec3 target{original.X + std::cos(angle) * dist, original.Y + std::sin(angle) * dist, original.Z};
            moved = SetLocation(spawner, target);
            if (moved) ++g_stats.Moved;
            else ++g_stats.MoveFailed;
        }

        int before = HandleCount(spawner);
        t_inExtra = true;
        spawn.Call(spawner);
        t_inExtra = false;
        int after = HandleCount(spawner);

        if (moved) SetLocation(spawner, original);

        ++g_stats.ExtraSpawned;
        bool detailed = g_cfg.VerboseLogging || g_stats.ExtraSpawned <= 10;
        if (detailed)
        {
            Log(std::format(STR("Grupo extra #{} em {} (folha {}): grupo {} com até {} Pal(s), lista {} -> {}, deslocado: {}."),
                            index + 1, spawner->GetName(),
                            spawner->GetValuePtrByPropertyNameInChain<FName>(STR("SpawnerName"))
                                    ? spawner->GetValuePtrByPropertyNameInChain<FName>(STR("SpawnerName"))->ToString()
                                    : StringType(STR("?")),
                            GroupRowName(group).ToString(), GroupSize(group), before, after,
                            moved ? STR("sim") : STR("não")));
        }
        if (g_stats.ExtraSpawned % 50 == 0)
        {
            Log(std::format(STR("Resumo: {} Spawn(s) originais, {} elegíveis, {} grupos limitados, {} grupos extras, "
                                "{} sorteios sem grupo, deslocamentos {} ok / {} falhas."),
                            g_stats.OriginalSeen, g_stats.Eligible, g_stats.Clamped, g_stats.ExtraSpawned,
                            g_stats.LotteryFailed, g_stats.Moved, g_stats.MoveFailed));
        }
    }

    auto OnSpawnPre(UObject* context, FFrame& stack) -> void
    {
        if (t_inExtra || !context) return;
        ++g_stats.OriginalSeen;
        if (!IsEligible(context)) return;
        ++g_stats.Eligible;

        auto fn = stack.Node();
        auto groupProp = fn->FindProperty(FName(STR("SpawnGroup"), FNAME_Find));
        if (groupProp && ResolveLayout(groupProp) && stack.Locals())
        {
            auto group = static_cast<uint8*>(groupProp->ContainerPtrToValuePtr<void>(static_cast<void*>(stack.Locals())));
            t_originalRow = GroupRowName(group);
            if (ClampGroup(group) > 0) ++g_stats.Clamped;
        }
        t_pendingSpawner = context;
    }

    auto OnSpawnPost(UObject* context) -> void
    {
        if (t_inExtra || !context || t_pendingSpawner != context) return;
        t_pendingSpawner = nullptr;
        std::uniform_int_distribution<int> chance(1, 100);
        for (int i = 0; i < g_cfg.ExtraGroups; ++i)
        {
            if (chance(g_rng) > g_cfg.ExtraChance) continue;
            SpawnExtraGroup(context, i);
        }
    }
} // namespace

class PalSpawnGroups : public CppUserModBase
{
public:
    PalSpawnGroups() : CppUserModBase()
    {
        ModName = STR("PalSpawnGroups");
        ModVersion = MOD_VERSION;
        ModDescription = STR("Mais grupos pequenos de Pals selvagens por spawner comum.");
        ModAuthors = STR("lbcamargo94");
    }

    ~PalSpawnGroups() override = default;

    auto on_unreal_init() -> void override
    {
        g_modDir = FindModDir();
        LoadConfig();
        if (!g_cfg.Enabled)
        {
            Log(std::format(STR("v{} desativado no config.txt."), MOD_VERSION));
            return;
        }
        g_nameSpawn = FName(STR("Spawn"), FNAME_Add);
        g_nameStandardClass = FName(STR("BP_PalSpawner_Standard_C"), FNAME_Add);

        Hook::RegisterProcessLocalScriptFunctionPreCallback(
                [](Hook::TCallbackIterationData<void>&, UObject* context, FFrame& stack, void*) {
                    if (IsSpawnFunction(stack.Node())) OnSpawnPre(context, stack);
                },
                {false, false, STR("PalSpawnGroups"), STR("SpawnPre")});
        Hook::RegisterProcessLocalScriptFunctionPostCallback(
                [](Hook::TCallbackIterationData<void>&, UObject* context, FFrame& stack, void*) {
                    if (IsSpawnFunction(stack.Node())) OnSpawnPost(context);
                },
                {false, false, STR("PalSpawnGroups"), STR("SpawnPost")});

        Log(std::format(STR("v{} carregado: {} grupo(s) extra(s) por spawner comum ({}%), grupos de até {} Pal(s), "
                            "deslocamento {:.0f}-{:.0f} m."),
                        MOD_VERSION, g_cfg.ExtraGroups, g_cfg.ExtraChance, g_cfg.MaxGroupSize,
                        g_cfg.OffsetMin / 100.0, g_cfg.OffsetMax / 100.0));
    }
};

#define PAL_SPAWN_GROUPS_API __declspec(dllexport)
extern "C"
{
    PAL_SPAWN_GROUPS_API CppUserModBase* start_mod()
    {
        return new PalSpawnGroups();
    }

    PAL_SPAWN_GROUPS_API void uninstall_mod(CppUserModBase* mod)
    {
        delete mod;
    }
}
