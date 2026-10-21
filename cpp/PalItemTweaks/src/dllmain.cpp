// Pal Item Tweaks - mod C++ (UE4SS) para Palworld.
//
// O jogo não lê o limite de pilha da DT_ItemDataTable em tempo de jogo: ele
// monta um UPalStaticItemDataBase por item (UPalStaticItemDataAsset::
// StaticItemDataMap) e usa esses objetos. Por isso a edição da tabela pelo
// PalSchema não teve efeito. Este mod altera os próprios objetos:
//   - MaxStackCount > 1  -> StackSize (padrão 999999);
//   - implantes consumíveis (TypeB ConsumePassiveSkillChange) -> essenciais,
//     com bNotConsumed, como os implantes permanentes do jogo.
// Reaplica a cada 30 s (só percorre o mapa de itens, sem busca global).

#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <Windows.h>

#include <algorithm>
#include <filesystem>
#include <format>
#include <fstream>
#include <string>

#include <DynamicOutput/DynamicOutput.hpp>
#include <Helpers/String.hpp>
#include <Mod/CppUserModBase.hpp>
#include <Unreal/Engine/UDataTable.hpp>
#include <Unreal/FText.hpp>
#include <Unreal/FMemory.hpp>
#include <atomic>
#include <cmath>
#include <cstring>
#include <mutex>
#include <random>
#include <unordered_set>
#include <vector>
#include <Unreal/Core/Containers/Map.hpp>
#include <Unreal/CoreUObject/UObject/Class.hpp>
#include <Unreal/CoreUObject/UObject/UnrealType.hpp>
#include <Unreal/Hooks/Hooks.hpp>
#include <Unreal/NameTypes.hpp>
#include <Unreal/UObject.hpp>
#include <Unreal/UObjectArray.hpp>
#include <Unreal/UObjectGlobals.hpp>

using namespace RC;
using namespace RC::Unreal;

namespace
{
    constexpr auto MOD_VERSION = STR("0.5.2");

    // EPalItemTypeA / EPalItemTypeB (Pal_enums.hpp do dump de cabeçalhos)
    constexpr uint8 TYPEA_ESSENTIAL = 9;
    constexpr uint8 TYPEB_ESSENTIAL_PASSIVE_CHANGE = 70;
    constexpr uint8 TYPEB_CONSUME_PASSIVE_CHANGE = 72;
    constexpr uint8 TYPEB_ESSENTIAL = 54;

    struct Config
    {
        bool Enabled = true;
        int StackSize = 999999;
        bool PermanentImplants = true;
        int ReviveTimePercent = 10; // tempo de reviver na caixa de Pals (% do original)
        int RankUpPercent = 50;     // Pals consumidos na máquina de condensação (% do original)
        std::vector<StringType> WeightlessItems{STR("Money"), STR("DogCoin")};
        std::vector<StringType> EssentialItems{STR("DogCoin")};
        bool AutoLoot = true;            // itens que caem perto vão direto para o inventário
        double AutoLootRange = 1500.0;   // cm (15 m)
        bool AutoLootOutsideBaseOnly = true;
        double AutoLootBaseMargin = 500.0; // cm além do raio da base
        std::vector<StringType> ReturnToCommonItems{STR("Money")}; // saem da aba de importantes
        bool SortEssentials = true;      // itens importantes do inventário comum -> aba de importantes
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
        Output::send<LogLevel::Default>(STR("[PalItemTweaks] {}\n"), msg);
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

    auto SplitList(const std::string& value) -> std::vector<StringType>
    {
        std::vector<StringType> out;
        size_t start = 0;
        while (start <= value.size())
        {
            auto comma = value.find(',', start);
            auto part = Trim(value.substr(start, comma == std::string::npos ? std::string::npos : comma - start));
            if (!part.empty()) out.push_back(StringType(part.begin(), part.end()));
            if (comma == std::string::npos) break;
            start = comma + 1;
        }
        return out;
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
            else if (key == "stacksize") g_cfg.StackSize = std::clamp(static_cast<int>(asNum), 0, 999999);
            else if (key == "permanentimplants") g_cfg.PermanentImplants = asBool;
            else if (key == "autoloot") g_cfg.AutoLoot = asBool;
            else if (key == "autolootrange") g_cfg.AutoLootRange = std::clamp(asNum, 100.0, 10000.0);
            else if (key == "autolootoutsidebaseonly") g_cfg.AutoLootOutsideBaseOnly = asBool;
            else if (key == "returntocommonitems") g_cfg.ReturnToCommonItems = SplitList(value);
            else if (key == "sortessentials") g_cfg.SortEssentials = asBool;
            else if (key == "weightlessitems") g_cfg.WeightlessItems = SplitList(value);
            else if (key == "essentialitems") g_cfg.EssentialItems = SplitList(value);
            else if (key == "rankuppercent") g_cfg.RankUpPercent = std::clamp(static_cast<int>(asNum), 1, 100);
            else if (key == "revivetimepercent") g_cfg.ReviveTimePercent = std::clamp(static_cast<int>(asNum), 1, 100);
            else if (key == "verboselogging") g_cfg.VerboseLogging = asBool;
        }
    }

    // Offsets lidos por reflexão na primeira vez.
    struct ItemLayout
    {
        bool Ready = false;
        bool Failed = false;
        int32 MapOffset = 0;
        FScriptMapLayout MapLayout{};
        int32 MaxStack = -1;
        int32 TypeA = -1;
        int32 TypeB = -1;
        int32 NotConsumed = -1;
        int32 Weight = -1;
        uint8 NotConsumedMask = 0xFF;
    } g_layout;

    auto ResolveLayout(UObject* asset) -> bool
    {
        if (g_layout.Ready) return true;
        if (g_layout.Failed) return false;
        g_layout.Failed = true;
        auto mapProp = static_cast<FMapProperty*>(asset->GetPropertyByNameInChain(STR("StaticItemDataMap")));
        if (!mapProp) { Log(STR("StaticItemDataMap não encontrado.")); return false; }
        auto itemClass = UObjectGlobals::StaticFindObject<UClass*>(nullptr, nullptr, STR("/Script/Pal.PalStaticItemDataBase"));
        if (!itemClass) { Log(STR("Classe PalStaticItemDataBase não encontrada.")); return false; }
        auto maxStack = itemClass->FindProperty(FName(STR("MaxStackCount"), FNAME_Find));
        auto typeA = itemClass->FindProperty(FName(STR("TypeA"), FNAME_Find));
        auto typeB = itemClass->FindProperty(FName(STR("TypeB"), FNAME_Find));
        auto notConsumed = itemClass->FindProperty(FName(STR("bNotConsumed"), FNAME_Find));
        auto weight = itemClass->FindProperty(FName(STR("Weight"), FNAME_Find));
        g_layout.Weight = weight ? weight->GetOffset_Internal() : -1;
        if (!maxStack) { Log(STR("MaxStackCount não encontrado.")); return false; }
        g_layout.MapOffset = mapProp->GetOffset_Internal();
        g_layout.MapLayout = mapProp->GetMapLayout();
        g_layout.MaxStack = maxStack->GetOffset_Internal();
        g_layout.TypeA = typeA ? typeA->GetOffset_Internal() : -1;
        g_layout.TypeB = typeB ? typeB->GetOffset_Internal() : -1;
        if (notConsumed)
        {
            auto boolProp = static_cast<FBoolProperty*>(notConsumed);
            g_layout.NotConsumed = notConsumed->GetOffset_Internal() + boolProp->GetByteOffset();
            g_layout.NotConsumedMask = boolProp->GetByteMask();
        }
        g_layout.Ready = true;
        g_layout.Failed = false;
        Log(std::format(STR("Layout: mapa +{}, MaxStackCount +{}, TypeA +{}, TypeB +{}, bNotConsumed +{} (máscara {})."),
                        g_layout.MapOffset, g_layout.MaxStack, g_layout.TypeA, g_layout.TypeB, g_layout.NotConsumed,
                        g_layout.NotConsumedMask));
        return true;
    }

    std::unordered_set<StringType> g_essentialIds; // itens com TypeA Essential (preenchido em Apply)

    struct Tracked
    {
        UObject* Object = nullptr;
        int32 Index = -1;
    } g_asset;

    auto IsAlive(const Tracked& t) -> bool
    {
        if (!t.Object) return false;
        auto item = UObjectArray::IndexToObject(t.Index);
        return item && item->GetUObject() == t.Object && !item->IsUnreachable() && !item->IsPendingKill();
    }

    bool g_firstApplyLogged = false;

    auto Apply(UObject* asset) -> void
    {
        if (!ResolveLayout(asset)) return;
        auto map = reinterpret_cast<FScriptMap*>(reinterpret_cast<uint8*>(asset) + g_layout.MapOffset);
        int32 maxIndex = map->GetMaxIndex();
        if (maxIndex <= 0 || maxIndex > 100000) return;
        int items = 0, stacks = 0, implants = 0, special = 0;
        for (int32 i = 0; i < maxIndex; ++i)
        {
            if (!map->IsValidIndex(i)) continue;
            auto pair = static_cast<uint8*>(map->GetData(i, g_layout.MapLayout));
            auto item = *reinterpret_cast<uint8**>(pair + g_layout.MapLayout.ValueOffset);
            if (!item) continue;
            ++items;
            auto itemId = reinterpret_cast<FName*>(pair)->ToString();
            if (g_layout.TypeA >= 0 && item[g_layout.TypeA] == TYPEA_ESSENTIAL) g_essentialIds.insert(itemId);
            auto inList = [&](const std::vector<StringType>& list) { return std::find(list.begin(), list.end(), itemId) != list.end(); };
            if (g_layout.Weight >= 0 && inList(g_cfg.WeightlessItems))
            {
                auto& w = *reinterpret_cast<float*>(item + g_layout.Weight);
                if (w != 0.0f) { if (!g_firstApplyLogged) Log(std::format(STR("Peso de {}: {} -> 0."), itemId, w)); w = 0.0f; ++special; }
            }
            if (inList(g_cfg.EssentialItems) && g_layout.TypeA >= 0 && g_layout.TypeB >= 0 && item[g_layout.TypeA] != TYPEA_ESSENTIAL)
            {
                if (!g_firstApplyLogged) Log(std::format(STR("{}: tipo {}/{} -> essencial."), itemId, item[g_layout.TypeA], item[g_layout.TypeB]));
                item[g_layout.TypeA] = TYPEA_ESSENTIAL;
                item[g_layout.TypeB] = TYPEB_ESSENTIAL;
                ++special;
            }
            auto& maxStack = *reinterpret_cast<int32*>(item + g_layout.MaxStack);
            if (g_cfg.StackSize > 1 && maxStack > 1 && maxStack != g_cfg.StackSize)
            {
                maxStack = g_cfg.StackSize;
                ++stacks;
            }
            if (g_cfg.PermanentImplants && g_layout.TypeB >= 0 && item[g_layout.TypeB] == TYPEB_CONSUME_PASSIVE_CHANGE)
            {
                if (g_layout.TypeA >= 0) item[g_layout.TypeA] = TYPEA_ESSENTIAL;
                item[g_layout.TypeB] = TYPEB_ESSENTIAL_PASSIVE_CHANGE;
                if (g_layout.NotConsumed >= 0) item[g_layout.NotConsumed] |= g_layout.NotConsumedMask;
                ++implants;
            }
        }
        if (stacks > 0 || implants > 0 || special > 0 || !g_firstApplyLogged)
        {
            g_firstApplyLogged = true;
            Log(std::format(STR("{} item(ns): {} pilha(s) -> {}, {} implante(s) consumível(is) -> permanente(s), {} ajuste(s) de peso/tipo."), items, stacks,
                            g_cfg.StackSize, implants, special));
        }
    }

    // Registro único dos valores de PalGameSetting ligados a reviver e
    // construção (diagnóstico para os mods Quick Revive / construção).
    bool g_settingsLogged = false;
    auto LogGameSettings() -> void
    {
        auto gs = UObjectGlobals::FindFirstOf(STR("PalGameSetting"));
        if (!gs) return;
        g_settingsLogged = true;
        StringType line;
        for (auto name : {STR("PalBoxReviveTime"), STR("BuildSimulationLeanAngleMax"), STR("BuildSimulationFoundationFloatingAllowance"),
                          STR("BuildSimulationVerticalAdjustRate"), STR("BuildSimulationVerticalMinLength"), STR("BuildingMaxZ"),
                          STR("BuilderModeInstallableRange"), STR("SnapBuildObjectAttachDistance"), STR("BaseCampAreaRange")})
        {
            auto prop = gs->GetPropertyByNameInChain(name);
            if (!prop) continue;
            auto ptr = reinterpret_cast<uint8*>(gs) + prop->GetOffset_Internal();
            line += std::format(STR("{}={} "), name, *reinterpret_cast<float*>(ptr));
        }
        if (auto mapProp = static_cast<FMapProperty*>(gs->GetPropertyByNameInChain(STR("BuildSimulationFoundationCheckCollisionScale"))))
        {
            auto layout = mapProp->GetMapLayout();
            auto map = reinterpret_cast<FScriptMap*>(reinterpret_cast<uint8*>(gs) + mapProp->GetOffset_Internal());
            for (int32 i = 0; i < map->GetMaxIndex(); ++i)
            {
                if (!map->IsValidIndex(i)) continue;
                auto pair = static_cast<uint8*>(map->GetData(i, layout));
                auto v = reinterpret_cast<double*>(pair + layout.ValueOffset);
                line += std::format(STR("CollisionScale[{}]=({:.2f},{:.2f},{:.2f}) "), *pair, v[0], v[1], v[2]);
            }
        }
        if (auto def = gs->GetValuePtrByPropertyNameInChain<int32>(STR("CharacterRankUpRequiredNumDefault"))) line += std::format(STR("RankUpPadrão={} "), *def);
        if (auto rankProp = static_cast<FMapProperty*>(gs->GetPropertyByNameInChain(STR("CharacterRankUpRequiredNumMap"))))
        {
            auto layout = rankProp->GetMapLayout();
            auto map = reinterpret_cast<FScriptMap*>(reinterpret_cast<uint8*>(gs) + rankProp->GetOffset_Internal());
            for (int32 i = 0; i < map->GetMaxIndex(); ++i)
            {
                if (!map->IsValidIndex(i)) continue;
                auto pair = static_cast<uint8*>(map->GetData(i, layout));
                line += std::format(STR("RankUp[{}]={} "), *reinterpret_cast<int32*>(pair), *reinterpret_cast<int32*>(pair + layout.ValueOffset));
            }
        }
        Log(std::format(STR("PalGameSetting ({}): {}"), gs->GetFullName(), line));
    }

    // Máquina de condensação: Pals consumidos por estrela = RankUpPercent do
    // original (mínimo 1). Guarda os originais por objeto para não acumular.
    Tracked g_rankSetting;
    std::unordered_map<int32, int32> g_rankOriginal;
    int32 g_rankDefaultOriginal = -1;
    bool g_rankLogged = false;

    auto ScaledRank(int32 original) -> int32
    {
        return std::max(1, static_cast<int32>(std::lround(original * g_cfg.RankUpPercent / 100.0)));
    }

    auto ApplyRankUp() -> void
    {
        if (g_cfg.RankUpPercent >= 100) return;
        auto gs = UObjectGlobals::FindFirstOf(STR("PalGameSetting"));
        if (!gs) return;
        if (!IsAlive(g_rankSetting) || g_rankSetting.Object != gs)
        {
            g_rankSetting = {gs, gs->GetInternalIndex()};
            g_rankOriginal.clear();
            g_rankDefaultOriginal = -1;
        }
        StringType changes;
        if (auto def = gs->GetValuePtrByPropertyNameInChain<int32>(STR("CharacterRankUpRequiredNumDefault")))
        {
            if (g_rankDefaultOriginal < 0) g_rankDefaultOriginal = *def;
            int32 want = ScaledRank(g_rankDefaultOriginal);
            if (*def != want) { *def = want; changes += std::format(STR("padrão {}->{} "), g_rankDefaultOriginal, want); }
        }
        if (auto prop = static_cast<FMapProperty*>(gs->GetPropertyByNameInChain(STR("CharacterRankUpRequiredNumMap"))))
        {
            auto layout = prop->GetMapLayout();
            auto map = reinterpret_cast<FScriptMap*>(reinterpret_cast<uint8*>(gs) + prop->GetOffset_Internal());
            for (int32 i = 0; i < map->GetMaxIndex(); ++i)
            {
                if (!map->IsValidIndex(i)) continue;
                auto pair = static_cast<uint8*>(map->GetData(i, layout));
                int32 rank = *reinterpret_cast<int32*>(pair);
                auto& value = *reinterpret_cast<int32*>(pair + layout.ValueOffset);
                if (!g_rankOriginal.contains(rank)) g_rankOriginal[rank] = value;
                int32 want = ScaledRank(g_rankOriginal[rank]);
                if (value != want) { value = want; changes += std::format(STR("★{} {}->{} "), rank, g_rankOriginal[rank], want); }
            }
        }
        if (!changes.empty() && !g_rankLogged)
        {
            g_rankLogged = true;
            Log(std::format(STR("Máquina de condensação ({}%): {}"), g_cfg.RankUpPercent, changes));
        }
    }

    // Pals que já tinham mais condensações que o novo limite (ex.: 13+ com o
    // limite de 4 estrelas reduzido para 12) ficavam travados. Deixa o contador
    // a uma condensação da próxima estrela. Rank 1 = sem estrela; a chave do
    // mapa (Rank atual) é o total exigido para a próxima.
    double g_nextRankFix = 0.0;
    int g_rankFixes = 0;

    auto FixStuckRanks() -> void
    {
        if (g_cfg.RankUpPercent >= 100 || g_rankOriginal.empty()) return;
        auto paramClass = UObjectGlobals::StaticFindObject<UClass*>(nullptr, nullptr, STR("/Script/Pal.PalIndividualCharacterParameter"));
        if (!paramClass) return;
        auto saveProp = static_cast<FStructProperty*>(paramClass->FindProperty(FName(STR("SaveParameter"), FNAME_Find)));
        if (!saveProp) return;
        auto rankProp = saveProp->GetStruct()->FindProperty(FName(STR("Rank"), FNAME_Find));
        auto expProp = saveProp->GetStruct()->FindProperty(FName(STR("RankUpExp"), FNAME_Find));
        if (!rankProp || !expProp) return;
        int32 rankOffset = saveProp->GetOffset_Internal() + rankProp->GetOffset_Internal();
        int32 expOffset = saveProp->GetOffset_Internal() + expProp->GetOffset_Internal();

        std::vector<UObject*> params;
        UObjectGlobals::FindAllOf(STR("PalIndividualCharacterParameter"), params);
        for (auto p : params)
        {
            auto base = reinterpret_cast<uint8*>(p);
            uint8 rank = base[rankOffset];
            auto& exp = *reinterpret_cast<uint16*>(base + expOffset);
            auto it = g_rankOriginal.find(rank);
            if (it == g_rankOriginal.end()) continue; // já no máximo ou sem tabela
            int32 required = ScaledRank(it->second);
            if (exp < required) continue;
            uint16 before = exp;
            exp = static_cast<uint16>(std::max(0, required - 1));
            ++g_rankFixes;
            if (g_rankFixes <= 20)
                Log(std::format(STR("Condensação destravada: {} (rank {}) contador {} -> {} (próxima estrela com {})."),
                                p->GetName(), rank, before, exp, required));
        }
    }

    // Tempo de reviver na caixa de Pals: ReviveTimePercent do original (padrão
    // 10% = 10 min -> 1 min), sem depender da unidade usada pelo jogo.
    struct ReviveState
    {
        Tracked Setting;
        float Original = 0.0f;
        float Written = 0.0f;
    } g_revive;

    auto ApplyRevive() -> void
    {
        if (g_cfg.ReviveTimePercent >= 100) return;
        if (!IsAlive(g_revive.Setting))
        {
            auto gs = UObjectGlobals::FindFirstOf(STR("PalGameSetting"));
            if (!gs) return;
            g_revive = {{gs, gs->GetInternalIndex()}, 0.0f, 0.0f};
        }
        auto gs = g_revive.Setting.Object;
        auto prop = gs->GetPropertyByNameInChain(STR("PalBoxReviveTime"));
        if (!prop) return;
        auto& value = *reinterpret_cast<float*>(reinterpret_cast<uint8*>(gs) + prop->GetOffset_Internal());
        if (g_revive.Written != 0.0f && value == g_revive.Written) return;
        if (value <= 0.0f) return;
        g_revive.Original = value;
        g_revive.Written = value * static_cast<float>(g_cfg.ReviveTimePercent) / 100.0f;
        value = g_revive.Written;
        Log(std::format(STR("Reviver na caixa de Pals: {} -> {} ({}%)."), g_revive.Original, g_revive.Written, g_cfg.ReviveTimePercent));
    }
    // Lista de passivas (passives.txt), gravada uma vez por sessão: base para
    // escolher quais passivas viram implantes.
    bool g_passivesDumped = false;

    auto PropOffset(UStruct* s, const CharType* name) -> int32
    {
        auto p = s ? s->FindProperty(FName(name, FNAME_Find)) : nullptr;
        return p ? p->GetOffset_Internal() : -1;
    }

    auto DumpPassives() -> void
    {
        g_passivesDumped = true;
        std::vector<UObject*> tables;
        UObjectGlobals::FindAllOf(STR("DataTable"), tables);
        UDataTable* passives = nullptr;
        UDataTable* names = nullptr;
        UDataTable* surgery = nullptr;
        for (auto obj : tables)
        {
            auto n = obj->GetName();
            if (n == STR("DT_PassiveSkill_Main")) passives = static_cast<UDataTable*>(obj);
            else if (n == STR("DT_SkillNameText")) names = static_cast<UDataTable*>(obj);
            else if (n == STR("DT_OperatingTablePassiveSkillDataTable")) surgery = static_cast<UDataTable*>(obj);
        }
        if (!passives) { Log(STR("DT_PassiveSkill_Main não encontrada.")); return; }

        std::unordered_set<std::string> onTable;
        if (surgery)
        {
            for (auto& pair : surgery->GetRowMap()) onTable.insert(to_utf8_string(pair.Key.ToString()));
        }
        int32 nameText = names ? PropOffset(names->GetRowStruct().Get(), STR("TextData")) : -1;
        auto TextOf = [&](const StringType& key) -> std::string {
            if (!names || nameText < 0) return "";
            auto row = names->FindRowUnchecked(FName(key.c_str(), FNAME_Find));
            if (!row) return "";
            return to_utf8_string(reinterpret_cast<FText*>(row + nameText)->ToString());
        };

        UStruct* rs = passives->GetRowStruct().Get();
        int32 oRank = PropOffset(rs, STR("Rank")), oWeight = PropOffset(rs, STR("LotteryWeight"));
        int32 oAddPal = PropOffset(rs, STR("AddPal")), oRare = PropOffset(rs, STR("AddRarePal"));
        int32 oTree = PropOffset(rs, STR("AddWorldTreePal")), oMut = PropOffset(rs, STR("AddMutationPal"));
        int32 oWeapon = PropOffset(rs, STR("AddShotWeapon")), oArmor = PropOffset(rs, STR("AddArmor"));
        int32 oAcc = PropOffset(rs, STR("AddAccessory")), oCat = PropOffset(rs, STR("Category"));
        int32 oNameId = PropOffset(rs, STR("OverrideNameTextID"));
        int32 oE1 = PropOffset(rs, STR("EffectType1")), oV1 = PropOffset(rs, STR("EffectValue1"));
        int32 oE2 = PropOffset(rs, STR("EffectType2")), oV2 = PropOffset(rs, STR("EffectValue2"));

        std::ofstream out(g_modDir / "passives.txt", std::ios::binary);
        out << "# id\trank\tpeso\tAddPal\tAddRare\tAddTree\tAddMut\tarma\tarmadura\tacessorio\tcategoria\tna_mesa\tefeito1\tefeito2\tnome\n";
        int count = 0;
        for (auto& pair : passives->GetRowMap())
        {
            auto row = pair.Value;
            auto id = pair.Key.ToString();
            auto b = [&](int32 o) { return o >= 0 && row[o] ? "1" : "0"; };
            auto i32 = [&](int32 o) { return o >= 0 ? std::to_string(*reinterpret_cast<int32*>(row + o)) : std::string("?"); };
            auto eff = [&](int32 oe, int32 ov) {
                if (oe < 0 || ov < 0 || row[oe] == 0) return std::string("-");
                return std::to_string(row[oe]) + ":" + std::to_string(*reinterpret_cast<float*>(row + ov));
            };
            std::string name = TextOf(STR("PASSIVE_") + id);
            if (name.empty() && oNameId >= 0)
            {
                auto overrideId = reinterpret_cast<FName*>(row + oNameId)->ToString();
                if (overrideId != STR("None")) name = TextOf(overrideId);
            }
            out << to_utf8_string(id) << "\t" << i32(oRank) << "\t" << i32(oWeight) << "\t" << b(oAddPal) << "\t" << b(oRare) << "\t"
                << b(oTree) << "\t" << b(oMut) << "\t" << b(oWeapon) << "\t" << b(oArmor) << "\t" << b(oAcc) << "\t"
                << (oCat >= 0 ? std::to_string(row[oCat]) : "?") << "\t" << (onTable.contains(to_utf8_string(id)) ? "1" : "0") << "\t"
                << eff(oE1, oV1) << "\t" << eff(oE2, oV2) << "\t" << name << "\n";
            ++count;
        }
        Log(std::format(STR("Lista de {} passiva(s) gravada em passives.txt."), count));
    }

    // Diagnóstico das lojas (Ctrl+F12): produtos na tabela x lojas vivas.
    struct RawProducts
    {
        uint8* Data;
        int32 Num;
        int32 Max;
    };
    std::atomic<bool> g_shopReportRequested{false};

    auto CountImplants(const RawProducts& arr, int32 elemSize, int32 idOffset) -> int
    {
        int n = 0;
        for (int32 i = 0; i < arr.Num; ++i)
        {
            auto id = reinterpret_cast<FName*>(arr.Data + static_cast<size_t>(i) * elemSize + idOffset)->ToString();
            if (id.starts_with(STR("PalPassiveSkillChange"))) ++n;
        }
        return n;
    }

    auto ShopReport() -> void
    {
        std::vector<UObject*> tables;
        UObjectGlobals::FindAllOf(STR("DataTable"), tables);
        for (auto obj : tables)
        {
            auto name = obj->GetName();
            if (!name.starts_with(STR("DT_ItemShopCreateData"))) continue;
            auto dt = static_cast<UDataTable*>(obj);
            auto rs = dt->GetRowStruct().Get();
            auto arrProp = rs ? static_cast<FArrayProperty*>(rs->FindProperty(FName(STR("productDataArray"), FNAME_Find))) : nullptr;
            if (!arrProp) continue;
            auto inner = static_cast<FStructProperty*>(arrProp->GetInner());
            int32 idOffset = PropOffset(inner->GetStruct(), STR("StaticItemId"));
            for (auto rowName : {STR("Village_Shop_1"), STR("Wander_Shop_1"), STR("Desert_Shop_1")})
            {
                auto row = dt->FindRowUnchecked(FName(rowName, FNAME_Find));
                if (!row) continue;
                auto& arr = *reinterpret_cast<RawProducts*>(row + arrProp->GetOffset_Internal());
                Log(std::format(STR("Tabela {} / {}: {} produto(s), {} implante(s)."), name, rowName, arr.Num,
                                CountImplants(arr, inner->GetElementSize(), idOffset)));
            }
        }
        // Nome exibido de cada implante (DT_ItemNameText, chave ITEM_NAME_<id>).
        for (auto obj : tables)
        {
            if (obj->GetName() != STR("DT_ItemNameText")) continue;
            auto dt = static_cast<UDataTable*>(obj);
            int32 textOffset = PropOffset(dt->GetRowStruct().Get(), STR("TextData"));
            if (textOffset < 0) break;
            std::ofstream out(g_modDir / "implant_names.txt", std::ios::binary);
            int n = 0;
            for (auto& pair : dt->GetRowMap())
            {
                auto key = pair.Key.ToString();
                if (!key.starts_with(STR("ITEM_NAME_PalPassiveSkillChange"))) continue;
                out << to_utf8_string(key.substr(10)) << "\t" << to_utf8_string(reinterpret_cast<FText*>(pair.Value + textOffset)->ToString()) << "\n";
                ++n;
            }
            Log(std::format(STR("Nomes de {} implante(s) gravados em implant_names.txt."), n));
            break;
        }

        // Mesa de cirurgia: todas as linhas (passiva, preço, item exigido).
        for (auto obj : tables)
        {
            if (obj->GetName() != STR("DT_OperatingTablePassiveSkillDataTable")) continue;
            auto dt = static_cast<UDataTable*>(obj);
            auto rs = dt->GetRowStruct().Get();
            int32 oPassive = PropOffset(rs, STR("PassiveSkill")), oPrice = PropOffset(rs, STR("Price")), oReq = PropOffset(rs, STR("RequireItemId"));
            std::ofstream out(g_modDir / "surgery_table.txt", std::ios::binary);
            int n = 0;
            for (auto& pair : dt->GetRowMap())
            {
                auto row = pair.Value;
                out << to_utf8_string(pair.Key.ToString()) << "\t" << to_utf8_string(reinterpret_cast<FName*>(row + oPassive)->ToString()) << "\t"
                    << *reinterpret_cast<int32*>(row + oPrice) << "\t" << to_utf8_string(reinterpret_cast<FName*>(row + oReq)->ToString()) << "\n";
                ++n;
            }
            Log(std::format(STR("Mesa de cirurgia: {} linha(s) gravadas em surgery_table.txt."), n));
            break;
        }

        std::vector<UObject*> shops;
        UObjectGlobals::FindAllOf(STR("PalShopBase"), shops);
        int logged = 0;
        for (auto shop : shops)
        {
            auto shopName = shop->GetValuePtrByPropertyNameInChain<FName>(STR("MyShopName"));
            auto products = shop->GetValuePtrByPropertyNameInChain<RawProducts>(STR("ProductArray"));
            if (!shopName || !products) continue;
            if (logged++ < 40)
                Log(std::format(STR("Loja viva {}: {} produto(s)."), shopName->ToString(), products->Num));
            if (shopName->ToString() != STR("Village_Shop_1") || !products->Data || products->Num <= 0 || products->Num > 500) continue;
            StringType implants, others;
            int nImplants = 0, nInvalid = 0;
            for (int32 i = 0; i < products->Num; ++i)
            {
                auto product = reinterpret_cast<UObject**>(products->Data)[i];
                if (!product) continue;
                auto valid = product->GetValuePtrByPropertyNameInChain<bool>(STR("IsValidProductFlag"));
                auto giver = product->GetValuePtrByPropertyNameInChain<UObject*>(STR("MyProductGiver"));
                FName* id = (giver && *giver) ? (*giver)->GetValuePtrByPropertyNameInChain<FName>(STR("ProductStaticItemID")) : nullptr;
                auto idText = id ? id->ToString() : StringType(STR("?"));
                if (valid && !*valid) ++nInvalid;
                if (idText.starts_with(STR("PalPassiveSkillChange")))
                {
                    ++nImplants;
                    implants += idText + ((valid && !*valid) ? STR("(inválido) ") : STR(" "));
                }
                else others += idText + STR(" ");
            }
            Log(std::format(STR("Village_Shop_1 viva: {} implante(s), {} inválido(s). Implantes: {}"), nImplants, nInvalid, implants));
            Log(std::format(STR("Village_Shop_1 viva, outros: {}"), others));
        }
        Log(std::format(STR("{} loja(s) viva(s)."), shops.size()));
    }

    double g_clock = 0.0;

    // ------------------------------------------------------------------
    // Chamada de UFunction por reflexão (parâmetros inicializados/destruídos).
    // ------------------------------------------------------------------
    class ParamBuffer
    {
    public:
        explicit ParamBuffer(UFunction* fn) : m_fn(fn), m_data(std::max<size_t>(fn->GetParmsSize(), 16), 0)
        {
            for (FProperty* p : TFieldRange<FProperty>(m_fn, EFieldIterationFlags::IncludeDeprecated))
                if (p->HasAnyPropertyFlags(CPF_Parm)) p->InitializeValue_InContainer(m_data.data());
        }
        ~ParamBuffer()
        {
            for (FProperty* p : TFieldRange<FProperty>(m_fn, EFieldIterationFlags::IncludeDeprecated))
                if (p->HasAnyPropertyFlags(CPF_Parm)) p->DestroyValue_InContainer(m_data.data());
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

    struct Vec3
    {
        double X, Y, Z;
    };

    auto TrackedFind(Tracked& t, const CharType* className) -> UObject*
    {
        if (IsAlive(t)) return t.Object;
        auto obj = UObjectGlobals::FindFirstOf(className);
        t = obj ? Tracked{obj, obj->GetInternalIndex()} : Tracked{};
        return obj;
    }

    auto ActorLocation(UObject* actor, Vec3& out) -> bool
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

    // ------------------------------------------------------------------
    // Coleta automática (AutoLoot): itens que caem perto do jogador vão
    // direto para o inventário, pela coleta automática do próprio jogo
    // (RequestPickup(bByAutoPickup = true)). Fora das bases.
    // ------------------------------------------------------------------
    struct PendingDrop
    {
        UObject* Object;
        int32 Index;
        double Since;
        int Tries;
    };
    std::mutex g_dropMutex;
    std::vector<PendingDrop> g_newDrops; // preenchido no gancho (qualquer thread)
    std::vector<PendingDrop> g_drops;    // só no game thread
    std::atomic<UClass*> g_dropClass{nullptr};
    Tracked g_player;
    struct BaseArea
    {
        double X, Y, Range;
    };
    std::vector<BaseArea> g_bases;
    double g_nextBaseScan = 0.0;
    int g_autoLooted = 0;
    int g_autoLootLogged = 0;

    auto OnObjectConstructed(UObject* obj) -> void
    {
        auto cls = g_dropClass.load(std::memory_order_relaxed);
        if (!cls || !obj || obj->GetClassPrivate() != cls) return;
        std::lock_guard lock(g_dropMutex);
        if (g_newDrops.size() < 2000) g_newDrops.push_back({obj, obj->GetInternalIndex(), -1.0, 0});
    }

    auto ScanBases() -> void
    {
        g_bases.clear();
        std::vector<UObject*> models;
        UObjectGlobals::FindAllOf(STR("PalBaseCampModel"), models);
        for (auto m : models)
        {
            auto transform = m->GetPropertyByNameInChain(STR("Transform"));
            auto range = m->GetPropertyByNameInChain(STR("AreaRange"));
            if (!transform || !range) continue;
            // FTransform (UE5, double): Rotation (32 bytes) e depois Translation.
            auto t = reinterpret_cast<double*>(reinterpret_cast<uint8*>(m) + transform->GetOffset_Internal() + 32);
            float r = *reinterpret_cast<float*>(reinterpret_cast<uint8*>(m) + range->GetOffset_Internal());
            if (r <= 0.0f) continue;
            g_bases.push_back({t[0], t[1], static_cast<double>(r) + g_cfg.AutoLootBaseMargin});
        }
    }

    auto InsideBase(const Vec3& p) -> bool
    {
        for (auto& b : g_bases)
        {
            double dx = p.X - b.X, dy = p.Y - b.Y;
            if (dx * dx + dy * dy <= b.Range * b.Range) return true;
        }
        return false;
    }

    auto DropLocation(UObject* model, Vec3& out) -> bool
    {
        auto fn = model->GetFunctionByNameInChain(STR("GetMapObjectLocation"));
        if (!fn) return false;
        ParamBuffer params(fn);
        params.Call(model);
        auto v = params.Ptr(STR("outVector"));
        if (!v) return false;
        out = *reinterpret_cast<Vec3*>(v);
        return !(out.X == 0.0 && out.Y == 0.0 && out.Z == 0.0);
    }

    auto ProcessDrops() -> void
    {
        if (!g_dropClass.load())
        {
            g_dropClass = UObjectGlobals::StaticFindObject<UClass*>(nullptr, nullptr, STR("/Script/Pal.PalMapObjectDropItemModel"));
            if (!g_dropClass.load()) return;
        }
        {
            std::lock_guard lock(g_dropMutex);
            for (auto& d : g_newDrops) { d.Since = g_clock; g_drops.push_back(d); }
            g_newDrops.clear();
        }
        if (g_drops.empty()) return;
        if (g_clock >= g_nextBaseScan)
        {
            g_nextBaseScan = g_clock + 30.0;
            ScanBases();
        }
        auto player = TrackedFind(g_player, STR("PalPlayerCharacter"));
        Vec3 p{};
        bool havePlayer = player && ActorLocation(player, p);
        double range2 = g_cfg.AutoLootRange * g_cfg.AutoLootRange;
        std::vector<PendingDrop> keep;
        for (auto& d : g_drops)
        {
            if (g_clock - d.Since < 0.5) { keep.push_back(d); continue; }
            Tracked t{d.Object, d.Index};
            if (!IsAlive(t) || !havePlayer) continue;
            Vec3 loc{};
            if (!DropLocation(d.Object, loc))
            {
                if (++d.Tries < 6) keep.push_back(d);
                continue;
            }
            double dx = loc.X - p.X, dy = loc.Y - p.Y, dz = loc.Z - p.Z;
            if (dx * dx + dy * dy + dz * dz > range2) continue; // longe: fica no chão
            if (g_cfg.AutoLootOutsideBaseOnly && InsideBase(loc)) continue;
            auto fn = d.Object->GetFunctionByNameInChain(STR("RequestPickup"));
            if (!fn) continue;
            ParamBuffer params(fn);
            if (auto flag = params.Ptr(STR("bByAutoPickup"))) *flag = 1;
            params.Call(d.Object);
            ++g_autoLooted;
            if (g_cfg.VerboseLogging || g_autoLootLogged < 5)
            {
                ++g_autoLootLogged;
                Log(std::format(STR("Coleta automática: item a {:.1f} m (total {})."), std::sqrt(dx * dx + dy * dy + dz * dz) / 100.0, g_autoLooted));
            }
        }
        g_drops.swap(keep);
    }

    // ------------------------------------------------------------------
    // Organizador: itens importantes que entraram no inventário comum (ex.:
    // tirados de um baú) vão para a aba de itens importantes.
    // ------------------------------------------------------------------
    Tracked g_inventory;
    Tracked g_itemNet;
    int g_sorted = 0;

    auto InventoryContainer(UObject* inv, uint8 type, UObject*& container, uint8* containerId) -> bool
    {
        auto fn = inv->GetFunctionByNameInChain(STR("TryGetContainerFromInventoryType"));
        auto fnId = inv->GetFunctionByNameInChain(STR("TryGetContainerIDFromInventoryType"));
        if (!fn || !fnId) return false;
        {
            ParamBuffer params(fn);
            *params.Ptr(STR("inventoryType")) = type;
            params.Call(inv);
            auto out = params.Ptr(STR("OutContainer"));
            auto ret = params.Ptr(STR("ReturnValue"));
            if (!out || !ret || !*ret) return false;
            container = *reinterpret_cast<UObject**>(out);
        }
        {
            ParamBuffer params(fnId);
            *params.Ptr(STR("inventoryType")) = type;
            params.Call(inv);
            auto out = params.Ptr(STR("OutContainerId"));
            auto ret = params.Ptr(STR("ReturnValue"));
            if (!out || !ret || !*ret) return false;
            std::memcpy(containerId, out, 16);
        }
        return container != nullptr;
    }

    // Move um slot (contêiner de origem) para outro contêiner do jogador.
    auto RequestMove(UObject* net, const uint8* fromContainerId, int32 slotIndex, int32 count, const uint8* toContainerId) -> bool
    {
        auto fn = net->GetFunctionByNameInChain(STR("RequestMoveToContainer_ToServer"));
        if (!fn) return false;
        ParamBuffer params(fn);
        auto requestId = reinterpret_cast<uint32*>(params.Ptr(STR("RequestID")));
        auto to = params.Ptr(STR("ToContainerId"));
        auto fromsProp = static_cast<FArrayProperty*>(params.Prop(STR("Froms")));
        auto froms = reinterpret_cast<RawProducts*>(params.Ptr(STR("Froms")));
        if (!requestId || !to || !fromsProp || !froms) return false;
        static std::mt19937 rng{std::random_device{}()};
        for (int k = 0; k < 4; ++k) requestId[k] = rng();
        std::memcpy(to, toContainerId, 16);
        int32 elemSize = fromsProp->GetInner()->GetElementSize();
        auto elem = static_cast<uint8*>(FMemory::Malloc(elemSize));
        std::memset(elem, 0, elemSize);
        std::memcpy(elem, fromContainerId, 16);
        *reinterpret_cast<int32*>(elem + 16) = slotIndex;
        *reinterpret_cast<int32*>(elem + 20) = count;
        froms->Data = elem;
        froms->Num = 1;
        froms->Max = 1;
        params.Call(net);
        return true;
    }

    // Itens da lista ReturnToCommonItems que estão na aba de importantes
    // voltam para o inventário comum (ex.: moeda de ouro após deixar de ser
    // item importante). Um por vez.
    auto ReturnToCommon(UObject* net, UObject* essential, const uint8* essentialId, const uint8* commonId) -> bool
    {
        if (g_cfg.ReturnToCommonItems.empty()) return false;
        auto slots = essential->GetValuePtrByPropertyNameInChain<RawProducts>(STR("ItemSlotArray"));
        if (!slots || !slots->Data || slots->Num <= 0 || slots->Num > 1000) return false;
        for (int32 i = 0; i < slots->Num; ++i)
        {
            auto slot = reinterpret_cast<UObject**>(slots->Data)[i];
            if (!slot) continue;
            auto itemId = slot->GetValuePtrByPropertyNameInChain<FName>(STR("ItemId"));
            auto count = slot->GetValuePtrByPropertyNameInChain<int32>(STR("StackCount"));
            auto slotIndex = slot->GetValuePtrByPropertyNameInChain<int32>(STR("SlotIndex"));
            if (!itemId || !count || !slotIndex || *count <= 0) continue;
            auto id = itemId->ToString();
            if (std::find(g_cfg.ReturnToCommonItems.begin(), g_cfg.ReturnToCommonItems.end(), id) == g_cfg.ReturnToCommonItems.end()) continue;
            if (g_essentialIds.contains(id)) continue; // ainda é item importante: não mexe
            if (RequestMove(net, essentialId, *slotIndex, *count, commonId))
            {
                Log(std::format(STR("Organizador: {} x{} devolvido ao inventário comum."), id, *count));
                return true;
            }
        }
        return false;
    }

    auto SortEssentials() -> void
    {
        if (g_essentialIds.empty()) return;
        auto inv = TrackedFind(g_inventory, STR("PalPlayerInventoryData"));
        auto net = TrackedFind(g_itemNet, STR("PalNetworkItemComponent"));
        if (!inv || !net) return;
        UObject* common = nullptr;
        UObject* essential = nullptr;
        uint8 commonId[16]{}, essentialId[16]{};
        if (!InventoryContainer(inv, 0, common, commonId) || !InventoryContainer(inv, 2, essential, essentialId)) return;
        if (ReturnToCommon(net, essential, essentialId, commonId)) return;
        auto slots = common->GetValuePtrByPropertyNameInChain<RawProducts>(STR("ItemSlotArray"));
        if (!slots || !slots->Data || slots->Num <= 0 || slots->Num > 1000) return;
        for (int32 i = 0; i < slots->Num; ++i)
        {
            auto slot = reinterpret_cast<UObject**>(slots->Data)[i];
            if (!slot) continue;
            auto itemId = slot->GetValuePtrByPropertyNameInChain<FName>(STR("ItemId"));
            auto count = slot->GetValuePtrByPropertyNameInChain<int32>(STR("StackCount"));
            auto slotIndex = slot->GetValuePtrByPropertyNameInChain<int32>(STR("SlotIndex"));
            if (!itemId || !count || !slotIndex || *count <= 0) continue;
            auto id = itemId->ToString();
            if (!g_essentialIds.contains(id)) continue;

            auto fn = net->GetFunctionByNameInChain(STR("RequestMoveToContainer_ToServer"));
            if (!fn) return;
            ParamBuffer params(fn);
            auto requestId = reinterpret_cast<uint32*>(params.Ptr(STR("RequestID")));
            auto to = params.Ptr(STR("ToContainerId"));
            auto fromsProp = static_cast<FArrayProperty*>(params.Prop(STR("Froms")));
            auto froms = reinterpret_cast<RawProducts*>(params.Ptr(STR("Froms")));
            if (!requestId || !to || !fromsProp || !froms) return;
            static std::mt19937 rng{std::random_device{}()};
            for (int k = 0; k < 4; ++k) requestId[k] = rng();
            std::memcpy(to, essentialId, 16);
            // Froms: um FPalItemSlotIdAndNum {ContainerId, SlotIndex, Num}; a
            // memória é do alocador do jogo e é liberada pelo DestroyValue.
            int32 elemSize = fromsProp->GetInner()->GetElementSize();
            auto elem = static_cast<uint8*>(FMemory::Malloc(elemSize));
            std::memset(elem, 0, elemSize);
            std::memcpy(elem, commonId, 16);
            *reinterpret_cast<int32*>(elem + 16) = *slotIndex;
            *reinterpret_cast<int32*>(elem + 20) = *count;
            froms->Data = elem;
            froms->Num = 1;
            froms->Max = 1;
            params.Call(net);
            ++g_sorted;
            Log(std::format(STR("Organizador: {} x{} movido para os itens importantes (total {})."), id, *count, g_sorted));
            return; // um por vez
        }
    }

    auto InventoryReport() -> void
    {
        // Implantes no inventário do jogador (comum = 0, importantes = 2).
        if (auto inv = TrackedFind(g_inventory, STR("PalPlayerInventoryData")))
        {
            for (uint8 type : {uint8(0), uint8(2)})
            {
                UObject* container = nullptr;
                uint8 containerId[16]{};
                if (!InventoryContainer(inv, type, container, containerId)) continue;
                auto slots = container->GetValuePtrByPropertyNameInChain<RawProducts>(STR("ItemSlotArray"));
                if (!slots || !slots->Data || slots->Num <= 0 || slots->Num > 1000) continue;
                StringType list;
                for (int32 i = 0; i < slots->Num; ++i)
                {
                    auto slot = reinterpret_cast<UObject**>(slots->Data)[i];
                    if (!slot) continue;
                    auto itemId = slot->GetValuePtrByPropertyNameInChain<FName>(STR("ItemId"));
                    auto count = slot->GetValuePtrByPropertyNameInChain<int32>(STR("StackCount"));
                    if (!itemId || !count || *count <= 0) continue;
                    auto id = itemId->ToString();
                    if (id.starts_with(STR("PalPassiveSkillChange")) || g_essentialIds.contains(id)) list += std::format(STR("{} x{}; "), id, *count);
                }
                Log(std::format(STR("Inventário {} ({} slots): {}"), type == 0 ? STR("comum") : STR("importantes"), slots->Num, list));
            }
        }

    }

    double g_nextApply = 3.0;
    double g_nextSort = 5.0;

    auto OnTick(float deltaSeconds) -> void
    {
        g_clock += std::clamp(static_cast<double>(deltaSeconds), 0.0, 1.0);
        if (g_shopReportRequested.exchange(false))
        {
            ShopReport();
            InventoryReport();
        }
        if (g_cfg.AutoLoot) ProcessDrops();
        if (g_cfg.SortEssentials && g_clock >= g_nextSort)
        {
            g_nextSort = g_clock + 2.0;
            SortEssentials();
        }
        if (g_clock < g_nextApply) return;
        if (!IsAlive(g_asset))
        {
            g_nextApply = g_clock + 5.0;
            auto asset = UObjectGlobals::FindFirstOf(STR("PalStaticItemDataAsset"));
            if (!asset) return;
            g_asset = {asset, asset->GetInternalIndex()};
            Log(std::format(STR("Tabela de itens encontrada: {}."), asset->GetFullName()));
        }
        g_nextApply = g_clock + 30.0;
        Apply(g_asset.Object);
        if (UObjectGlobals::FindFirstOf(STR("PalPlayerCharacter")))
        {
            if (!g_settingsLogged) LogGameSettings();
            if (!g_passivesDumped) DumpPassives();
            ApplyRevive();
            ApplyRankUp();
            if (g_clock >= g_nextRankFix)
            {
                g_nextRankFix = g_clock + 60.0;
                FixStuckRanks();
            }
        }
    }
} // namespace

class PalItemTweaks : public CppUserModBase
{
public:
    PalItemTweaks() : CppUserModBase()
    {
        ModName = STR("PalItemTweaks");
        ModVersion = MOD_VERSION;
        ModDescription = STR("Pilhas de itens maiores e implantes permanentes.");
        ModAuthors = STR("lbcamargo94");
    }

    ~PalItemTweaks() override = default;

    auto on_unreal_init() -> void override
    {
        g_modDir = FindModDir();
        LoadConfig();
        if (!g_cfg.Enabled)
        {
            Log(std::format(STR("v{} desativado no config.txt."), MOD_VERSION));
            return;
        }
        Hook::RegisterEngineTickPreCallback(
                [](Hook::TCallbackIterationData<void>&, UEngine*, float deltaSeconds, bool) { OnTick(deltaSeconds); },
                {false, false, STR("PalItemTweaks"), STR("Tick")});
        if (g_cfg.AutoLoot)
        {
            Hook::RegisterStaticConstructObjectPostCallback(
                    [](Hook::TCallbackIterationData<UObject*>& data, const FStaticConstructObjectParameters&) {
                        OnObjectConstructed(data.GetCurrentResolvedReturnValue());
                    },
                    {false, true, STR("PalItemTweaks"), STR("AutoLootWatch")});
        }
        // A tecla chega na thread do UE4SS: só marca; o relatório roda no game thread.
        register_keydown_event(Input::Key::F12, {Input::ModifierKey::CONTROL}, [] { g_shopReportRequested = true; });
        Log(std::format(STR("v{} carregado: pilhas até {}, implantes permanentes: {}."), MOD_VERSION, g_cfg.StackSize,
                        g_cfg.PermanentImplants ? STR("sim") : STR("não")));
    }
};

#define PAL_ITEM_TWEAKS_API __declspec(dllexport)
extern "C"
{
    PAL_ITEM_TWEAKS_API CppUserModBase* start_mod()
    {
        return new PalItemTweaks();
    }

    PAL_ITEM_TWEAKS_API void uninstall_mod(CppUserModBase* mod)
    {
        delete mod;
    }
}
