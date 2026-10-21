-- ============================================================================
-- Bigger Pal Box v0.1.0
-- ============================================================================
-- Aumenta o número de páginas da caixa de Pals (PalBoxPages no config.txt;
-- padrão 64 = o dobro de 32 páginas x 30 Pals = 1920 Pals).
--
-- O que se sabe (patch 2026-09-15):
--   * PalGameSetting.PalBoxSlotNumInPage = 30 (Pals por página) e
--     PalBoxPageNum (páginas) - configurações usadas pela tela e, ao criar a
--     caixa, pelo tamanho do container.
--   * A caixa do jogador é um container de Pals (CharacterContainerSaveData,
--     PalStorageContainerId) com SlotNum = 960 gravado no save.
--
-- v0.1.0 (teste): muda PalBoxPageNum no PalGameSetting (instâncias + CDO do
-- BP) antes do save carregar, e ao entrar no mundo registra no log as páginas
-- e o tamanho real da caixa (se o container continuar com 960, será preciso
-- editar o save - ferramenta em Pal-Bigger-Storage\tools\patch_inventory.py).
--
-- Segurança: só lê/escreve propriedades que a reflexão confirmou existirem.
-- ============================================================================

local LOG_PREFIX  = "[BiggerPalBox]"
local MOD_VERSION = "0.1.1"

local GAME_SETTING_CDO = "/Game/Pal/Blueprint/System/BP_PalGameSetting.Default__BP_PalGameSetting_C"
local CONFIG_PATHS = { "Mods\\BiggerPalBox\\config.txt", "ue4ss\\Mods\\BiggerPalBox\\config.txt" }

local function log(msg)
    print(LOG_PREFIX .. " " .. tostring(msg) .. "\n")
end

Config = { Enabled = true, PalBoxPages = 64 }

local function LoadConfig()
    for _, p in ipairs(CONFIG_PATHS) do
        local f = io.open(p, "r")
        if f then
            for line in f:lines() do
                line = line:gsub("[;#].*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
                local key, value = line:match("^([%w_]+)%s*=%s*(.-)$")
                if key and Config[key] ~= nil then
                    if value:lower() == "false" then Config[key] = false
                    elseif value:lower() == "true" then Config[key] = true
                    else Config[key] = tonumber(value) or value end
                end
            end
            f:close()
            return
        end
    end
end

local function valid(obj)
    if not obj then return false end
    local ok, v = pcall(function() return obj:IsValid() end)
    return ok and v
end

local function IntProps(obj, pattern)
    local found = {}
    pcall(function()
        local s, guard = obj:GetClass(), 0
        while valid(s) and guard < 32 do
            guard = guard + 1
            s:ForEachProperty(function(prop)
                local n = prop:GetFName():ToString()
                if prop:GetClass():GetFName():ToString() == "IntProperty" and n:find(pattern, 1, true) then
                    found[n] = true
                end
            end)
            s = s:GetSuperStruct()
        end
    end)
    return found
end

local applied, defaultPages = false, nil

local function ApplyPages()
    local objs = FindAllOf("PalGameSetting") or {}
    local cdo = StaticFindObject(GAME_SETTING_CDO)
    if valid(cdo) then objs[#objs + 1] = cdo end
    local changed = 0
    for _, gs in ipairs(objs) do
        pcall(function()
            if not valid(gs) then return end
            local props = IntProps(gs, "PalBox")
            if not props["PalBoxPageNum"] then
                if not applied then
                    local names = {}
                    for n in pairs(props) do names[#names + 1] = n end
                    log("PalBoxPageNum não existe nesta versão; campos PalBox: " .. table.concat(names, ", "))
                end
                return
            end
            defaultPages = defaultPages or gs.PalBoxPageNum
            local target = math.max(math.floor(Config.PalBoxPages), defaultPages)
            if gs.PalBoxPageNum ~= target then
                gs.PalBoxPageNum = target
                changed = changed + 1
            end
        end)
    end
    if changed > 0 then
        log(string.format("PalBoxPageNum: %s -> %d (%d objeto(s)).", tostring(defaultPages), math.floor(Config.PalBoxPages), changed))
    end
    applied = true
end

-- Ao entrar no mundo: confirma páginas e tamanho real da caixa.
local function Report()
    pcall(ApplyPages)
    local gs = FindFirstOf("PalGameSetting")
    local pages, perPage = "?", "?"
    if valid(gs) then
        local props = IntProps(gs, "PalBox")
        if props["PalBoxPageNum"] then pages = gs.PalBoxPageNum end
        if props["PalBoxSlotNumInPage"] then perPage = gs.PalBoxSlotNumInPage end
    end
    local sizes = {}
    for _, c in ipairs(FindAllOf("PalIndividualCharacterContainer") or {}) do
        pcall(function()
            local n = c:Num()
            if n and n >= 100 then sizes[#sizes + 1] = tostring(n) end
        end)
    end
    log(string.format("Caixa: %s página(s) x %s Pals; containers grandes de Pals: [%s].",
        tostring(pages), tostring(perPage), table.concat(sizes, ", ")))
end

LoadConfig()
if not Config.Enabled then
    log("v" .. MOD_VERSION .. " desativado no config.txt.")
    return
end

-- Antes do save carregar (menu principal) e de novo ao entrar no mundo.
local tries = 0
LoopAsync(3000, function()
    tries = tries + 1
    ExecuteInGameThread(function() pcall(ApplyPages) end)
    return applied or tries > 40
end)

-- v0.1.1: o relatório (busca de containers) roda só no primeiro
-- ClientRestart de cada mapa (crash de 13/10/2026 num FindAllOf logo após
-- renascer).
local reportedThisMap = false
if type(RegisterLoadMapPreHook) == "function" then
    RegisterLoadMapPreHook(function() reportedThisMap = false end)
end

RegisterHook("/Script/Engine.PlayerController:ClientRestart", function()
    ExecuteWithDelay(10000, function()
        ExecuteInGameThread(function()
            if reportedThisMap then return end
            reportedThisMap = true
            local ok, err = pcall(Report)
            if not ok then log("Erro no relatório: " .. tostring(err)) end
        end)
    end)
end)

log(string.format("v%s carregado: caixa de Pals com %d páginas.", MOD_VERSION, math.floor(Config.PalBoxPages)))
