-- ============================================================================
-- Bigger Storage v0.1.2 (descoberta)
-- ============================================================================
-- Fase 1: SÓ LEITURA. Levanta quantos slots cada container tem por padrão,
-- para depois definirmos quantos slots cada um vai ganhar.
--
-- Nomes encontrados no executável (patch 2026-09-15), sem a classe dona:
--   ItemChestSlotNum, GuildChestSlotNum, ChestSlotNum, ContainerSlotNum,
--   StoreSlotNum, SlotNum, ItemChestSetting, SetInventorySize,
--   RequestExtendSlotNum_ServerInternal
--
-- O relatório é gravado ~20 s depois que o personagem aparece no mundo e
-- de novo com Ctrl+F10 (abra alguns baús antes, se quiser). Sai no
-- UE4SS.log e em Mods\BiggerStorage\discovery.txt:
--   1. PROP  - classes/structs com propriedades de slot (nome:tipo)
--   2. DT    - DataTables cujas linhas têm campos de slot, com os valores
--   3. CDO   - valores padrão (Default__) das classes com campos de slot
--   4. BAÚ   - baús/caixas colocados no mundo: tipo e slots reais
--   5. INV   - containers do inventário do jogador e seus slots
--   6. TODOS - todos os PalItemContainer agrupados por dono e nº de slots
--
-- Segurança: só lê propriedades que a reflexão confirmou existirem
-- (acessar propriedade inexistente causa ACCESS_VIOLATION mesmo em pcall).
-- Não chama funções do jogo que alterem estado.
-- ============================================================================

local LOG_PREFIX  = "[BiggerStorage]"
local MOD_VERSION = "0.1.2"

local SLOT_PATTERNS = { "SlotNum", "SlotCount", "InventorySize", "ContainerSize", "ChestSetting" }
local DT_NAME_PATTERNS = { "Chest", "Container", "Inventory", "Storage", "MapObject" }

local CHEST_CLASSES = {
    "PalMapObjectItemChestModel",
    "PalMapObjectItemChest_AffectCorruption",
    "PalMapObjectGuildChestModel",
    "PalMapObjectPalFoodBoxModel",
}

local REPORT_PATHS = {
    "Mods\\BiggerStorage\\discovery.txt",
    "ue4ss\\Mods\\BiggerStorage\\discovery.txt",
}

-- ============================================================================
-- LOG / RELATÓRIO
-- ============================================================================
local reportLines = {}

local function log(msg)
    print(LOG_PREFIX .. " " .. tostring(msg) .. "\n")
end

local function out(msg)
    reportLines[#reportLines + 1] = msg
    log(msg)
end

local function WriteReport()
    for _, p in ipairs(REPORT_PATHS) do
        local f = io.open(p, "w")
        if f then
            f:write(table.concat(reportLines, "\n"), "\n")
            f:close()
            log("Relatório gravado em " .. p)
            return
        end
    end
    log("Não consegui gravar discovery.txt - veja o UE4SS.log.")
end

-- ============================================================================
-- UTILITÁRIOS
-- ============================================================================
local function valid(obj)
    if not obj then return false end
    local ok, v = pcall(function() return obj:IsValid() end)
    return ok and v
end

local function str(v)
    if type(v) ~= "userdata" then return tostring(v) end
    local ok, s = pcall(function() return v:ToString() end)
    return ok and s or tostring(v)
end

local function fname(obj)
    local ok, s = pcall(function() return obj:GetFName():ToString() end)
    return ok and s or "?"
end

local function fullName(obj)
    local ok, s = pcall(function() return obj:GetFullName() end)
    return ok and s or "?"
end

local function matchesAny(name, patterns)
    for _, p in ipairs(patterns) do
        if name:find(p, 1, true) then return true end
    end
    return false
end

local function arrayCount(arr)
    local ok, n = pcall(function() return arr:GetArrayNum() end)
    if ok then return n end
    local ok2, n2 = pcall(function() return #arr end)
    return ok2 and n2 or -1
end

local function guidKey(g)
    return ("%08X%08X%08X%08X"):format(g.A & 0xFFFFFFFF, g.B & 0xFFFFFFFF, g.C & 0xFFFFFFFF, g.D & 0xFFFFFFFF)
end

-- Propriedades de uma classe/struct incluindo as herdadas:
-- lista de { name =, type =, prop = }.
local propCache = {}
local function AllProps(struct)
    local key = fullName(struct)
    if propCache[key] then return propCache[key] end
    local list, s, guard = {}, struct, 0
    while valid(s) and guard < 32 do
        guard = guard + 1
        pcall(function()
            s:ForEachProperty(function(prop)
                list[#list + 1] = {
                    name = prop:GetFName():ToString(),
                    type = prop:GetClass():GetFName():ToString(),
                    prop = prop,
                }
            end)
        end)
        local ok, super = pcall(function() return s:GetSuperStruct() end)
        s = ok and super or nil
    end
    propCache[key] = list
    return list
end

local function PropMap(struct)
    local map = {}
    for _, p in ipairs(AllProps(struct)) do map[p.name] = p end
    return map
end

local function InnerStruct(p)
    local ok, s = pcall(function() return p.prop:GetStruct() end)
    if ok and valid(s) then return s end
    return nil
end

-- Lê os campos de slot (int/byte) de um valor (objeto ou struct) cujo tipo
-- é `struct`; desce um nível em StructProperty (ex.: ItemChestSetting).
local function SlotValues(value, struct, prefix, depth)
    local parts = {}
    depth = depth or 0
    for _, p in ipairs(AllProps(struct)) do
        local label = (prefix or "") .. p.name
        if (p.type == "IntProperty" or p.type == "ByteProperty" or p.type == "Int16Property")
            and matchesAny(p.name, SLOT_PATTERNS) then
            local ok, v = pcall(function() return value[p.name] end)
            parts[#parts + 1] = label .. "=" .. (ok and str(v) or "?")
        elseif p.type == "StructProperty" and depth < 1 then
            local inner = InnerStruct(p)
            if inner and (matchesAny(p.name, SLOT_PATTERNS) or matchesAny(fname(inner), { "Chest", "Container", "Inventory" })) then
                local ok, sub = pcall(function() return value[p.name] end)
                if ok and sub then
                    for _, x in ipairs(SlotValues(sub, inner, label .. ".", depth + 1)) do
                        parts[#parts + 1] = x
                    end
                end
            end
        end
    end
    return parts
end

local function HasSlotFields(struct)
    for _, p in ipairs(AllProps(struct)) do
        if matchesAny(p.name, SLOT_PATTERNS) then return true end
        if p.type == "StructProperty" then
            local inner = InnerStruct(p)
            if inner then
                for _, q in ipairs(AllProps(inner)) do
                    if matchesAny(q.name, SLOT_PATTERNS) then return true end
                end
            end
        end
    end
    return false
end

-- ============================================================================
-- 1-3. REFLEXÃO, DATATABLES E CDOs (uma passada em todos os objetos)
-- ============================================================================
local function ScanTypesAndDefaults()
    local typesWithSlots = {}   -- [nome completo da classe] = true
    local dataTables, cdos = {}, {}

    ForEachUObject(function(obj)
        pcall(function()
            local kind = obj:GetClass():GetFName():ToString()
            if kind == "Class" or kind == "ScriptStruct" or kind == "BlueprintGeneratedClass" then
                local parts = {}
                obj:ForEachProperty(function(prop)
                    local name = prop:GetFName():ToString()
                    if matchesAny(name, SLOT_PATTERNS) then
                        parts[#parts + 1] = name .. ":" .. prop:GetClass():GetFName():ToString()
                    end
                end)
                if #parts > 0 then
                    typesWithSlots[obj:GetFullName()] = true
                    out("PROP " .. obj:GetFullName() .. " {" .. table.concat(parts, ", ") .. "}")
                end
            elseif kind == "DataTable" or kind == "CompositeDataTable" then
                dataTables[#dataTables + 1] = obj
            elseif obj:GetFName():ToString():sub(1, 9) == "Default__" then
                cdos[#cdos + 1] = obj
            end
        end)
    end)

    out("")
    out(string.format("== DataTables (%d carregadas) ==", #dataTables))
    for _, dt in ipairs(dataTables) do
        pcall(function()
            local rowStruct = dt.RowStruct
            if not valid(rowStruct) then return end
            local name = fname(dt)
            if HasSlotFields(rowStruct) then
                out("DT " .. fullName(dt) .. " (linha: " .. fname(rowStruct) .. ")")
                dt:ForEachRow(function(rowName, row)
                    local parts = SlotValues(row, rowStruct)
                    if #parts > 0 then
                        out("DT   " .. str(rowName) .. ": " .. table.concat(parts, ", "))
                    end
                end)
            elseif matchesAny(name, DT_NAME_PATTERNS) then
                local fields = {}
                for _, p in ipairs(AllProps(rowStruct)) do fields[#fields + 1] = p.name .. ":" .. p.type end
                out("DT? " .. fullName(dt) .. " sem campo de slot; campos: " .. table.concat(fields, ", "))
            end
        end)
    end

    out("")
    out("== Valores padrão (CDO) ==")
    for _, cdo in ipairs(cdos) do
        pcall(function()
            local cls = cdo:GetClass()
            if not HasSlotFields(cls) then return end
            local parts = SlotValues(cdo, cls)
            if #parts > 0 then
                out("CDO " .. fullName(cls) .. ": " .. table.concat(parts, ", "))
            end
        end)
    end
end

-- ============================================================================
-- 4-6. CONTAINERS VIVOS
-- ============================================================================
local function ContainerIndex()
    local index, list = {}, {}
    for _, c in ipairs(FindAllOf("PalItemContainer") or {}) do
        pcall(function()
            if not valid(c) then return end
            local rec = { obj = c, slots = arrayCount(c.ItemSlotArray), used = 0 }
            pcall(function()
                c.ItemSlotArray:ForEach(function(_, elem)
                    local slot = elem:get()
                    local okE, empty = pcall(function() return slot:IsEmpty() end)
                    if okE and not empty then rec.used = rec.used + 1 end
                end)
            end)
            local ok, k = pcall(function() return guidKey(c.ID.ID) end)
            rec.key = ok and k or fullName(c)
            index[rec.key] = rec
            list[#list + 1] = rec
        end)
    end
    return index, list
end

-- Componentes de parâmetro que definem os slots de cada tipo de objeto da base
-- (encontrados na v0.1.0). O valor real fica no template do componente dentro
-- do blueprint de cada tipo (ex.: BP_ItemChest_02_C), não no CDO da classe C++.
local PARAM_CLASSES = {
    PalMapObjectItemChestParameterComponent = "Baú",
    PalMapObjectFoodBoxParameterComponent = "Caixa de comida",
    PalMapObjectMedicineBoxParameterComponent = "Caixa de remédio",
    PalMapObjectFishPondParameterComponent = "Lago de pesca",
    PalMapObjectBreedFarmParameterComponent = "Rancho de cruzamento",
    PalMapObjectMultiHatchingEggWithBreedParameterComponent = "Incubadora c/ cruzamento",
    PalMapObjectItemBoothParameterComponent = "Loja de itens",
    PalMapObjectPalBoothParameterComponent = "Loja de Pals",
    PalMapObjectShippingItemParameterComponent = "Caixa de envio",
    PalMapObjectCollectResourceParameterComponent = "Coleta de recursos",
    PalMapObjectDisplayCharacterParameterComponent = "Expositor de Pals",
    PalMapObjectRecoverOtomoParameterComponent = "Recuperação de Pals",
    PalMapObjectConvertCharacterToItemParameterComponent = "Conversor de Pal em item",
    PalMapObjectRecyclerParameterComponent = "Reciclador",
}

local MASTER_TABLE = "/Game/Pal/DataTable/MapObject/DT_MapObjectMasterDataTable.DT_MapObjectMasterDataTable"
local NAME_TABLE   = "/Game/Pal/DataTable/Text/DT_MapObjectNameText.DT_MapObjectNameText"

-- BlueprintClassName (sem _C) -> { id = MapObjectId, msg = OverrideNameMsgID }
local function MasterIndex()
    local byBp = {}
    local dt = StaticFindObject(MASTER_TABLE)
    if not valid(dt) then return byBp end
    pcall(function()
        dt:ForEachRow(function(rowName, row)
            pcall(function()
                local bp = row.BlueprintClassName:ToString()
                local msg = row.OverrideNameMsgID:ToString()
                byBp[bp] = { id = str(rowName), msg = msg }
            end)
        end)
    end)
    return byBp
end

local function NameIndex()
    local texts = {}
    local dt = StaticFindObject(NAME_TABLE)
    if not valid(dt) then return texts end
    pcall(function()
        dt:ForEachRow(function(rowName, row)
            pcall(function() texts[str(rowName)] = row.TextData:ToString() end)
        end)
    end)
    return texts
end

local function DisplayName(texts, entry)
    if not entry then return "" end
    for _, key in ipairs({ entry.msg, "MAPOBJECT_NAME_" .. entry.id, "COMMON_MAPOBJECT_NAME_" .. entry.id }) do
        if key and key ~= "" and key ~= "None" and texts[key] then return texts[key] end
    end
    local suffix = "_" .. entry.id
    for k, v in pairs(texts) do
        if k:sub(-#suffix) == suffix then return v end
    end
    return ""
end

-- Classe de parâmetro (C++) de um objeto, subindo a hierarquia.
local function ParamClassOf(obj)
    local ok, s = pcall(function() return obj:GetClass() end)
    local guard = 0
    while ok and valid(s) and guard < 16 do
        guard = guard + 1
        local n = fname(s)
        if PARAM_CLASSES[n] then return n, obj:GetClass() end
        ok, s = pcall(function() return s:GetSuperStruct() end)
    end
    return nil
end

-- Tipos nunca construídos no save não estão na memória: carrega os blueprints
-- de armazenamento listados na tabela mestre para que os templates existam.
local LOAD_PATTERNS = { "Chest", "Box", "Storage", "Refrigerator", "Cooler", "Locker", "Shelf" }
-- Pastas vistas no índice do Pal-Windows.pak.
local BUILD_ROOT = "/Game/Pal/Blueprint/MapObject/BuildObject/"
local BUILD_DIRS = { "", "Furniture/", "Base/" }

local function SoftPath(soft)
    for _, getter in ipairs({
        function() return soft:ToString() end,
        function() return soft.SoftObjectPtr.ObjectId.AssetPathName:ToString() end,
        function() return soft.ObjectId.AssetPathName:ToString() end,
    }) do
        local ok, s = pcall(getter)
        if ok and type(s) == "string" and s:sub(1, 1) == "/" then return s end
    end
    return nil
end

local function LoadStorageBlueprints()
    if type(LoadAsset) ~= "function" then
        out("LoadAsset indisponível - só aparecem tipos já carregados.")
        return
    end
    local dt = StaticFindObject(MASTER_TABLE)
    if not valid(dt) then return end
    local loaded, failed, softOk = 0, {}, 0
    local function tryLoad(path)
        local ok, res = pcall(LoadAsset, path)
        return ok and res ~= nil and valid(res)
    end
    pcall(function()
        dt:ForEachRow(function(rowName, row)
            pcall(function()
                local bp = row.BlueprintClassName:ToString()
                if bp:sub(1, 15) ~= "BP_BuildObject_" or not matchesAny(bp, LOAD_PATTERNS) then return end
                local candidates = {}
                local soft = SoftPath(row.BlueprintClassSoft)
                if soft then softOk = softOk + 1; candidates[#candidates + 1] = soft:gsub("_C$", "") end
                for _, dir in ipairs(BUILD_DIRS) do
                    candidates[#candidates + 1] = BUILD_ROOT .. dir .. bp .. "." .. bp
                end
                for _, path in ipairs(candidates) do
                    if tryLoad(path) then loaded = loaded + 1; return end
                end
                failed[#failed + 1] = bp
            end)
        end)
    end)
    out(string.format("(caminho vindo da tabela em %d linha(s))", softOk))
    out(string.format("Blueprints de armazenamento carregados: %d%s", loaded,
        #failed > 0 and (" (falharam: " .. table.concat(failed, ", ") .. ")") or ""))
end

local function ScanTypes()
    out("")
    out("== Tipos de objeto (padrão de cada blueprint) ==")
    LoadStorageBlueprints()
    local entries, order = {}, {}
    ForEachUObject(function(obj)
        pcall(function()
            local kind = obj:GetClass():GetFName():ToString()
            if kind == "Class" or kind == "BlueprintGeneratedClass" or kind == "ScriptStruct" then return end
            local paramName, cls = ParamClassOf(obj)
            if not paramName then return end
            local name = obj:GetFName():ToString()
            local bp, live
            if name:sub(1, 9) == "Default__" then
                if fname(cls) == paramName then return end   -- CDO C++ já está no relatório
                bp, live = fname(cls), false
            else
                local outer = obj:GetOuter()
                local outerKind = outer:GetClass():GetFName():ToString()
                if outerKind == "BlueprintGeneratedClass" then
                    bp, live = fname(outer), false                -- template
                else
                    bp, live = fname(outer:GetClass()), true     -- objeto colocado
                end
            end
            local values = SlotValues(obj, cls)
            local key = paramName .. "|" .. bp .. "|" .. table.concat(values, ", ")
            local e = entries[key]
            if not e then
                e = { param = paramName, bp = bp, values = values, live = 0 }
                entries[key] = e
                order[#order + 1] = key
            end
            if live then e.live = e.live + 1 end
        end)
    end)

    local master, texts = MasterIndex(), NameIndex()
    table.sort(order)
    for _, key in ipairs(order) do
        local e = entries[key]
        local bpBase = e.bp:gsub("_C$", "")
        local m = master[bpBase] or master[e.bp]
        out(string.format("TIPO %s | %s | id=%s | \"%s\" | %s | no mundo: %d",
            PARAM_CLASSES[e.param], e.bp, m and m.id or "?", DisplayName(texts, m),
            table.concat(e.values, ", "), e.live))
    end
end

local function ScanContainers()
    local index, list = ContainerIndex()
    local claimed = {}

    out("")
    out("== Baús e caixas no mundo ==")
    local groups, seen = {}, {}
    for _, className in ipairs(CHEST_CLASSES) do
        for _, model in ipairs(FindAllOf(className) or {}) do
            pcall(function()
                if not valid(model) then return end
                local addr = fullName(model)
                if seen[addr] then return end
                seen[addr] = true
                local container = model:GetItemContainerModule():GetContainer()
                local ok, k = pcall(function() return guidKey(container.ID.ID) end)
                local rec = ok and index[k] or nil
                if rec then claimed[rec.key] = true end
                local gkey = fname(model:GetClass()) .. " | " .. (rec and rec.slots or "?")
                groups[gkey] = (groups[gkey] or 0) + 1
            end)
        end
    end
    for gkey, n in pairs(groups) do
        out(string.format("BAÚ %s slots (x%d no mundo)", gkey, n))
    end

    out("")
    out("== Inventário do jogador ==")
    for _, inv in ipairs(FindAllOf("PalPlayerInventoryData") or {}) do
        pcall(function()
            local infoProp = PropMap(inv:GetClass())["MyInventoryInfo"]
            local infoStruct = infoProp and infoProp.type == "StructProperty" and InnerStruct(infoProp) or nil
            if not infoStruct then
                out("INV sem MyInventoryInfo em " .. fullName(inv))
                return
            end
            local info = inv.MyInventoryInfo
            out("INV " .. fullName(inv) .. " (" .. fname(infoStruct) .. ")")
            for _, p in ipairs(AllProps(infoStruct)) do
                local inner = p.type == "StructProperty" and InnerStruct(p) or nil
                if inner and PropMap(inner)["ID"] then
                    local ok, k = pcall(function() return guidKey(info[p.name].ID) end)
                    local rec = ok and index[k] or nil
                    if rec then claimed[rec.key] = true end
                    out(string.format("INV   %s: %s slots (%s ocupados)", p.name,
                        rec and tostring(rec.slots) or "?", rec and tostring(rec.used) or "?"))
                else
                    out("INV   (campo) " .. p.name .. ":" .. p.type)
                end
            end
            for _, p in ipairs(AllProps(inv:GetClass())) do
                if p.type == "FloatProperty" and p.name:find("Weight") then
                    local ok, v = pcall(function() return inv[p.name] end)
                    out("INV   " .. p.name .. " = " .. (ok and str(v) or "?"))
                end
            end
        end)
    end

    out("")
    out(string.format("== Containers grandes (>= 9 slots) não identificados =="))
    local byOuter = {}
    for _, rec in ipairs(list) do
        if not claimed[rec.key] and rec.slots >= 9 then
            local gkey = rec.slots .. " slots (" .. rec.used .. " ocupados)"
            byOuter[gkey] = (byOuter[gkey] or 0) + 1
        end
    end
    for gkey, n in pairs(byOuter) do
        out(string.format("OUTRO %s (x%d)", gkey, n))
    end
end

-- ============================================================================
-- EXECUÇÃO
-- ============================================================================
-- v0.1.0 já gravou PROP/DT/CDO; v0.1.1 roda só os tipos e os containers.
-- ScanTypesAndDefaults fica disponível para uma nova varredura completa.
local function RunDiscovery(reason)
    reportLines = {}
    out(string.format("Bigger Storage v%s - descoberta (%s) - %s", MOD_VERSION, reason, os.date("%Y-%m-%d %H:%M:%S")))
    local okT, errT = pcall(ScanTypes)
    if not okT then out("Erro nos tipos: " .. tostring(errT)) end
    local ok, err = pcall(ScanContainers)
    if not ok then out("Erro lendo containers: " .. tostring(err)) end
    WriteReport()
end

local autoDone = false
local playerSeenAt = nil

LoopAsync(5000, function()
    if autoDone then return true end
    ExecuteInGameThread(function()
        if autoDone then return end
        local player = FindFirstOf("PalPlayerCharacter")
        if not valid(player) then return end
        playerSeenAt = playerSeenAt or os.time()
        if os.time() - playerSeenAt < 20 then return end
        autoDone = true
        RunDiscovery("automática")
    end)
    return false
end)

RegisterKeyBind(Key.F10, { ModifierKey.CONTROL }, function()
    ExecuteInGameThread(function() RunDiscovery("Ctrl+F10") end)
end)

log(string.format("v%s carregado (descoberta, só leitura). Relatório automático ~20 s após entrar no mundo; Ctrl+F10 repete.", MOD_VERSION))
