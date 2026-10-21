// Pal Base Storage - mod C++ (UE4SS) para Palworld.
//
// Fabricar usando os baús das bases da guilda (e o Baú da Guilda), como o
// Integrated Storage, sem mexer na lista de contêineres do inventário.
//
// v0.4.0 (novo desenho): as versões 0.1-0.3 punham os baús no
// UPalItemContainerMultiHelper do inventário; o servidor recusa operações em
// contêineres de baú, o que quebrava bancadas manuais e a pesca. Agora:
//   1. UPalUIConvertItemModel:CanStartProduction (pós): se a resposta for
//      "faltam itens" e inventário + baús bastarem, libera o botão;
//   2. UPalUIConvertItemModel:StartProduction (pré): move dos baús para o
//      inventário só o que falta (RequestMoveToContainer_ToServer), e o jogo
//      consome do inventário normalmente.

#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <Windows.h>

#include <algorithm>
#include <cstring>
#include <filesystem>
#include <format>
#include <fstream>
#include <random>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include <DynamicOutput/DynamicOutput.hpp>
#include <Mod/CppUserModBase.hpp>
#include <Unreal/CoreUObject/UObject/Class.hpp>
#include <Unreal/CoreUObject/UObject/UnrealType.hpp>
#include <Unreal/Engine/UDataTable.hpp>
#include <Unreal/FFrame.hpp>
#include <Unreal/FMemory.hpp>
#include <Unreal/Hooks/Hooks.hpp>
#include <Unreal/NameTypes.hpp>
#include <Unreal/UObject.hpp>
#include <Unreal/UObjectArray.hpp>
#include <Unreal/UObjectGlobals.hpp>

using namespace RC;
using namespace RC::Unreal;

namespace
{
    constexpr auto MOD_VERSION = STR("0.5.0");
    constexpr uint8 RESPONSE_ENABLE = 0;
    constexpr uint8 RESPONSE_NOT_ENOUGH_ITEMS = 4;

    struct Config
    {
        bool Enabled = true;
        bool IncludeGuildChest = true;
        double ScanSeconds = 15.0;
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
        Output::send<LogLevel::Default>(STR("[PalBaseStorage] {}\n"), msg);
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
        return std::filesystem::path(buffer).parent_path().parent_path();
    }

    auto LoadConfig() -> void
    {
        std::ifstream file(g_modDir / "config.txt");
        if (!file) return;
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
            else if (key == "includeguildchest") g_cfg.IncludeGuildChest = asBool;
            else if (key == "scanseconds") g_cfg.ScanSeconds = std::clamp(asNum, 3.0, 300.0);
            else if (key == "verboselogging") g_cfg.VerboseLogging = asBool;
        }
    }

    struct RawArray
    {
        uint8* Data;
        int32 Num;
        int32 Max;
    };

    struct Tracked
    {
        UObject* Object = nullptr;
        int32 Index = -1;
    };

    auto IsAlive(const Tracked& t) -> bool
    {
        if (!t.Object) return false;
        auto item = UObjectArray::IndexToObject(t.Index);
        return item && item->GetUObject() == t.Object && !item->IsUnreachable() && !item->IsPendingKill();
    }

    auto IsAlive(UObject* obj) -> bool
    {
        return obj && IsAlive(Tracked{obj, obj->GetInternalIndex()});
    }

    auto TrackedFind(Tracked& t, const CharType* className) -> UObject*
    {
        if (IsAlive(t)) return t.Object;
        auto obj = UObjectGlobals::FindFirstOf(className);
        t = obj ? Tracked{obj, obj->GetInternalIndex()} : Tracked{};
        return obj;
    }

    // Chamada de UFunction por reflexão (parâmetros inicializados/destruídos).
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

    // ------------------------------------------------------------------
    // Baús das bases da guilda
    // ------------------------------------------------------------------
    struct GuidKey
    {
        uint32 A, B, C, D;
        bool operator==(const GuidKey&) const = default;
        bool IsZero() const { return (A | B | C | D) == 0; }
    };
    struct GuidHash
    {
        size_t operator()(const GuidKey& g) const { return (static_cast<size_t>(g.A) << 32 ^ g.B) ^ (static_cast<size_t>(g.C) << 16 ^ g.D); }
    };

    int32 g_belongGroupOffset = -1;
    auto ContainerGroup(UObject* container, GuidKey& out) -> bool
    {
        if (g_belongGroupOffset < 0)
        {
            auto belong = static_cast<FStructProperty*>(container->GetPropertyByNameInChain(STR("BelongInfo")));
            if (!belong) return false;
            auto group = belong->GetStruct()->FindProperty(FName(STR("GroupId"), FNAME_Find));
            if (!group) return false;
            g_belongGroupOffset = belong->GetOffset_Internal() + group->GetOffset_Internal();
        }
        std::memcpy(&out, reinterpret_cast<uint8*>(container) + g_belongGroupOffset, sizeof(GuidKey));
        return true;
    }

    std::vector<Tracked> g_storage;
    size_t g_lastLoggedCount = static_cast<size_t>(-1);

    auto ScanStorage() -> void
    {
        std::unordered_set<GuidKey, GuidHash> groups;
        std::vector<UObject*> bases;
        UObjectGlobals::FindAllOf(STR("PalBaseCampModel"), bases);
        for (auto base : bases)
        {
            if (auto g = base->GetValuePtrByPropertyNameInChain<GuidKey>(STR("GroupIdBelongTo")); g && !g->IsZero()) groups.insert(*g);
        }
        std::vector<Tracked> found;
        auto chestClass = UObjectGlobals::StaticFindObject<UClass*>(nullptr, nullptr, STR("/Script/Pal.PalMapObjectItemChestModel"));
        if (chestClass && !groups.empty())
        {
            std::vector<UObject*> modules;
            UObjectGlobals::FindAllOf(STR("PalMapObjectItemContainerModule"), modules);
            for (auto module : modules)
            {
                auto owner = module->GetOuterPrivate();
                if (!owner || !owner->IsA(chestClass)) continue;
                auto container = module->GetValuePtrByPropertyNameInChain<UObject*>(STR("TargetContainer"));
                if (!container || !*container || !IsAlive(*container)) continue;
                GuidKey group{};
                if (!ContainerGroup(*container, group) || !groups.contains(group)) continue;
                found.push_back({*container, (*container)->GetInternalIndex()});
            }
        }
        int guildChests = 0;
        if (g_cfg.IncludeGuildChest)
        {
            std::vector<UObject*> storages;
            UObjectGlobals::FindAllOf(STR("PalGuildItemStorage"), storages);
            for (auto storage : storages)
            {
                auto container = storage->GetValuePtrByPropertyNameInChain<UObject*>(STR("ItemContainer"));
                if (!container || !*container || !IsAlive(*container)) continue;
                found.push_back({*container, (*container)->GetInternalIndex()});
                ++guildChests;
            }
        }
        g_storage.swap(found);
        if (g_storage.size() != g_lastLoggedCount)
        {
            g_lastLoggedCount = g_storage.size();
            Log(std::format(STR("{} baú(s) disponíveis para fabricar ({} base(s) da guilda, {} Baú(s) da Guilda)."), g_storage.size(),
                            groups.size(), guildChests));
        }
    }

    // ------------------------------------------------------------------
    // Contagem e movimentação de itens
    // ------------------------------------------------------------------
    struct SlotInfo
    {
        UObject* Slot;
        int32 Count;
        int32 SlotIndex;
        uint8 ContainerId[16];
    };

    auto ForEachSlot(UObject* container, const FName& itemId, auto&& fn) -> void
    {
        auto slots = container->GetValuePtrByPropertyNameInChain<RawArray>(STR("ItemSlotArray"));
        if (!slots || !slots->Data || slots->Num <= 0 || slots->Num > 5000) return;
        for (int32 i = 0; i < slots->Num; ++i)
        {
            auto slot = reinterpret_cast<UObject**>(slots->Data)[i];
            if (!slot) continue;
            auto id = slot->GetValuePtrByPropertyNameInChain<FName>(STR("ItemId"));
            auto count = slot->GetValuePtrByPropertyNameInChain<int32>(STR("StackCount"));
            auto index = slot->GetValuePtrByPropertyNameInChain<int32>(STR("SlotIndex"));
            auto cid = slot->GetValuePtrByPropertyNameInChain<uint8>(STR("ContainerId"));
            if (!id || !count || !index || !cid || *count <= 0 || *id != itemId) continue;
            SlotInfo info{slot, *count, *index, {}};
            std::memcpy(info.ContainerId, cid, 16);
            fn(info);
        }
    }

    auto CountIn(UObject* container, const FName& itemId) -> int64
    {
        int64 total = 0;
        ForEachSlot(container, itemId, [&](const SlotInfo& s) { total += s.Count; });
        return total;
    }

    Tracked g_inventory;
    Tracked g_itemNet;

    // Contêiner comum do inventário do jogador (EPalPlayerInventoryType::Common = 0).
    auto CommonContainer(UObject*& container, uint8* containerId) -> bool
    {
        auto inv = TrackedFind(g_inventory, STR("PalPlayerInventoryData"));
        if (!inv) return false;
        auto fn = inv->GetFunctionByNameInChain(STR("TryGetContainerFromInventoryType"));
        auto fnId = inv->GetFunctionByNameInChain(STR("TryGetContainerIDFromInventoryType"));
        if (!fn || !fnId) return false;
        {
            ParamBuffer params(fn);
            *params.Ptr(STR("inventoryType")) = 0;
            params.Call(inv);
            auto out = params.Ptr(STR("OutContainer"));
            auto ret = params.Ptr(STR("ReturnValue"));
            if (!out || !ret || !*ret) return false;
            container = *reinterpret_cast<UObject**>(out);
        }
        {
            ParamBuffer params(fnId);
            *params.Ptr(STR("inventoryType")) = 0;
            params.Call(inv);
            auto out = params.Ptr(STR("OutContainerId"));
            auto ret = params.Ptr(STR("ReturnValue"));
            if (!out || !ret || !*ret) return false;
            std::memcpy(containerId, out, 16);
        }
        return container != nullptr;
    }

    // Quantidade do item que o jogo considera "no inventário" (todos os
    // contêineres do ajudante do inventário, sem os baús).
    auto CountInInventory(const FName& itemId) -> int64
    {
        auto inv = TrackedFind(g_inventory, STR("PalPlayerInventoryData"));
        if (!inv) return 0;
        auto helper = inv->GetValuePtrByPropertyNameInChain<UObject*>(STR("InventoryMultiHelper"));
        if (!helper || !*helper) return 0;
        auto arr = (*helper)->GetValuePtrByPropertyNameInChain<RawArray>(STR("Containers"));
        if (!arr || !arr->Data || arr->Num <= 0 || arr->Num > 64) return 0;
        int64 total = 0;
        for (int32 i = 0; i < arr->Num; ++i)
        {
            auto c = reinterpret_cast<UObject**>(arr->Data)[i];
            if (c) total += CountIn(c, itemId);
        }
        return total;
    }

    auto CountInStorage(const FName& itemId) -> int64
    {
        int64 total = 0;
        for (auto& t : g_storage)
            if (IsAlive(t)) total += CountIn(t.Object, itemId);
        return total;
    }

    std::mt19937 g_rng{std::random_device{}()};

    // Move `num` itens de um slot de baú para o contêiner comum do jogador.
    auto MoveToInventory(const SlotInfo& from, int32 num, const uint8* toContainerId) -> bool
    {
        auto net = TrackedFind(g_itemNet, STR("PalNetworkItemComponent"));
        if (!net) return false;
        auto fn = net->GetFunctionByNameInChain(STR("RequestMoveToContainer_ToServer"));
        if (!fn) return false;
        ParamBuffer params(fn);
        auto requestId = reinterpret_cast<uint32*>(params.Ptr(STR("RequestID")));
        auto to = params.Ptr(STR("ToContainerId"));
        auto fromsProp = static_cast<FArrayProperty*>(params.Prop(STR("Froms")));
        auto froms = reinterpret_cast<RawArray*>(params.Ptr(STR("Froms")));
        if (!requestId || !to || !fromsProp || !froms) return false;
        for (int k = 0; k < 4; ++k) requestId[k] = g_rng();
        std::memcpy(to, toContainerId, 16);
        int32 elemSize = fromsProp->GetInner()->GetElementSize();
        auto elem = static_cast<uint8*>(FMemory::Malloc(elemSize));
        std::memset(elem, 0, elemSize);
        std::memcpy(elem, from.ContainerId, 16);
        *reinterpret_cast<int32*>(elem + 16) = from.SlotIndex;
        *reinterpret_cast<int32*>(elem + 20) = num;
        froms->Data = elem;
        froms->Num = 1;
        froms->Max = 1;
        params.Call(net);
        return true;
    }

    // ------------------------------------------------------------------
    // Receita da bancada
    // ------------------------------------------------------------------
    struct Requirement
    {
        FName Id;
        int32 Num;
    };

    auto RequiredMaterials(UObject* convertUiModel, std::vector<Requirement>& out) -> bool
    {
        auto settingPtr = convertUiModel->GetValuePtrByPropertyNameInChain<UObject*>(STR("ProductSettingModel"));
        if (!settingPtr || !*settingPtr) return false;
        auto setting = *settingPtr;
        auto fn = setting->GetFunctionByNameInChain(STR("GetRequiredMaterialInfos"));
        if (!fn) return false;
        ParamBuffer params(fn);
        if (auto oneUnit = params.Ptr(STR("OneUnit"))) *oneUnit = 0;
        params.Call(setting);
        auto arr = reinterpret_cast<RawArray*>(params.Ptr(STR("RequiredMaterialInfos")));
        if (!arr || !arr->Data || arr->Num <= 0 || arr->Num > 32) return false;
        for (int32 i = 0; i < arr->Num; ++i)
        {
            auto e = arr->Data + static_cast<size_t>(i) * 12; // FPalStaticItemIdAndNum {FName, int32}
            out.push_back({*reinterpret_cast<FName*>(e), *reinterpret_cast<int32*>(e + 8)});
        }
        return true;
    }

    // Inventário + baús bastam para todos os materiais?
    auto EnoughWithStorage(const std::vector<Requirement>& reqs) -> bool
    {
        for (auto& r : reqs)
            if (CountInInventory(r.Id) + CountInStorage(r.Id) < r.Num) return false;
        return true;
    }

    int g_pulledLogs = 0;

    auto PullMissing(const std::vector<Requirement>& reqs) -> void
    {
        UObject* common = nullptr;
        uint8 commonId[16]{};
        if (!CommonContainer(common, commonId)) return;
        for (auto& r : reqs)
        {
            int64 missing = r.Num - CountInInventory(r.Id);
            if (missing <= 0) continue;
            int64 pulled = 0;
            for (auto& t : g_storage)
            {
                if (missing <= 0 || !IsAlive(t)) continue;
                std::vector<SlotInfo> slots;
                ForEachSlot(t.Object, r.Id, [&](const SlotInfo& s) { slots.push_back(s); });
                for (auto& s : slots)
                {
                    if (missing <= 0) break;
                    int32 take = static_cast<int32>(std::min<int64>(missing, s.Count));
                    if (MoveToInventory(s, take, commonId))
                    {
                        missing -= take;
                        pulled += take;
                    }
                }
            }
            if (g_cfg.VerboseLogging || g_pulledLogs < 30)
            {
                ++g_pulledLogs;
                Log(std::format(STR("Fabricar: {} x{} trazido(s) dos baús{}."), r.Id.ToString(), pulled,
                                missing > 0 ? std::format(STR(" (ainda faltam {})"), missing) : StringType()));
            }
        }
    }

    // ------------------------------------------------------------------
    // Ganchos da interface da bancada
    // ------------------------------------------------------------------
    auto OnCanStartPost(UnrealScriptFunctionCallableContext& context, void*) -> void
    {
        if (!context.RESULT_DECL || !context.Context) return;
        auto result = static_cast<uint8*>(context.RESULT_DECL);
        if (*result != RESPONSE_NOT_ENOUGH_ITEMS) return;
        std::vector<Requirement> reqs;
        if (!RequiredMaterials(context.Context, reqs) || reqs.empty()) return;
        if (EnoughWithStorage(reqs))
        {
            *result = RESPONSE_ENABLE;
            LogV(STR("Bancada: materiais completos com os baús; botão liberado."));
        }
    }

    auto OnStartProductionPre(UnrealScriptFunctionCallableContext& context, void*) -> void
    {
        if (!context.Context) return;
        std::vector<Requirement> reqs;
        if (!RequiredMaterials(context.Context, reqs) || reqs.empty()) return;
        PullMissing(reqs);
    }

    // ------------------------------------------------------------------
    // v0.5.0: construir usando os baús.
    //   - UPalBuilderComponent:IsExistsMaterialForBuildObject (pós) e
    //     IsEnableBuild (pós): libera quando inventário + baús bastam;
    //   - UPalUIBuildingModel:BuildObject e PalNetworkPlayerComponent:
    //     RequestBuild_ToServer (pré): traz dos baús o que falta.
    // ------------------------------------------------------------------
    constexpr uint8 BUILD_NOT_ENOUGH_MATERIALS = 17;
    constexpr uint8 BUILD_OK = 0;

    // Materiais de uma linha FPalBuildObjectData (Material1..4_Id/_Count).
    auto BuildRequirements(UStruct* rowStruct, uint8* row, std::vector<Requirement>& out) -> void
    {
        for (int k = 1; k <= 4; ++k)
        {
            auto idProp = rowStruct->FindProperty(FName(std::format(STR("Material{}_Id"), k).c_str(), FNAME_Find));
            auto countProp = rowStruct->FindProperty(FName(std::format(STR("Material{}_Count"), k).c_str(), FNAME_Find));
            if (!idProp || !countProp) continue;
            auto id = *reinterpret_cast<FName*>(row + idProp->GetOffset_Internal());
            auto count = *reinterpret_cast<int32*>(row + countProp->GetOffset_Internal());
            if (count > 0 && id.ToString() != STR("None")) out.push_back({id, count});
        }
    }

    Tracked g_buildTable;
    auto BuildRequirementsById(const FName& buildObjectId, std::vector<Requirement>& out) -> bool
    {
        if (!IsAlive(g_buildTable))
        {
            std::vector<UObject*> tables;
            UObjectGlobals::FindAllOf(STR("DataTable"), tables);
            for (auto t : tables)
            {
                if (t->GetName() == STR("DT_BuildObjectDataTable")) { g_buildTable = {t, t->GetInternalIndex()}; break; }
            }
            if (!IsAlive(g_buildTable)) return false;
        }
        auto dt = static_cast<UDataTable*>(g_buildTable.Object);
        auto rowStruct = dt->GetRowStruct().Get();
        auto row = dt->FindRowUnchecked(buildObjectId);
        if (!rowStruct || !row) return false;
        BuildRequirements(rowStruct, row, out);
        return true;
    }

    auto SelectedBuildObject(UObject* builder, FName& out) -> bool
    {
        auto fn = builder->GetFunctionByNameInChain(STR("GetSelectedBuildObjectId"));
        if (!fn) return false;
        ParamBuffer params(fn);
        params.Call(builder);
        auto id = params.Ptr(STR("OutSelectedBuildObjectId"));
        if (!id) return false;
        out = *reinterpret_cast<FName*>(id);
        return out.ToString() != STR("None");
    }

    auto OnExistsMaterialPost(UnrealScriptFunctionCallableContext& context, void*) -> void
    {
        if (!context.RESULT_DECL) return;
        auto result = static_cast<bool*>(context.RESULT_DECL);
        if (*result) return;
        auto fn = context.TheStack.Node();
        auto prop = static_cast<FStructProperty*>(fn->FindProperty(FName(STR("BuildObjectData"), FNAME_Find)));
        if (!prop) return;
        std::vector<Requirement> reqs;
        BuildRequirements(prop->GetStruct(), context.TheStack.Locals() + prop->GetOffset_Internal(), reqs);
        if (!reqs.empty() && EnoughWithStorage(reqs)) *result = true;
    }

    auto OnEnableBuildPost(UnrealScriptFunctionCallableContext& context, void*) -> void
    {
        if (!context.RESULT_DECL || !context.Context) return;
        auto result = static_cast<uint8*>(context.RESULT_DECL);
        if (*result != BUILD_NOT_ENOUGH_MATERIALS) return;
        FName id;
        std::vector<Requirement> reqs;
        if (!SelectedBuildObject(context.Context, id) || !BuildRequirementsById(id, reqs) || reqs.empty()) return;
        if (EnoughWithStorage(reqs)) *result = BUILD_OK;
    }

    auto PullForBuild(const FName& id) -> void
    {
        std::vector<Requirement> reqs;
        if (!BuildRequirementsById(id, reqs) || reqs.empty()) return;
        bool missing = false;
        for (auto& r : reqs)
            if (CountInInventory(r.Id) < r.Num) missing = true;
        if (missing) PullMissing(reqs);
    }

    auto OnBuildObjectPre(UnrealScriptFunctionCallableContext& context, void*) -> void
    {
        if (!context.Context) return;
        auto id = context.Context->GetValuePtrByPropertyNameInChain<FName>(STR("BuildObjectId"));
        if (id) PullForBuild(*id);
    }

    auto OnRequestBuildPre(UnrealScriptFunctionCallableContext& context, void*) -> void
    {
        auto fn = context.TheStack.Node();
        auto prop = fn->FindProperty(FName(STR("BuildObjectId"), FNAME_Find));
        if (!prop) return;
        PullForBuild(*reinterpret_cast<FName*>(context.TheStack.Locals() + prop->GetOffset_Internal()));
    }

    // ------------------------------------------------------------------
    // v0.4.1: receitas cujo item você já possui (aba de itens importantes,
    // ex.: selas/equipamentos de Pal) ficam com o fundo verde na bancada.
    // ------------------------------------------------------------------
    struct LinearColor
    {
        float R, G, B, A;
    };
    std::unordered_map<UObject*, LinearColor> g_originalBase; // por widget de imagem
    FName g_nameUpdateSufficient;
    FName g_nameSetupProduct;
    FName g_nameSlotClass;

    auto EssentialContainer() -> UObject*
    {
        auto inv = TrackedFind(g_inventory, STR("PalPlayerInventoryData"));
        if (!inv) return nullptr;
        auto fn = inv->GetFunctionByNameInChain(STR("TryGetContainerFromInventoryType"));
        if (!fn) return nullptr;
        ParamBuffer params(fn);
        *params.Ptr(STR("inventoryType")) = 2; // Essential
        params.Call(inv);
        auto out = params.Ptr(STR("OutContainer"));
        auto ret = params.Ptr(STR("ReturnValue"));
        return (out && ret && *ret) ? *reinterpret_cast<UObject**>(out) : nullptr;
    }

    auto SetImageColor(UObject* image, const LinearColor& color) -> void
    {
        auto fn = image->GetFunctionByNameInChain(STR("SetColorAndOpacity"));
        if (!fn) return;
        ParamBuffer params(fn);
        auto c = params.Ptr(STR("InColorAndOpacity"));
        if (!c) return;
        *reinterpret_cast<LinearColor*>(c) = color;
        params.Call(image);
    }

    auto TintRecipeSlot(UObject* slot) -> void
    {
        auto productId = slot->GetValuePtrByPropertyNameInChain<FName>(STR("Product ItemId"));
        auto basePtr = slot->GetValuePtrByPropertyNameInChain<UObject*>(STR("Base"));
        if (!productId || !basePtr || !*basePtr) return;
        auto base = *basePtr;
        if (!g_originalBase.contains(base))
        {
            auto current = base->GetValuePtrByPropertyNameInChain<LinearColor>(STR("ColorAndOpacity"));
            g_originalBase[base] = current ? *current : LinearColor{1, 1, 1, 1};
            if (g_originalBase.size() > 2000) g_originalBase.clear();
        }
        bool owned = false;
        if (auto essential = EssentialContainer()) owned = CountIn(essential, *productId) > 0;
        SetImageColor(base, owned ? LinearColor{0.25f, 0.85f, 0.35f, 1.0f} : g_originalBase[base]);
    }

    auto OnScriptPost(UObject* context, FFrame& stack) -> void
    {
        auto fn = stack.Node();
        if (!fn || !context) return;
        auto name = fn->GetNamePrivate();
        if (name != g_nameUpdateSufficient && name != g_nameSetupProduct) return;
        auto outer = fn->GetOuterPrivate();
        if (!outer || outer->GetNamePrivate() != g_nameSlotClass) return;
        TintRecipeSlot(context);
    }

    bool g_hooksRegistered = false;
    auto RegisterHooks() -> void
    {
        g_hooksRegistered = true;
        int count = 0;
        if (auto fn = UObjectGlobals::StaticFindObject<UFunction*>(nullptr, nullptr, STR("/Script/Pal.PalUIConvertItemModel:CanStartProduction")))
        {
            UObjectGlobals::RegisterHook(fn, [](UnrealScriptFunctionCallableContext&, void*) {}, OnCanStartPost, nullptr);
            ++count;
        }
        if (auto fn = UObjectGlobals::StaticFindObject<UFunction*>(nullptr, nullptr, STR("/Script/Pal.PalUIConvertItemModel:StartProduction")))
        {
            UObjectGlobals::RegisterHook(fn, OnStartProductionPre, [](UnrealScriptFunctionCallableContext&, void*) {}, nullptr);
            ++count;
        }
        struct BuildHook { const CharType* Path; bool Pre; void (*Fn)(UnrealScriptFunctionCallableContext&, void*); };
        static const BuildHook buildHooks[] = {
                {STR("/Script/Pal.PalBuilderComponent:IsExistsMaterialForBuildObject"), false, OnExistsMaterialPost},
                {STR("/Script/Pal.PalBuilderComponent:IsEnableBuild"), false, OnEnableBuildPost},
                {STR("/Script/Pal.PalUIBuildingModel:BuildObject"), true, OnBuildObjectPre},
                {STR("/Script/Pal.PalNetworkPlayerComponent:RequestBuild_ToServer"), true, OnRequestBuildPre},
        };
        for (auto& h : buildHooks)
        {
            auto fn = UObjectGlobals::StaticFindObject<UFunction*>(nullptr, nullptr, h.Path);
            if (!fn) continue;
            if (h.Pre) UObjectGlobals::RegisterHook(fn, h.Fn, [](UnrealScriptFunctionCallableContext&, void*) {}, nullptr);
            else UObjectGlobals::RegisterHook(fn, [](UnrealScriptFunctionCallableContext&, void*) {}, h.Fn, nullptr);
            ++count;
        }
        g_nameUpdateSufficient = FName(STR("UpdateSufficient"), FNAME_Add);
        g_nameSetupProduct = FName(STR("SetupProductItemInfo"), FNAME_Add);
        g_nameSlotClass = FName(STR("WBP_PalConvertItemMenu_RecipeSlotButton_C"), FNAME_Add);
        Hook::RegisterProcessLocalScriptFunctionPostCallback(
                [](Hook::TCallbackIterationData<void>&, UObject* context, FFrame& stack, void*) { OnScriptPost(context, stack); },
                {false, false, STR("PalBaseStorage"), STR("RecipeTint")});
        Log(std::format(STR("{} gancho(s) da bancada registrados."), count));
    }

    double g_clock = 0.0;
    double g_nextScan = 5.0;

    auto OnTick(float deltaSeconds) -> void
    {
        g_clock += std::clamp(static_cast<double>(deltaSeconds), 0.0, 1.0);
        if (!g_hooksRegistered && g_clock > 3.0) RegisterHooks();
        if (g_clock >= g_nextScan)
        {
            g_nextScan = g_clock + g_cfg.ScanSeconds;
            if (UObjectGlobals::FindFirstOf(STR("PalPlayerCharacter"))) ScanStorage();
        }
    }
} // namespace

class PalBaseStorage : public CppUserModBase
{
public:
    PalBaseStorage() : CppUserModBase()
    {
        ModName = STR("PalBaseStorage");
        ModVersion = MOD_VERSION;
        ModDescription = STR("Fabricar usando os baús das bases da guilda.");
        ModAuthors = STR("lbcamargo94");
    }

    ~PalBaseStorage() override = default;

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
                {false, false, STR("PalBaseStorage"), STR("Tick")});
        Log(std::format(STR("v{} carregado (Baú da Guilda: {})."), MOD_VERSION, g_cfg.IncludeGuildChest ? STR("sim") : STR("não")));
    }
};

#define PAL_BASE_STORAGE_API __declspec(dllexport)
extern "C"
{
    PAL_BASE_STORAGE_API CppUserModBase* start_mod()
    {
        return new PalBaseStorage();
    }

    PAL_BASE_STORAGE_API void uninstall_mod(CppUserModBase* mod)
    {
        delete mod;
    }
}
