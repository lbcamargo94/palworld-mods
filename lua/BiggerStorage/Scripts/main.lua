-- ============================================================================
-- Bigger Storage v0.3.2
-- ============================================================================
-- Aumenta os slots dos baús, caixas e armários da base e do inventário
-- principal do jogador (valores no config.txt). A descoberta que levantou os
-- padrões está em tools\discovery.lua.
--
-- Onde o jogo guarda os slots (patch 2026-09-15):
--   * Cada tipo de baú é um blueprint BP_BuildObject_<Id>_C com um componente
--     <X>ParameterComponent (ItemChest/FoodBox/MedicineBox) cujo SlotNum é o
--     tamanho do container criado na construção. Baús já construídos guardam
--     o tamanho no save e não mudam (nenhuma função exposta os redimensiona).
--   * Baú da guilda: GuildChestSlotNum em PalGameSetting (54).
--   * Inventário principal: PalCheatManager:SetInventorySize(NewSize)
--     (CheatManagerEnablerMod precisa estar ativo).
--
-- Como aplica (v0.2.1 - sem travadas):
--   v0.2.0 carregava os blueprints com LoadAsset; o GC os descarregava e o mod
--   recarregava tudo + varria todos os objetos a cada ~30 s (travadas).
--   Agora o mod não carrega nada: NotifyOnNewObject avisa quando o PRÓPRIO
--   jogo cria um componente de parâmetro (template ao carregar o blueprint, ou
--   componente de um baú colocado) e o SlotNum é ajustado no tick seguinte.
--
-- Segurança: só escreve propriedades que a reflexão confirmou existirem como
-- IntProperty (acessar propriedade inexistente causa ACCESS_VIOLATION mesmo em
-- pcall). Nunca reduz abaixo do padrão do jogo.
-- ============================================================================

local LOG_PREFIX  = "[BiggerStorage]"
local MOD_VERSION = "0.3.4"

local MASTER_TABLE = "/Game/Pal/DataTable/MapObject/DT_MapObjectMasterDataTable.DT_MapObjectMasterDataTable"
local GAME_SETTING_CDO = "/Game/Pal/Blueprint/System/BP_PalGameSetting.Default__BP_PalGameSetting_C"

-- Componentes cujo SlotNum define o tamanho do container do objeto.
local PARAM_CLASSES = {
    "PalMapObjectItemChestParameterComponent",
    "PalMapObjectFoodBoxParameterComponent",
    "PalMapObjectMedicineBoxParameterComponent",
}
local SLOT_FIELD = "SlotNum"

-- Um objeto recém-criado ainda pode receber os valores do arquivo depois do
-- aviso; por isso cada um é conferido algumas vezes antes de sair da fila.
local PENDING_PASSES = 4

local CHEST_CLASSES = {
    "PalMapObjectItemChestModel",
    "PalMapObjectItemChest_AffectCorruption",
    "PalMapObjectGuildChestModel",
    "PalMapObjectPalFoodBoxModel",
}

local CONFIG_DIRS = { "Mods\\BiggerStorage\\", "ue4ss\\Mods\\BiggerStorage\\" }

-- ============================================================================
-- LOGGING
-- ============================================================================
local function log(msg)
    print(LOG_PREFIX .. " " .. tostring(msg) .. "\n")
end

local function logV(msg)
    if Config and Config.VerboseLogging then
        print(LOG_PREFIX .. "[V] " .. tostring(msg) .. "\n")
    end
end

-- ============================================================================
-- CONFIG
-- ============================================================================
Config = {
    Enabled          = true,
    InventorySlots   = 96,
    GuildChestSlots  = 108,
    ShowSlotCounter  = true,
    HitchMonitor     = false,
    HitchThresholdMs = 120,
    VerboseLogging   = false,
}
-- [MapObjectId] = slots desejados (qualquer outra chave numérica do config).
local Targets = {}

local function ParseValue(v)
    if v == "0" or v:lower() == "false" then return false end
    if v == "1" or v:lower() == "true"  then return true  end
    local n = tonumber((v:gsub(",", ".")))
    if n ~= nil then return n end
    return v
end

local modDir = nil

local function LoadConfig()
    local f = nil
    for _, dir in ipairs(CONFIG_DIRS) do
        f = io.open(dir .. "config.txt", "r")
        if f then modDir = dir; break end
    end
    if not f then
        log("config.txt não encontrado - nada será alterado.")
        return
    end
    for line in f:lines() do
        line = line:gsub("[;#].*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" then
            local key, value = line:match("^([%w_]+)%s*=%s*(.-)$")
            if key then
                if Config[key] ~= nil then
                    Config[key] = ParseValue(value)
                elseif key ~= "ScanIntervalMs" then   -- chave antiga (v0.2.0)
                    local n = tonumber((value:gsub(",", ".")))
                    if n and n >= 1 then
                        Targets[key] = math.min(math.floor(n + 0.5), 1000)
                    else
                        log("Valor inválido para " .. key .. ": " .. tostring(value))
                    end
                end
            end
        end
    end
    f:close()
end

local function ConfigSlots(name)
    local n = Config[name]
    if type(n) ~= "number" or n < 1 then return nil end
    return math.min(math.floor(n + 0.5), 1000)
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

local function arrayCount(arr)
    local ok, n = pcall(function() return arr:GetArrayNum() end)
    if ok then return n end
    local ok2, n2 = pcall(function() return #arr end)
    return ok2 and n2 or -1
end

local function guidKey(g)
    return ("%08X%08X%08X%08X"):format(g.A & 0xFFFFFFFF, g.B & 0xFFFFFFFF, g.C & 0xFFFFFFFF, g.D & 0xFFFFFFFF)
end

-- Propriedades da classe/struct e das superclasses: { name, type, prop }.
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

local function HasIntProp(struct, name)
    for _, p in ipairs(AllProps(struct)) do
        if p.name == name then return p.type == "IntProperty" end
    end
    return false
end

local function InnerStruct(p)
    local ok, s = pcall(function() return p.prop:GetStruct() end)
    if ok and valid(s) then return s end
    return nil
end

-- ============================================================================
-- TABELA MESTRE: blueprint -> MapObjectId
-- ============================================================================
local bpToId = {}
local masterReady = false

local function BuildMasterIndex()
    if masterReady then return true end
    local dt = StaticFindObject(MASTER_TABLE)
    if not valid(dt) then return false end
    pcall(function()
        dt:ForEachRow(function(rowName, row)
            pcall(function()
                local bp = row.BlueprintClassName:ToString()
                if bp:sub(1, 15) == "BP_BuildObject_" then bpToId[bp] = str(rowName) end
            end)
        end)
    end)
    masterReady = next(bpToId) ~= nil
    return masterReady
end

local function IdOfClassName(className)
    return bpToId[(className:gsub("_C$", ""))]
end

-- ============================================================================
-- BAÚS: componentes criados pelo jogo
-- ============================================================================
local defaults = {}     -- [id] = slots padrão do jogo
local pending = {}      -- { obj =, passes = }
local stats = { templates = 0, placed = 0 }
local reportedIds = {}

-- Ajusta um componente; devolve true se terminou (ajustado ou não se aplica).
local function ApplyComponent(comp)
    if not valid(comp) then return true end
    if not HasIntProp(comp:GetClass(), SLOT_FIELD) then return true end
    local outer = comp:GetOuter()
    if not valid(outer) then return false end
    local isTemplate = outer:GetClass():GetFName():ToString() == "BlueprintGeneratedClass"
    local className = isTemplate and fname(outer) or fname(outer:GetClass())
    local id = IdOfClassName(className)
    local target = id and Targets[id]
    if not target then return true end
    local current = comp[SLOT_FIELD]
    if isTemplate and defaults[id] == nil and current ~= target then defaults[id] = current end
    local d = defaults[id]
    if d and target < d then target = d end   -- nunca reduz
    if current ~= target then
        comp[SLOT_FIELD] = target
        if isTemplate then stats.templates = stats.templates + 1 else stats.placed = stats.placed + 1 end
        if not reportedIds[id] then
            reportedIds[id] = true
            log(string.format("%s: %s -> %d slots (%s)", id, tostring(current), target,
                isTemplate and "baús novos" or "baú colocado"))
        end
    end
    return false
end

local function ProcessPending()
    if #pending == 0 or not BuildMasterIndex() then return end
    local keep = {}
    for _, item in ipairs(pending) do
        local ok, done = pcall(ApplyComponent, item.obj)
        item.passes = item.passes + 1
        if ok and not done and item.passes < PENDING_PASSES then keep[#keep + 1] = item end
    end
    pending = keep
end

-- ============================================================================
-- BAÚ DA GUILDA
-- ============================================================================
local guildDefault = nil

local function ApplyGuildChest()
    local target = ConfigSlots("GuildChestSlots")
    if not target then return 0 end
    local changed = 0
    local objs = FindAllOf("PalGameSetting") or {}
    local cdo = StaticFindObject(GAME_SETTING_CDO)
    if valid(cdo) then objs[#objs + 1] = cdo end
    for _, gs in ipairs(objs) do
        pcall(function()
            if not (valid(gs) and HasIntProp(gs:GetClass(), "GuildChestSlotNum")) then return end
            local current = gs.GuildChestSlotNum
            guildDefault = guildDefault or current
            local t = math.max(target, guildDefault)
            if current ~= t then
                gs.GuildChestSlotNum = t
                changed = changed + 1
            end
        end)
    end
    return changed
end

-- ============================================================================
-- INVENTÁRIO PRINCIPAL
-- ============================================================================
local function ContainerIndex()
    local index = {}
    for _, c in ipairs(FindAllOf("PalItemContainer") or {}) do
        pcall(function()
            if not valid(c) then return end
            index[guidKey(c.ID.ID)] = { slots = arrayCount(c.ItemSlotArray) }
        end)
    end
    return index
end

-- { [campo ...ContainerId] = slots } do jogador local (single player).
local function InventorySlots()
    local result = {}
    local inv = FindFirstOf("PalPlayerInventoryData")
    if not valid(inv) then return nil end
    local infoProp
    for _, p in ipairs(AllProps(inv:GetClass())) do
        if p.name == "MyInventoryInfo" and p.type == "StructProperty" then infoProp = p end
    end
    local infoStruct = infoProp and InnerStruct(infoProp)
    if not infoStruct then return nil end
    local index = ContainerIndex()
    local info = inv.MyInventoryInfo
    for _, p in ipairs(AllProps(infoStruct)) do
        if p.name:find("ContainerId$") then
            local ok, k = pcall(function() return guidKey(info[p.name].ID) end)
            local rec = ok and index[k] or nil
            if rec then result[p.name] = rec.slots end
        end
    end
    return result
end

-- Teste v0.2.3: PalDebugSetting.DebugInventorySize (padrão 0). Se o jogo usa
-- esse valor ao montar o inventário, aplicar no menu principal (antes do save
-- carregar) aumenta o inventário principal sem editar o save.
local debugSizeApplied = false

local function ApplyDebugInventorySize()
    local target = ConfigSlots("InventorySlots")
    if not target or debugSizeApplied then return end
    local objs = FindAllOf("PalDebugSetting") or {}
    local cdo = StaticFindObject("/Script/Pal.Default__PalDebugSetting")
    if valid(cdo) then objs[#objs + 1] = cdo end
    local changed = 0
    for _, ds in ipairs(objs) do
        pcall(function()
            if not (valid(ds) and HasIntProp(ds:GetClass(), "DebugInventorySize")) then return end
            if ds.DebugInventorySize ~= target then
                ds.DebugInventorySize = target
                changed = changed + 1
            end
        end)
    end
    debugSizeApplied = true
    log(string.format("Teste do inventário: DebugInventorySize = %d em %d objeto(s).", target, changed))
end

-- Estado: nil = ainda não tentou; "waiting" = pediu, conferindo; "done"/"failed".
local inventoryState = nil
local inventoryAskedAt = 0

local function ApplyInventory()
    local target = ConfigSlots("InventorySlots")
    if not target or inventoryState == "done" or inventoryState == "failed" then return end
    local slots = InventorySlots()
    local common = slots and slots.CommonContainerId
    if not common then return end

    if common >= target then
        if inventoryState == "waiting" then log(string.format("Inventário principal: %d slots.", common)) end
        inventoryState = "done"
        return
    end
    if inventoryState == "waiting" then
        if os.time() - inventoryAskedAt < 5 then return end
        inventoryState = "failed"
        log(string.format("Inventário continua com %d slots - SetInventorySize não teve efeito " ..
            "(CheatManagerEnablerMod ativo?).", common))
        return
    end

    local cm = FindFirstOf("PalCheatManager")
    if not valid(cm) then
        inventoryState = "failed"
        log("PalCheatManager não encontrado - ative o CheatManagerEnablerMod para aumentar o inventário.")
        return
    end
    local ok, err = pcall(function() cm:SetInventorySize(target) end)
    if not ok then
        inventoryState = "failed"
        log("Erro chamando SetInventorySize: " .. tostring(err))
        return
    end
    inventoryState = "waiting"
    inventoryAskedAt = os.time()
    log(string.format("Inventário principal: pedido %d -> %d slots.", common, target))
end

-- ============================================================================
-- RELATÓRIO (Ctrl+F10)
-- ============================================================================
local function RunReport()
    local lines = {}
    local function out(msg) lines[#lines + 1] = msg end
    out(string.format("Bigger Storage v%s - relatório - %s", MOD_VERSION, os.date("%Y-%m-%d %H:%M:%S")))
    out(string.format("Componentes ajustados nesta sessão: %d template(s), %d baú(s) colocado(s).",
        stats.templates, stats.placed))
    out("")
    out("== Baús no mundo (slots reais) ==")
    local index = ContainerIndex()
    local groups, seen = {}, {}
    for _, className in ipairs(CHEST_CLASSES) do
        for _, model in ipairs(FindAllOf(className) or {}) do
            pcall(function()
                if not valid(model) then return end
                local key = fullName(model)
                if seen[key] then return end
                seen[key] = true
                local c = model:GetItemContainerModule():GetContainer()
                local rec = index[guidKey(c.ID.ID)]
                local g = fname(model:GetClass()) .. " | " .. (rec and rec.slots or "?") .. " slots"
                groups[g] = (groups[g] or 0) + 1
            end)
        end
    end
    for g, n in pairs(groups) do out(string.format("  %s (x%d)", g, n)) end
    out("")
    out("== Inventário do jogador ==")
    for name, n in pairs(InventorySlots() or {}) do out(string.format("  %s: %d slots", name, n)) end

    local dirs = modDir and { modDir } or CONFIG_DIRS
    for _, dir in ipairs(dirs) do
        local f = io.open(dir .. "report.txt", "w")
        if f then
            f:write(table.concat(lines, "\n"), "\n")
            f:close()
            log("Relatório gravado em " .. dir .. "report.txt")
            return
        end
    end
end

-- ============================================================================
-- DIAGNÓSTICO DA INTERFACE (Ctrl+F11, só leitura)
-- ============================================================================
-- Para o contador "usados/total": com a janela do baú ou do inventário aberta,
-- percorre a árvore de widgets da janela (a partir das listas de itens
-- visíveis) e grava tipo, nome e texto de cada widget. O Palworld não usa
-- TextBlock puro (v0.2.3 achou 0), então os textos são lidos de qualquer
-- widget com propriedade Text:TextProperty.
local UI_LISTS = { "WBP_PalItemScrollList_C", "WBP_PalPlayerInventoryScrollList_C" }
local UI_MAX_LINES = 2500
local UI_MAX_SAME = 3     -- filhos repetidos da mesma classe (ex.: slots) mostrados

local function PropOfType(obj, name, typeName)
    for _, p in ipairs(AllProps(obj:GetClass())) do
        if p.name == name then return p.type == typeName end
    end
    return false
end

-- Janela da lista: o último WBP na cadeia de outers ANTES da camada geral
-- (WBP_PalOverallUILayout_C, que contém todas as telas). Também devolve a
-- cadeia de classes, para o relatório.
local function TopWidget(widget)
    local top, o, guard, chain = widget, widget, 0, {}
    while guard < 16 do
        guard = guard + 1
        local ok, outer = pcall(function() return o:GetOuter() end)
        if not (ok and valid(outer)) then break end
        local cls = fname(outer:GetClass())
        if cls:find("OverallUILayout", 1, true) then break end
        if cls:sub(-2) == "_C" and cls:sub(1, 3) == "WBP" then
            top = outer
            chain[#chain + 1] = cls
        end
        o = outer
    end
    return top, table.concat(chain, " < ")
end

local function ContainerUsage(container)
    local total, used = arrayCount(container.ItemSlotArray), 0
    container.ItemSlotArray:ForEach(function(_, elem)
        -- Slot nulo/inválido: IsEmpty nele quebra o UE4SS em código nativo
        -- (pcall não segura) - conferir antes. Conta como vazio.
        local slot = elem:get()
        if not valid(slot) then return end
        local ok, empty = pcall(function() return slot:IsEmpty() end)
        if ok and not empty then used = used + 1 end
    end)
    return used, total
end

local function DumpTree(widget, depth, out, budget)
    if budget.lines >= UI_MAX_LINES or depth > 30 or not valid(widget) then return end
    local cls = fname(widget:GetClass())
    local extra = ""
    if PropOfType(widget, "Text", "TextProperty") then
        local ok, t = pcall(function() return widget.Text:ToString() end)
        extra = " \"" .. (ok and t or "?") .. "\""
    end
    local okV, vis = pcall(function() return widget:IsVisible() end)
    budget.lines = budget.lines + 1
    out(string.rep("  ", depth) .. cls .. " " .. fname(widget) .. extra .. ((okV and not vis) and " [oculto]" or ""))

    local children = {}
    if PropOfType(widget, "Slots", "ArrayProperty") then
        pcall(function()
            widget.Slots:ForEach(function(_, elem)
                local s = elem:get()
                if valid(s) and PropOfType(s, "Content", "ObjectProperty") and valid(s.Content) then
                    children[#children + 1] = s.Content
                end
            end)
        end)
    end
    if PropOfType(widget, "WidgetTree", "ObjectProperty") then
        pcall(function()
            local tree = widget.WidgetTree
            if valid(tree) and PropOfType(tree, "RootWidget", "ObjectProperty") and valid(tree.RootWidget) then
                children[#children + 1] = tree.RootWidget
            end
        end)
    end
    local perClass = {}
    for _, child in ipairs(children) do
        local c = fname(child:GetClass())
        perClass[c] = (perClass[c] or 0) + 1
        if perClass[c] <= UI_MAX_SAME then
            DumpTree(child, depth + 1, out, budget)
        elseif perClass[c] == UI_MAX_SAME + 1 then
            out(string.rep("  ", depth + 1) .. "... (mais " .. c .. ")")
        end
    end
end

local function RunUiDump()
    local lines = {}
    local function out(msg) lines[#lines + 1] = msg end
    out(string.format("Bigger Storage v%s - interface - %s", MOD_VERSION, os.date("%Y-%m-%d %H:%M:%S")))
    local tops, seenTop = {}, {}
    for _, className in ipairs(UI_LISTS) do
        for _, w in ipairs(FindAllOf(className) or {}) do
            pcall(function()
                if not valid(w) then return end
                local okV, visible = pcall(function() return w:IsVisible() end)
                if not (okV and visible) then return end
                local usage = "?"
                if PropOfType(w, "Target Container", "ObjectProperty") then
                    local c = w["Target Container"]
                    if valid(c) then
                        local u, t = ContainerUsage(c)
                        usage = u .. "/" .. t
                    end
                end
                local top, chain = TopWidget(w)
                out("")
                out(string.format("LISTA %s (%s) | slots %s | janela %s", fname(w), className, usage, fname(top:GetClass())))
                out("  cadeia: " .. chain)
                local key = fullName(top)
                if not seenTop[key] then
                    seenTop[key] = true
                    tops[#tops + 1] = top
                end
            end)
        end
    end
    local budget = { lines = 0 }
    for _, top in ipairs(tops) do
        out("")
        out("== Árvore de " .. fname(top:GetClass()) .. " ==")
        local ok, err = pcall(DumpTree, top, 0, out, budget)
        if not ok then out("Erro na árvore: " .. tostring(err)) end
    end

    local dirs = modDir and { modDir } or CONFIG_DIRS
    for _, dir in ipairs(dirs) do
        local f = io.open(dir .. "ui.txt", "w")
        if f then
            f:write(table.concat(lines, "\n"), "\n")
            f:close()
            log("Diagnóstico da interface gravado em " .. dir .. "ui.txt")
            return
        end
    end
end

-- ============================================================================
-- INIT
-- ============================================================================
LoadConfig()

if not Config.Enabled then
    log("v" .. MOD_VERSION .. " desativado no config.txt.")
    return
end

-- O aviso pode chegar fora do game thread (carregamento): só enfileira.
for _, className in ipairs(PARAM_CLASSES) do
    NotifyOnNewObject("/Script/Pal." .. className, function(obj)
        pending[#pending + 1] = { obj = obj, passes = 0 }
    end)
end

-- Fila dos componentes: barato (só os objetos recém-criados).
LoopAsync(500, function()
    if #pending > 0 then
        ExecuteInGameThread(function() pcall(ProcessPending) end)
    end
    return false
end)

-- Baú da guilda e inventário: uma vez por entrada no mundo, ~10 s depois que
-- o personagem aparece. FindAllOf percorre todos os objetos do jogo, então
-- nada aqui roda periodicamente com o jogador no mundo (v0.2.1 fazia a cada
-- 5 s e contribuía para engasgos).
local playerSeenAt = nil
local appliedThisWorld = false
LoopAsync(5000, function()
    ExecuteInGameThread(function()
        local player = FindFirstOf("PalPlayerCharacter")
        if not valid(player) then
            playerSeenAt, appliedThisWorld = nil, false
            pcall(ApplyDebugInventorySize)   -- antes do save carregar
            return
        end
        if appliedThisWorld then return end
        playerSeenAt = playerSeenAt or os.time()
        if os.time() - playerSeenAt < 10 then return end
        appliedThisWorld = true

        local okG, guild = pcall(ApplyGuildChest)
        if okG and guild > 0 then logV(string.format("Baú da guilda: %d objeto(s) ajustado(s).", guild)) end
        -- Inventário: PalCheatManager:SetInventorySize existe mas não faz nada
        -- na build de produção (testado na v0.2.1). Aqui só registra o
        -- resultado do teste com DebugInventorySize.
        pcall(function()
            local slots = InventorySlots()
            log(string.format("Inventário principal no mundo: %s slots.",
                tostring(slots and slots.CommonContainerId or "?")))
        end)
    end)
    return false
end)

RegisterKeyBind(Key.F10, { ModifierKey.CONTROL }, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(RunReport)
        if not ok then log("Erro no relatório: " .. tostring(err)) end
    end)
end)

-- ============================================================================
-- CONTADOR DE SLOTS NA INTERFACE (v0.3.0)
-- ============================================================================
-- Acrescenta " (usados/total)" ao título da janela:
--   * baú:       Text_TargetContainerName (em WBP_IngameMenu_Chest_C)
--   * inventário: Text_InventoryHead       (em WBP_Common_Inventory_C)
-- O número vem do "Target Container" (PalItemContainer) da lista de itens.
-- O FText é criado pelo próprio jogo (KismetTextLibrary:Conv_StringToText,
-- que só recebe uma string comum) - nunca FText montado no Lua, que já
-- corrompeu o heap no Better Fishing. As listas são guardadas quando o jogo
-- as cria (NotifyOnNewObject), sem FindAllOf periódico.
local LIST_CLASSES = {
    { path = "/Game/Pal/Blueprint/UI/Inventory/WBP_PalItemScrollList.WBP_PalItemScrollList_C",
      title = "Text_TargetContainerName" },
    { path = "/Game/Pal/Blueprint/UI/Inventory/WBP_PalPlayerInventoryScrollList.WBP_PalPlayerInventoryScrollList_C",
      title = "Text_InventoryHead" },
}
local SUFFIX_PATTERN = "%s%(%d+/%d+%)$"

local trackedLists = {}     -- [endereço] = { widget =, title = nome da propriedade do título }
local missingTitleLogged = {}
local textLibrary = nil

-- A lista do inventário é subclasse da lista do baú (o aviso/FindAllOf da
-- classe-mãe também a devolve): o título é escolhido pela classe real.
local TITLE_BY_CLASS = {}
for _, lc in ipairs(LIST_CLASSES) do TITLE_BY_CLASS[lc.path:match("%.([%w_]+)$")] = lc.title end

local function TrackList(widget)
    local ok, addr = pcall(function() return widget:GetAddress() end)
    if ok and addr then trackedLists[addr] = { widget = widget } end
end

local function HasObjectProp(obj, name)
    for _, p in ipairs(AllProps(obj:GetClass())) do
        if p.name == name then return p.type == "ObjectProperty" end
    end
    return false
end

-- Procura um widget pelo nome na árvore de um UserWidget (largura primeiro),
-- sem descer nas listas de itens (centenas de slots) e com limite de nós.
-- Necessário para títulos fixos como Text_InventoryHead, que não são
-- variáveis do blueprint (não existem como propriedade).
local function FindInTree(userWidget, wantedName)
    if not HasObjectProp(userWidget, "WidgetTree") then return nil end
    local tree = userWidget.WidgetTree
    if not (valid(tree) and HasObjectProp(tree, "RootWidget")) then return nil end
    local queue, head, visited = { tree.RootWidget }, 1, 0
    while head <= #queue and visited < 600 do
        local w = queue[head]
        head = head + 1
        visited = visited + 1
        if valid(w) then
            if fname(w) == wantedName then return w end
            local cls = fname(w:GetClass())
            if not cls:find("ScrollList", 1, true) then
                for _, p in ipairs(AllProps(w:GetClass())) do
                    if p.name == "Slots" and p.type == "ArrayProperty" then
                        pcall(function()
                            w.Slots:ForEach(function(_, elem)
                                local s = elem:get()
                                if valid(s) and HasObjectProp(s, "Content") and valid(s.Content) then
                                    queue[#queue + 1] = s.Content
                                end
                            end)
                        end)
                    end
                end
            end
        end
    end
    return nil
end

-- Sobe a partir da lista: em cada UserWidget dono, tenta a propriedade com o
-- nome do título (variável do blueprint) e depois a busca na árvore.
local function FindTitle(widget, titleProp)
    local o, guard = widget, 0
    while guard < 16 do
        guard = guard + 1
        local ok, outer = pcall(function() return o:GetOuter() end)
        if not (ok and valid(outer)) then return nil end
        if fname(outer:GetClass()):find("OverallUILayout", 1, true) then return nil end
        if HasObjectProp(outer, titleProp) then
            local okT, t = pcall(function() return outer[titleProp] end)
            if okT and valid(t) then return t end
        end
        if HasObjectProp(outer, "WidgetTree") then
            local okF, t = pcall(FindInTree, outer, titleProp)
            if okF and t then return t end
        end
        o = outer
    end
    return nil
end

local function UsageOf(list)
    local hasProp = false
    for _, p in ipairs(AllProps(list:GetClass())) do
        if p.name == "Target Container" and p.type == "ObjectProperty" then hasProp = true end
    end
    if not hasProp then return nil end
    local c = list["Target Container"]
    if not valid(c) then return nil end
    local total, used = arrayCount(c.ItemSlotArray), 0
    c.ItemSlotArray:ForEach(function(_, elem)
        -- Slot nulo/inválido: IsEmpty nele quebra o UE4SS em código nativo
        -- (pcall não segura) - conferir antes. Conta como vazio.
        local slot = elem:get()
        if not valid(slot) then return end
        local ok, empty = pcall(function() return slot:IsEmpty() end)
        if ok and not empty then used = used + 1 end
    end)
    return used, total
end

local function SetTitle(title, used, total)
    if not valid(textLibrary) then
        textLibrary = StaticFindObject("/Script/Engine.Default__KismetTextLibrary")
        if not valid(textLibrary) then return end
    end
    local okR, current = pcall(function() return title.Text:ToString() end)
    if not okR or type(current) ~= "string" then return end
    local base = current:gsub(SUFFIX_PATTERN, "")
    local wanted = string.format("%s (%d/%d)", base, used, total)
    if current == wanted then return end
    local text = textLibrary:Conv_StringToText(wanted)
    title:SetText(text)
end

local function UpdateCounters()
    for addr, t in pairs(trackedLists) do
        local ok, err = pcall(function()
            if not valid(t.widget) then trackedLists[addr] = nil; return end
            t.title = t.title or TITLE_BY_CLASS[fname(t.widget:GetClass())]
            if not t.title then trackedLists[addr] = nil; return end
            local okV, visible = pcall(function() return t.widget:IsVisible() end)
            if not (okV and visible) then return end
            local used, total = UsageOf(t.widget)
            if not used then return end
            if not valid(t.titleWidget) then
                if t.nextSearch and os.time() < t.nextSearch then return end
                t.titleWidget = FindTitle(t.widget, t.title)
                t.nextSearch = os.time() + 5
            end
            local title = t.titleWidget
            if not title then
                local key = t.title .. "|" .. fname(t.widget:GetOuter():GetClass())
                if not missingTitleLogged[key] then
                    missingTitleLogged[key] = true
                    log("Contador: título " .. t.title .. " não encontrado para " .. fullName(t.widget))
                end
                return
            end
            SetTitle(title, used, total)
        end)
        if not ok then logV("Erro no contador: " .. tostring(err)) end
    end
end

-- ============================================================================
-- MONITOR DE TRAVADAS (diagnóstico; HitchMonitor no config)
-- ============================================================================
-- Um callback por frame no game thread mede o intervalo entre frames com
-- os.clock() (tempo real no MSVC). Intervalos acima de HitchThresholdMs vão
-- para hitches.txt com o horário, para achar o ritmo (3 s, 15 s, 60 s...)
-- e com isso o mod ou sistema responsável.
if Config.HitchMonitor then
    local threshold = (tonumber(Config.HitchThresholdMs) or 120) / 1000
    local lastFrame, queued, sessionStart = nil, false, os.clock()
    local hitchFile = (modDir or CONFIG_DIRS[1]) .. "hitches.txt"
    pcall(function()
        local f = io.open(hitchFile, "w")
        if f then
            f:write(string.format("Bigger Storage v%s - travadas acima de %d ms - %s\n",
                MOD_VERSION, math.floor(threshold * 1000), os.date("%Y-%m-%d %H:%M:%S")))
            f:close()
        end
    end)
    LoopAsync(5, function()
        if queued then return false end
        queued = true
        ExecuteInGameThread(function()
            queued = false
            local now = os.clock()
            if lastFrame then
                local gap = now - lastFrame
                if gap >= threshold then
                    local player = FindFirstOf("PalPlayerCharacter")
                    local line = string.format("%s  +%7.1f s  %5d ms%s", os.date("%H:%M:%S"),
                        now - sessionStart, math.floor(gap * 1000), valid(player) and "" or "  (sem personagem)")
                    pcall(function()
                        local f = io.open(hitchFile, "a")
                        if f then f:write(line, "\n"); f:close() end
                    end)
                    logV("Travada: " .. line)
                end
            end
            lastFrame = now
        end)
        return false
    end)
    log(string.format("Monitor de travadas ativo (>= %d ms) -> %s", math.floor(threshold * 1000), hitchFile))
end

if Config.ShowSlotCounter then
    -- As classes de interface só existem depois que o jogo carrega a UI:
    -- registra o aviso de cada uma assim que aparecer (e pega as listas que já
    -- existirem com uma busca única, feita nesse momento).
    local registered = {}
    LoopAsync(2000, function()
        local pendingCount = 0
        for _, lc in ipairs(LIST_CLASSES) do
            if not registered[lc.path] then
                pendingCount = pendingCount + 1
                ExecuteInGameThread(function()
                    if registered[lc.path] then return end
                    if not valid(StaticFindObject(lc.path)) then return end
                    registered[lc.path] = true
                    local ok, err = pcall(NotifyOnNewObject, lc.path, function(w) TrackList(w) end)
                    if not ok then log("Contador: aviso não registrado para " .. lc.path .. ": " .. tostring(err)) end
                    local short = lc.path:match("%.([%w_]+)$")
                    for _, w in ipairs(FindAllOf(short) or {}) do TrackList(w) end
                    logV("Contador: acompanhando " .. short)
                end)
            end
        end
        return pendingCount == 0
    end)

    -- Listas criadas antes do registro: uma busca por entrada no mundo.
    -- v0.3.4: só no primeiro ClientRestart de cada mapa (crash de 13/10/2026
    -- num FindAllOf logo após renascer); depois os avisos de criação bastam.
    local scannedThisMap = false
    if type(RegisterLoadMapPreHook) == "function" then
        RegisterLoadMapPreHook(function() scannedThisMap = false end)
    end
    RegisterHook("/Script/Engine.PlayerController:ClientRestart", function()
        ExecuteWithDelay(10000, function()
            ExecuteInGameThread(function()
                if scannedThisMap then return end
                scannedThisMap = true
                for _, lc in ipairs(LIST_CLASSES) do
                    local short = lc.path:match("%.([%w_]+)$")
                    pcall(function()
                        for _, w in ipairs(FindAllOf(short) or {}) do TrackList(w) end
                    end)
                end
            end)
        end)
    end)

    -- Troca de mapa (ex.: voltar ao menu): os widgets são destruídos. Esquece
    -- as referências e pausa o contador por alguns segundos (v0.3.3: crash de
    -- 12/10/2026 ao voltar ao menu, Lua acessando objeto destruído).
    local pausedUntil = 0
    if type(RegisterLoadMapPreHook) == "function" then
        RegisterLoadMapPreHook(function()
            trackedLists = {}
            pending = {}
            pausedUntil = os.clock() + 5
        end)
    end

    local counterQueued = false
    LoopAsync(250, function()
        if os.clock() < pausedUntil then return false end
        if counterQueued or next(trackedLists) == nil then return false end
        counterQueued = true
        ExecuteInGameThread(function()
            pcall(UpdateCounters)
            counterQueued = false
        end)
        return false
    end)
end

RegisterKeyBind(Key.F11, { ModifierKey.CONTROL }, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(RunUiDump)
        if not ok then log("Erro no diagnóstico da interface: " .. tostring(err)) end
    end)
end)

local n = 0
for _ in pairs(Targets) do n = n + 1 end
log(string.format("v%s carregado: %d tipo(s) de baú configurado(s); inventário %s; guilda %s.",
    MOD_VERSION, n, tostring(ConfigSlots("InventorySlots") or "inalterado"),
    tostring(ConfigSlots("GuildChestSlots") or "inalterado")))
