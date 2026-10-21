// Pal Transport Boost - mod C++ (UE4SS) para Palworld.
//
// O transporte de itens na base é coordenado pelo
// UPalBaseCampModuleTransportItemDirector: para cada Pal transportando há uma
// FPalBaseCampModuleTransportItemDirection com MaxItemStackNum (quantas
// pilhas ele leva por viagem). Este mod multiplica esse valor sempre que o
// diretor atribui ou atualiza um transporte.
//
// Também grava uma vez (data_dump.txt) as tabelas da mesa de cirurgia e das
// lojas, usadas para gerar os mods PalSchema de itens.

#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <Windows.h>

#include <algorithm>
#include <cmath>
#include <filesystem>
#include <format>
#include <fstream>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include <DynamicOutput/DynamicOutput.hpp>
#include <Helpers/String.hpp>
#include <Mod/CppUserModBase.hpp>
#include <Unreal/Core/Containers/Map.hpp>
#include <Unreal/CoreUObject/UObject/Class.hpp>
#include <Unreal/CoreUObject/UObject/UnrealType.hpp>
#include <Unreal/Engine/UDataTable.hpp>
#include <Unreal/FFrame.hpp>
#include <Unreal/Hooks/Hooks.hpp>
#include <Unreal/NameTypes.hpp>
#include <Unreal/UObject.hpp>
#include <Unreal/UObjectArray.hpp>
#include <Unreal/UObjectGlobals.hpp>

using namespace RC;
using namespace RC::Unreal;

namespace
{
    constexpr auto MOD_VERSION = STR("0.1.1");
    constexpr auto DIRECTOR_CLASS = STR("/Script/Pal.PalBaseCampModuleTransportItemDirector");

    struct Config
    {
        bool Enabled = true;
        double StackMultiplier = 3.0; // pilhas por viagem = original x multiplicador
        int MaxStacks = 20;           // teto de pilhas por viagem
        bool DumpData = true;
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

    auto Log(const StringType& msg) -> void
    {
        Output::send<LogLevel::Default>(STR("[PalTransportBoost] {}\n"), msg);
    }

    auto FindModDir() -> std::filesystem::path
    {
        HMODULE module{};
        GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                           reinterpret_cast<LPCWSTR>(&FindModDir), &module);
        wchar_t buffer[MAX_PATH]{};
        GetModuleFileNameW(module, buffer, MAX_PATH);
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
            else if (key == "stackmultiplier") g_cfg.StackMultiplier = std::clamp(asNum, 1.0, 20.0);
            else if (key == "maxstacks") g_cfg.MaxStacks = std::clamp(static_cast<int>(asNum), 1, 100);
            else if (key == "dumpdata") g_cfg.DumpData = asBool;
            else if (key == "verboselogging") g_cfg.VerboseLogging = asBool;
        }
    }

    // ------------------------------------------------------------------
    // Transporte
    // ------------------------------------------------------------------
    struct TransportLayout
    {
        bool Ready = false;
        bool Failed = false;
        int32 StatusMapOffset = 0;
        FScriptMapLayout StatusLayout{};
        int32 DirectionMapOffset = 0;
        FScriptMapLayout DirectionLayout{};
        int32 MaxStackOffset = 0;
    } g_layout;

    auto ResolveLayout(UObject* director) -> bool
    {
        if (g_layout.Ready) return true;
        if (g_layout.Failed) return false;
        g_layout.Failed = true; // só tenta uma vez
        auto statusMap = static_cast<FMapProperty*>(director->GetPropertyByNameInChain(STR("TransportItemStatusMap")));
        if (!statusMap) { Log(STR("TransportItemStatusMap não encontrado.")); return false; }
        auto statusValue = static_cast<FStructProperty*>(statusMap->GetValueProp());
        auto statusStruct = statusValue ? statusValue->GetStruct() : nullptr;
        if (!statusStruct) { Log(STR("Struct do status não encontrada.")); return false; }
        auto directionMap = static_cast<FMapProperty*>(statusStruct->FindProperty(FName(STR("DirectionMap"), FNAME_Find)));
        if (!directionMap) { Log(STR("DirectionMap não encontrado.")); return false; }
        auto directionValue = static_cast<FStructProperty*>(directionMap->GetValueProp());
        auto directionStruct = directionValue ? directionValue->GetStruct() : nullptr;
        if (!directionStruct) { Log(STR("Struct da direção não encontrada.")); return false; }
        auto maxStack = directionStruct->FindProperty(FName(STR("MaxItemStackNum"), FNAME_Find));
        if (!maxStack) { Log(STR("MaxItemStackNum não encontrado.")); return false; }

        g_layout.StatusMapOffset = statusMap->GetOffset_Internal();
        g_layout.StatusLayout = statusMap->GetMapLayout();
        g_layout.DirectionMapOffset = directionMap->GetOffset_Internal();
        g_layout.DirectionLayout = directionMap->GetMapLayout();
        g_layout.MaxStackOffset = maxStack->GetOffset_Internal();
        g_layout.Ready = true;
        g_layout.Failed = false;
        Log(std::format(STR("Layout do transporte: status +{}, direções +{}, MaxItemStackNum +{}."),
                        g_layout.StatusMapOffset, g_layout.DirectionMapOffset, g_layout.MaxStackOffset));
        return true;
    }

    template <typename Fn>
    auto ForEachMapValue(void* mapPtr, const FScriptMapLayout& layout, Fn&& fn) -> void
    {
        auto map = static_cast<FScriptMap*>(mapPtr);
        int32 maxIndex = map->GetMaxIndex();
        if (maxIndex < 0 || maxIndex > 100000) return;
        for (int32 i = 0; i < maxIndex; ++i)
        {
            if (!map->IsValidIndex(i)) continue;
            auto pair = static_cast<uint8*>(map->GetData(i, layout));
            fn(pair + layout.ValueOffset);
        }
    }

    // [endereço do MaxItemStackNum] = valor que o mod escreveu
    std::unordered_map<int32*, int32> g_written;
    int g_boosted = 0;
    int g_logged = 0;

    // Diagnóstico (v0.1.1): o que existe nos mapas do diretor.
    struct Census
    {
        int Statuses = 0;
        int Directions = 0;
        std::unordered_map<int32, int> Values;
    } g_census;
    double g_lastCensusLog = -1000.0;
    int g_censusLogs = 0;

    auto BoostDirector(UObject* director) -> void
    {
        if (!director || !ResolveLayout(director)) return;
        auto statusMap = reinterpret_cast<uint8*>(director) + g_layout.StatusMapOffset;
        ForEachMapValue(statusMap, g_layout.StatusLayout, [](uint8* status) {
            ++g_census.Statuses;
            ForEachMapValue(status + g_layout.DirectionMapOffset, g_layout.DirectionLayout, [](uint8* direction) {
                auto value = reinterpret_cast<int32*>(direction + g_layout.MaxStackOffset);
                int32 current = *value;
                ++g_census.Directions;
                ++g_census.Values[current];
                if (auto it = g_written.find(value); it != g_written.end() && it->second == current) return;
                if (current <= 0 || current > 1000) return;
                int32 boosted = std::clamp(static_cast<int32>(std::lround(current * g_cfg.StackMultiplier)), current, g_cfg.MaxStacks);
                if (boosted <= current)
                {
                    g_written[value] = current;
                    return;
                }
                *value = boosted;
                g_written[value] = boosted;
                ++g_boosted;
                if (g_cfg.VerboseLogging || g_logged < 10)
                {
                    ++g_logged;
                    Log(std::format(STR("Transporte: {} -> {} pilha(s) por viagem (total ajustado: {})."), current, boosted, g_boosted));
                }
            });
        });
        if (g_written.size() > 4096) g_written.clear();
    }

    struct TrackedObject
    {
        UObject* Object;
        int32 Index;
    };
    std::vector<TrackedObject> g_directors;

    auto IsAlive(const TrackedObject& t) -> bool
    {
        auto item = UObjectArray::IndexToObject(t.Index);
        return item && item->GetUObject() == t.Object && !item->IsUnreachable() && !item->IsPendingKill();
    }

    auto TrackDirector(UObject* director) -> void
    {
        if (!director) return;
        for (auto& t : g_directors)
        {
            if (t.Object == director) return;
        }
        g_directors.push_back({director, director->GetInternalIndex()});
        Log(std::format(STR("Diretor de transporte encontrado: {} ({} acompanhado(s))."), director->GetName(), g_directors.size()));
    }

    auto OnDirectorEvent(UnrealScriptFunctionCallableContext& context, void*) -> void
    {
        if (!context.Context) return;
        TrackDirector(context.Context);
        BoostDirector(context.Context);
    }

    bool g_hooksRegistered = false;
    auto RegisterHooks() -> bool
    {
        int count = 0;
        for (auto fnName : {STR("OnAssignWorkTransportItemTarget"), STR("OnAssignWorkRequirement"), STR("OnUpdateMapObjectContainer")})
        {
            auto path = std::format(STR("{}:{}"), DIRECTOR_CLASS, fnName);
            auto fn = UObjectGlobals::StaticFindObject<UFunction*>(nullptr, nullptr, path);
            if (!fn) continue;
            UObjectGlobals::RegisterHook(fn, [](UnrealScriptFunctionCallableContext&, void*) {}, OnDirectorEvent, nullptr);
            ++count;
        }
        Log(std::format(STR("{} gancho(s) do diretor de transporte registrados."), count));
        return count > 0;
    }

    // ------------------------------------------------------------------
    // Dump das tabelas (uma vez)
    // ------------------------------------------------------------------
    auto Utf8(const StringType& s) -> std::string
    {
        return to_utf8_string(s);
    }

    auto FieldString(UScriptStruct* rowStruct, uint8* row, const CharType* field) -> std::string
    {
        auto prop = rowStruct->FindProperty(FName(field, FNAME_Find));
        if (!prop) return "?";
        auto ptr = row + prop->GetOffset_Internal();
        auto className = prop->GetClass().GetName();
        if (className == STR("NameProperty")) return Utf8(reinterpret_cast<FName*>(ptr)->ToString());
        if (className == STR("IntProperty")) return std::to_string(*reinterpret_cast<int32*>(ptr));
        if (className == STR("FloatProperty")) return std::to_string(*reinterpret_cast<float*>(ptr));
        if (className == STR("ByteProperty") || className == STR("EnumProperty")) return std::to_string(*ptr);
        if (className == STR("StructProperty"))
        {
            // FPalDataTableRowName_*: struct com um FName "Key" no início.
            return Utf8(reinterpret_cast<FName*>(ptr)->ToString());
        }
        return Utf8(std::format(STR("<{}>"), className));
    }

    auto DumpTables() -> void
    {
        std::vector<UObject*> tables;
        UObjectGlobals::FindAllOf(STR("DataTable"), tables);
        std::ofstream out(g_modDir / "data_dump.txt", std::ios::binary);
        out << "# Pal Transport Boost - dump das tabelas (" << Utf8(MOD_VERSION) << ")\n";
        int dumped = 0;
        for (auto obj : tables)
        {
            auto name = obj->GetName();
            bool surgery = name.starts_with(STR("DT_OperatingTablePassiveSkillDataTable"));
            bool shop = name.starts_with(STR("DT_ItemShopCreateData"));
            bool shopSetting = name.starts_with(STR("DT_ItemShopSettingData"));
            bool items = name == STR("DT_ItemDataTable");
            if (!surgery && !shop && !shopSetting && !items) continue;
            auto dt = static_cast<UDataTable*>(obj);
            UScriptStruct* rowStruct = dt->GetRowStruct().Get();
            if (!rowStruct) continue;
            auto& rows = dt->GetRowMap();
            out << "\n== " << Utf8(obj->GetFullName()) << " (" << rows.Num() << " linhas)\n";
            ++dumped;
            int stackable = 0;
            for (auto& pair : rows)
            {
                auto rowName = Utf8(pair.Key.ToString());
                auto row = pair.Value;
                if (surgery)
                {
                    out << rowName << "\tPassiveSkill=" << FieldString(rowStruct, row, STR("PassiveSkill"))
                        << "\tPrice=" << FieldString(rowStruct, row, STR("Price"))
                        << "\tRequireItemId=" << FieldString(rowStruct, row, STR("RequireItemId")) << "\n";
                }
                else if (shopSetting)
                {
                    out << rowName << "\tCurrencyItemID=" << FieldString(rowStruct, row, STR("CurrencyItemID")) << "\n";
                }
                else if (shop)
                {
                    auto arrProp = static_cast<FArrayProperty*>(rowStruct->FindProperty(FName(STR("productDataArray"), FNAME_Find)));
                    std::string products;
                    int n = 0;
                    if (arrProp)
                    {
                        auto inner = static_cast<FStructProperty*>(arrProp->GetInner());
                        auto innerStruct = inner ? inner->GetStruct() : nullptr;
                        auto idProp = innerStruct ? innerStruct->FindProperty(FName(STR("StaticItemId"), FNAME_Find)) : nullptr;
                        struct RawArray { uint8* Data; int32 Num; int32 Max; };
                        auto& arr = *reinterpret_cast<RawArray*>(row + arrProp->GetOffset_Internal());
                        n = arr.Num;
                        if (idProp && arr.Data && arr.Num > 0 && arr.Num < 1000)
                        {
                            for (int32 i = 0; i < arr.Num; ++i)
                            {
                                auto id = reinterpret_cast<FName*>(arr.Data + static_cast<size_t>(i) * inner->GetElementSize() + idProp->GetOffset_Internal());
                                if (i) products += ",";
                                products += Utf8(id->ToString());
                            }
                        }
                    }
                    out << rowName << "\t" << n << " produto(s)\t" << products << "\n";
                }
                else if (items)
                {
                    auto stackProp = rowStruct->FindProperty(FName(STR("MaxStackCount"), FNAME_Find));
                    int32 stack = stackProp ? *reinterpret_cast<int32*>(row + stackProp->GetOffset_Internal()) : -1;
                    if (stack > 1) ++stackable;
                    if (rowName.starts_with("PalPassiveSkillChange"))
                        out << rowName << "\tMaxStackCount=" << stack << "\tTypeA=" << FieldString(rowStruct, row, STR("TypeA"))
                            << "\tTypeB=" << FieldString(rowStruct, row, STR("TypeB")) << "\n";
                }
            }
            if (items) out << "(itens empilháveis: " << stackable << ")\n";
        }
        Log(std::format(STR("Dump de {} tabela(s) gravado em data_dump.txt."), dumped));
    }

    // ------------------------------------------------------------------
    // Agendador no game thread (EngineTick)
    // ------------------------------------------------------------------
    double g_clock = 0.0;
    double g_nextHookTry = 2.0;
    double g_nextDumpTry = 10.0;
    double g_nextBoost = 1.0;
    bool g_dumped = false;

    auto OnTick(float deltaSeconds) -> void
    {
        g_clock += std::clamp(static_cast<double>(deltaSeconds), 0.0, 1.0);

        if (!g_hooksRegistered && g_clock >= g_nextHookTry)
        {
            g_nextHookTry = g_clock + 5.0;
            g_hooksRegistered = RegisterHooks();
        }

        if (g_cfg.DumpData && !g_dumped && g_clock >= g_nextDumpTry)
        {
            g_nextDumpTry = g_clock + 10.0;
            if (UObjectGlobals::FindFirstOf(STR("PalPlayerCharacter")))
            {
                g_dumped = true;
                DumpTables();
            }
        }

        // O jogo pode recriar as direções sem disparar os ganchos: confere os
        // diretores conhecidos a cada segundo (só os vivos, sem busca global).
        if (g_clock >= g_nextBoost)
        {
            g_nextBoost = g_clock + 1.0;
            g_directors.erase(std::remove_if(g_directors.begin(), g_directors.end(), [](const TrackedObject& t) { return !IsAlive(t); }),
                              g_directors.end());
            for (auto& t : g_directors) BoostDirector(t.Object);

            if (g_censusLogs < 20 && g_clock - g_lastCensusLog >= 30.0 && !g_directors.empty())
            {
                g_lastCensusLog = g_clock;
                ++g_censusLogs;
                StringType values;
                for (auto& [v, n] : g_census.Values) values += std::format(STR("{}={}x "), v, n);
                Log(std::format(STR("Diagnóstico (30 s): {} diretor(es), {} status, {} direção(ões); MaxItemStackNum vistos: {}; ajustes: {}."),
                                g_directors.size(), g_census.Statuses, g_census.Directions, values.empty() ? StringType(STR("nenhum")) : values,
                                g_boosted));
                g_census = Census{};
            }
        }
    }
} // namespace

class PalTransportBoost : public CppUserModBase
{
public:
    PalTransportBoost() : CppUserModBase()
    {
        ModName = STR("PalTransportBoost");
        ModVersion = MOD_VERSION;
        ModDescription = STR("Pals transportadores levam mais pilhas de itens por viagem na base.");
        ModAuthors = STR("lbcamargo94");
    }

    ~PalTransportBoost() override = default;

    auto on_unreal_init() -> void override
    {
        g_modDir = FindModDir();
        LoadConfig();
        if (!g_cfg.Enabled && !g_cfg.DumpData)
        {
            Log(std::format(STR("v{} desativado no config.txt."), MOD_VERSION));
            return;
        }
        if (!g_cfg.Enabled) g_hooksRegistered = true; // só o dump

        Hook::RegisterEngineTickPreCallback(
                [](Hook::TCallbackIterationData<void>&, UEngine*, float deltaSeconds, bool) { OnTick(deltaSeconds); },
                {false, false, STR("PalTransportBoost"), STR("Tick")});

        Log(std::format(STR("v{} carregado: transporte x{:.1f} (até {} pilha(s) por viagem){}."), MOD_VERSION,
                        g_cfg.StackMultiplier, g_cfg.MaxStacks, g_cfg.Enabled ? STR("") : STR(" [desativado, só dump]")));
    }
};

#define PAL_TRANSPORT_BOOST_API __declspec(dllexport)
extern "C"
{
    PAL_TRANSPORT_BOOST_API CppUserModBase* start_mod()
    {
        return new PalTransportBoost();
    }

    PAL_TRANSPORT_BOOST_API void uninstall_mod(CppUserModBase* mod)
    {
        delete mod;
    }
}
