-- ============================================================================
-- Better Fishing v1.4.0
-- ============================================================================
-- Hooks verificados (build 1.0 / 1.100.427; nomes conferidos no executável
-- do patch 2026-09-15):
--   /Script/Pal.PalFishingComponent:OnChangeRodState      (WaitHit = 6)
--   /Script/Pal.PalFishingComponent:OnPressedFishingButton
--   /Script/Pal.PalNetworkFishingComponent:StartCatchBattle_ToServer
--   /Script/Pal.PalNetworkFishingComponent:SuccessCatchBattle_ToServer
--
-- Ownership em Palworld:
--   PalFishingComponent        → owned by Pawn (BP_Player_Female_C)
--   PalNetworkFishingComponent → owned by PalNetworkTransmitter
--
-- NOTA sobre multiplicadores:
--   GetPropertyValue/SetPropertyValue com nomes incorretos também causam
--   ACCESS_VIOLATION no C++, igual ao acesso direto obj[prop], mesmo dentro
--   de pcall. Por isso toda propriedade é conferida pela reflexão da classe
--   (ForEachProperty) antes de qualquer leitura/escrita.
--
--   Os valores são sempre calculados a partir do ORIGINAL guardado na
--   primeira leitura (original × multiplicador). Reaplicar não acumula —
--   multiplicar o valor atual a cada carga quebrava os pontos de pesca no
--   QuickCatch.
--
--   Implementados (patch 2026-09-15, nomes vindos do executável):
--     BiteTimeMultiplier           → CatchBattleParameter.SinkWaitMinTime/MaxTime
--     FishingSpotRespawnMultiplier → FishShadowRespawnTime (se acessível)
--   Pendentes (aguardando nomes do diagnóstico no log):
--     EscapeChanceMultiplier, FishResistanceMultiplier, BaitConsumptionChance
-- ============================================================================

local UEHelpers = require("UEHelpers")

local LOG_PREFIX  = "[BetterFishing]"
local MOD_VERSION = "1.5.1"

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
-- CONFIG (valores padrão)
-- ============================================================================
Config = {
    Enabled                      = true,
    InstantCapture               = false,
    AutoStrike                   = true,
    CatchSuccessDelayMs          = 200,
    -- Multiplicadores: lidos, logados, mas aguardam ObjectDump para aplicação
    BiteTimeMultiplier           = 1.0,
    EscapeChanceMultiplier       = 1.0,
    FishResistanceMultiplier     = 1.0,
    FishingSpotRespawnMultiplier = 1.0,
    FishingSpotRespawnSeconds = 0,   -- > 0: tempo fixo (s) para qualquer spot; ignora o multiplicador
    BaitConsumptionChance        = 1.0,
    -- Modo Hardcore: desativa InstantCapture + AutoStrike
    HardcoreMode                 = false,
    NotifyChatEnabled            = true,
    VerboseLogging               = false,
}

-- ============================================================================
-- CONFIG LOADING
-- ============================================================================
local function ParseValue(v)
    if v == "0" or v:lower() == "false" then return false end
    if v == "1" or v:lower() == "true"  then return true  end
    local n = tonumber(v)
    if n ~= nil then return n end
    return v
end

local CONFIG_PATHS = {
    "Mods\\BetterFishing\\config.txt",
    "Mods/BetterFishing/config.txt",
    "ue4ss\\Mods\\BetterFishing\\config.txt",
    "ue4ss/Mods/BetterFishing/config.txt",
}

local function LoadConfig()
    local f, usedPath = nil, nil
    for _, p in ipairs(CONFIG_PATHS) do
        f = io.open(p, "r")
        if f then usedPath = p; break end
    end
    if not f then
        log("config.txt não encontrado — usando valores padrão.")
        return
    end
    log("config.txt carregado: " .. tostring(usedPath))
    for line in f:lines() do
        line = line:gsub("[;#].*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" then
            local k, v = line:match("^([%w_]+)%s*=%s*(.+)$")
            if k and v then
                Config[k] = ParseValue(v:gsub("^%s+", ""):gsub("%s+$", ""))
            end
        end
    end
    f:close()

    if type(Config.CatchSuccessDelayMs) == "boolean" then
        Config.CatchSuccessDelayMs = Config.CatchSuccessDelayMs and 1 or 0
    end
    if type(Config.CatchSuccessDelayMs) == "number" then
        Config.CatchSuccessDelayMs = math.max(0, math.min(10000, Config.CatchSuccessDelayMs))
    end

    if Config.HardcoreMode then
        Config.InstantCapture = false
        Config.AutoStrike     = false
        log("HardcoreMode ativo — InstantCapture e AutoStrike desativados.")
    end
end

LoadConfig()

-- Avisa sobre multiplicadores ainda não implementados
local function WarnPendingMultipliers()
    local pending = {}
    local checks = {
        { "EscapeChanceMultiplier",       Config.EscapeChanceMultiplier       },
        { "FishResistanceMultiplier",     Config.FishResistanceMultiplier     },
        { "BaitConsumptionChance",        Config.BaitConsumptionChance        },
    }
    for _, entry in ipairs(checks) do
        local name, val = entry[1], entry[2]
        if type(val) == "number" and val ~= 1.0 then
            table.insert(pending, name .. " = " .. tostring(val))
        end
    end
    if #pending > 0 then
        log("Multiplicadores configurados mas ainda não implementados:")
        for _, line in ipairs(pending) do log("  " .. line) end
        log("  → Veja as linhas 'Diagnóstico' no log para os nomes das propriedades.")
    end
end

-- ============================================================================
-- REFLEXÃO — confere propriedades antes de acessar (evita ACCESS_VIOLATION)
-- ============================================================================
-- Classes que podem carregar parâmetros de pesca.
local TUNING_CLASSES = {
    -- v1.5.0: FishShadowRespawnTime fica em APalFishingSpotArea (área de cada spot).
    "PalFishingSpotArea",
    "PalFishingSystem",
    "BP_PalFishingSystem_C",
    "PalFishingComponent",
    "BP_PalFishingComponent_C",
}

-- Palavras usadas no diagnóstico para listar propriedades de pesca.
local DIAG_PATTERN = { "Fish", "Sink", "Catch", "Difficulty", "Respawn",
                       "Search", "Bait", "Escape", "Pick" }

-- Cache por classe: { [nomePropriedade] = FProperty }
local classPropsCache = {}

local function MatchesDiag(name)
    for _, word in ipairs(DIAG_PATTERN) do
        if name:find(word) then return true end
    end
    return false
end

-- Lista as propriedades de uma UStruct (classe ou struct) incluindo superclasses.
local function CollectProperties(struct)
    local props = {}
    pcall(function()
        local current = struct
        while current and current:IsValid() do
            current:ForEachProperty(function(prop)
                props[prop:GetFName():ToString()] = prop
            end)
            current = current:GetSuperStruct()
        end
    end)
    return props
end

-- Propriedades da classe de obj; na primeira vez grava o diagnóstico no log.
local function GetClassProperties(obj, className)
    if classPropsCache[className] then return classPropsCache[className] end
    local props = CollectProperties(obj:GetClass())
    classPropsCache[className] = props

    local names = {}
    for name, prop in pairs(props) do
        if MatchesDiag(name) then
            local entry = name
            -- Para structs, lista também os campos (ex.: CatchBattleParameter).
            pcall(function()
                local inner = prop:GetStruct()
                if inner and inner:IsValid() then
                    local fields = {}
                    for fieldName in pairs(CollectProperties(inner)) do
                        table.insert(fields, fieldName)
                    end
                    table.sort(fields)
                    entry = entry .. "{" .. table.concat(fields, ",") .. "}"
                end
            end)
            table.insert(names, entry)
        end
    end
    table.sort(names)
    log("Diagnóstico " .. className .. ": " ..
        (#names > 0 and table.concat(names, ", ") or "nenhuma propriedade de pesca"))
    return props
end

-- Nomes dos campos de uma StructProperty (ou nil se não for struct).
local structFieldsCache = {}

local function GetStructFields(className, propName, prop)
    local key = className .. "." .. propName
    if structFieldsCache[key] ~= nil then return structFieldsCache[key] or nil end
    local fields = false
    pcall(function()
        local inner = prop:GetStruct()
        if inner and inner:IsValid() then fields = CollectProperties(inner) end
    end)
    structFieldsCache[key] = fields
    return fields or nil
end

-- ============================================================================
-- TUNING — sempre original × multiplicador (idempotente)
-- ============================================================================
-- originals["<objeto>|<caminho>"] = valor lido na primeira vez
local originals = {}
local tuningReported = {}

-- readBack: valor relido após a escrita, para confirmar que ela teve efeito.
local function ReportTuning(key, before, after, readBack)
    local applied = type(readBack) == "number" and math.abs(readBack - after) < 0.0001
    local suffix = applied and "" or (" (escrita não teve efeito, lido " .. tostring(readBack) .. ")")
    if tuningReported[key] then
        logV(string.format("%s: %.3f -> %.3f%s", key, before, after, suffix))
        return
    end
    tuningReported[key] = true
    log(string.format("%s: %.3f -> %.3f%s", key, before, after, suffix))
end

-- Aplica multiplicador a um float no topo do objeto.
local function TuneTopLevel(obj, objKey, className, props, propName, mult)
    if not props[propName] then return end
    local key = objKey .. "|" .. propName
    local current = obj[propName]
    if type(current) ~= "number" then return end
    if originals[key] == nil then originals[key] = current end
    local target = originals[key] * mult
    if current ~= target then
        obj[propName] = target
        ReportTuning(className .. "." .. propName, originals[key], target, obj[propName])
    end
end

-- Aplica multiplicador a campos float de uma struct do objeto.
local function TuneStructFields(obj, objKey, className, props, structName, fieldNames, mult)
    local prop = props[structName]
    if not prop then return end
    local fields = GetStructFields(className, structName, prop)
    if not fields then return end
    local struct = obj[structName]
    if not struct then return end
    for _, field in ipairs(fieldNames) do
        if fields[field] then
            local key = objKey .. "|" .. structName .. "." .. field
            local current = struct[field]
            if type(current) == "number" then
                if originals[key] == nil then originals[key] = current end
                local target = originals[key] * mult
                if current ~= target then
                    struct[field] = target
                    -- Relê pelo objeto: confirma que a struct é referência, não cópia.
                    ReportTuning(className .. "." .. structName .. "." .. field,
                        originals[key], target, obj[structName][field])
                end
            end
        end
    end
end

local function TuneObject(obj, className)
    if not (obj and obj:IsValid()) then return end
    local props = GetClassProperties(obj, className)
    local objKey = obj:GetFullName()

    local bite = tonumber(Config.BiteTimeMultiplier)
    if bite and bite ~= 1.0 then
        TuneStructFields(obj, objKey, className, props, "CatchBattleParameter",
            { "SinkWaitMinTime", "SinkWaitMaxTime" }, bite)
    end

    -- v1.5.1: tempo fixo em segundos (vale para qualquer tipo de spot).
    local fixedSeconds = tonumber(Config.FishingSpotRespawnSeconds)
    if fixedSeconds and fixedSeconds > 0 and props["FishShadowRespawnTime"] then
        local key = objKey .. "|FishShadowRespawnTime"
        local current = obj.FishShadowRespawnTime
        if type(current) == "number" then
            if originals[key] == nil then originals[key] = current end
            if current ~= fixedSeconds then
                obj.FishShadowRespawnTime = fixedSeconds
                ReportTuning(className .. ".FishShadowRespawnTime", originals[key], fixedSeconds, obj.FishShadowRespawnTime)
            end
        end
    else
        local respawn = tonumber(Config.FishingSpotRespawnMultiplier)
        if respawn and respawn ~= 1.0 then
            TuneTopLevel(obj, objKey, className, props, "FishShadowRespawnTime", respawn)
        end
    end
end

-- Rastreamento (v1.4.0): FindAllOf percorre todos os objetos do jogo
-- (~200 ms neste save); 4 buscas a cada 15 s causavam travadas periódicas.
-- Agora NotifyOnNewObject guarda os objetos das classes C++ quando o jogo os
-- cria, uma busca completa roda só 10 s após ClientRestart (pega também as
-- classes BP_*) e o loop periódico só reaplica nos objetos guardados.
local NOTIFY_CLASSES = { "PalFishingSystem", "PalFishingComponent", "PalFishingSpotArea" }
local tracked = {}   -- [endereço] = { obj =, className = }

local function Track(obj, className)
    local ok, addr = pcall(function() return obj:GetAddress() end)
    if ok and addr then tracked[addr] = { obj = obj, className = className } end
end

local function FullTuningScan()
    for _, className in ipairs(TUNING_CLASSES) do
        local objects = nil
        pcall(function() objects = FindAllOf(className) end)
        for _, obj in ipairs(objects or {}) do Track(obj, className) end
    end
end

local function ApplyTuning()
    for addr, t in pairs(tracked) do
        local okV, isValid = pcall(function() return t.obj:IsValid() end)
        if okV and isValid then
            local ok, err = pcall(TuneObject, t.obj, t.className)
            if not ok then log("Erro no tuning de " .. t.className .. ": " .. tostring(err)) end
        else
            tracked[addr] = nil
        end
    end
end

-- Multiplicadores fora de [0.05, 10] são limitados para evitar valores absurdos.
local function ClampMultiplier(name)
    local v = Config[name]
    if type(v) == "boolean" then v = v and 1 or 0 end
    v = tonumber(v)
    if not v then Config[name] = 1.0; return end
    local clamped = math.max(0.05, math.min(10.0, v))
    if clamped ~= v then
        log(string.format("%s %s fora de 0.05-10 - usando %s.", name, tostring(v), tostring(clamped)))
    end
    Config[name] = clamped
end

ClampMultiplier("BiteTimeMultiplier")
ClampMultiplier("FishingSpotRespawnMultiplier")

-- ============================================================================
-- ESTADO WaitHit — resolvido pelo enum em runtime (fallback 6)
-- ============================================================================
local WAIT_HIT_STATE = 6

local function ResolveWaitHitState()
    pcall(function()
        local enum = StaticFindObject("/Script/Pal.EPalFishingRodState")
        if not (enum and enum:IsValid()) then return end
        enum:ForEachName(function(name, value)
            local n = name:ToString()
            if n == "WaitHit" or n:match("::WaitHit$") then
                if value ~= WAIT_HIT_STATE then
                    log("EPalFishingRodState::WaitHit = " .. tostring(value) .. " (era 6).")
                end
                WAIT_HIT_STATE = value
            end
        end)
    end)
end

-- ============================================================================
-- NOTIFY
-- ============================================================================
-- v1.3.1: o aviso no chat (SendLog_ToClient com FText e TArray criados pelo
-- Lua) foi removido. A chamada falhava a cada captura e é suspeita do crash
-- "FMallocBinned2 Attempt to realloc an unrecognized block" (06/10/2026).
-- NotifyChatEnabled continua sendo lido, mas a mensagem vai só para o log.
local function Notify(msg)
    log(msg)
end

-- ============================================================================
-- OWNERSHIP GUARD — apenas para PalFishingComponent (owned by Pawn)
-- PalNetworkFishingComponent é owned by PalNetworkTransmitter, não usar aqui.
-- ============================================================================
local function IsLocalFishingComponent(comp)
    local ok, result = pcall(function()
        if not (comp and comp:IsValid()) then return true end
        local owner = comp:GetOwner()
        if not (owner and owner:IsValid()) then return true end
        local pc = UEHelpers.GetPlayerController()
        if not (pc and pc:IsValid()) then return true end
        local localPawn = pc.Pawn
        if not (localPawn and localPawn:IsValid()) then return true end
        local ownerName = owner:GetFullName()
        if ownerName == localPawn:GetFullName() then
            logV("OwnershipCheck — match: true")
            return true
        end

        -- Montado em um Pal, pc.Pawn deixa de ser o personagem do jogador.
        -- Com um único PalPlayerCharacter no mundo (single-player), o dono
        -- sendo esse personagem basta para considerar a pesca local.
        local players = {}
        for _, p in ipairs(FindAllOf("PalPlayerCharacter") or {}) do
            if p:IsValid() and not p:GetFullName():find("Default__") then
                table.insert(players, p)
            end
        end
        if #players == 1 and players[1]:GetFullName() == ownerName then
            logV("OwnershipCheck — single-player (montado?): true")
            return true
        end

        log("OwnershipCheck — dono=" .. ownerName .. " pawn=" .. localPawn:GetFullName()
            .. " jogadores=" .. #players)
        return false
    end)
    if not ok then return true end
    return result
end

-- ============================================================================
-- FLAG DE PESCA LOCAL
-- Definida pelo OnChangeRodState (PalFishingComponent, owner = Pawn confirmado).
-- Consumida pelo StartCatchBattle (PalNetworkFishingComponent, owner = PalNetworkTransmitter).
-- ============================================================================
local localFishingPending = false
local battleToken         = 0     -- invalida esperas de batalhas anteriores

-- ============================================================================
-- SUCESSO SEGURO
-- SuccessCatchBattle_ToServer roda via ExecuteInGameThread: ExecuteWithDelay
-- executa fora da thread do jogo, e chamar o RPC dali (v1.3.0 e anteriores)
-- é suspeito do crash "FMallocBinned2 Attempt to realloc an unrecognized
-- block" (06/10/2026).
--
-- O sucesso é enviado ao servidor logo após CatchSuccessDelayMs. A v1.3.1
-- esperava LoadedCutsceneInfo antes disso, mas a cutscene só carrega DEPOIS
-- que o servidor recebe o sucesso — a espera nunca terminava.
-- ============================================================================
local function ForceSuccess(netComp, token)
    ExecuteWithDelay(Config.CatchSuccessDelayMs, function()
        ExecuteInGameThread(function()
            local ok, err = pcall(function()
                if token ~= battleToken then return end
                if not (netComp and netComp:IsValid()) then
                    log("SuccessCatchBattle: comp inválido após delay.")
                    return
                end
                netComp:SuccessCatchBattle_ToServer()
                Notify("Captura instantânea!")
                log("SuccessCatchBattle_ToServer chamado.")
            end)
            if not ok then log("Erro ao forçar sucesso: " .. tostring(err)) end
        end)
    end)
end

-- ============================================================================
-- HOOKS PRINCIPAIS
-- ============================================================================
local hooksApplied = false

local function ApplyHooks()
    if hooksApplied then return true end
    ResolveWaitHitState()

    -- Hook 1: PalFishingComponent — mudança de estado da cana
    --   Acessa o componente APENAS no estado WaitHit (6), igual ao v1.1.0.
    --   Acessar o componente em outros estados pode causar crash durante
    --   transições onde ele está em estado parcialmente válido.
    RegisterHook("/Script/Pal.PalFishingComponent:OnChangeRodState", function(Context, StateArg)
        local ok, err = pcall(function()
            if not Config.Enabled then return end
            local state = StateArg:get()
            logV("OnChangeRodState state=" .. tostring(state))

            if state ~= WAIT_HIT_STATE then return end

            log("Peixe mordeu (WaitHit).")
            local comp = Context:get()

            if not IsLocalFishingComponent(comp) then
                log("Pesca não é local (multi-jogador remoto), ignorando.")
                return
            end

            localFishingPending = true

            if Config.InstantCapture and Config.AutoStrike then
                if comp and comp:IsValid() then
                    comp:OnPressedFishingButton()
                    log("AutoStrike disparado.")
                end
            end
        end)
        if not ok then log("Erro em OnChangeRodState: " .. tostring(err)) end
    end)

    -- Hook 2: PalNetworkFishingComponent — início do mini-jogo
    --   Usa localFishingPending (definida pelo Hook 1) em vez de checar ownership,
    --   pois PalNetworkFishingComponent é owned by PalNetworkTransmitter, não pelo Pawn.
    RegisterHook("/Script/Pal.PalNetworkFishingComponent:StartCatchBattle_ToServer", function(Context)
        local ok, err = pcall(function()
            logV("StartCatchBattle hook disparado.")
            if not Config.Enabled or not Config.InstantCapture then return end
            if not localFishingPending then
                logV("StartCatchBattle: não é pesca local, ignorando.")
                return
            end
            localFishingPending = false

            local comp = Context:get()
            if not (comp and comp:IsValid()) then
                log("StartCatchBattle: comp inválido.")
                return
            end

            battleToken = battleToken + 1
            log("Agendando SuccessCatchBattle em " .. tostring(Config.CatchSuccessDelayMs) .. "ms.")
            ForceSuccess(comp, battleToken)
        end)
        if not ok then log("Erro em StartCatchBattle_ToServer: " .. tostring(err)) end
    end)

    hooksApplied = true
    log("Hooks registrados (v" .. MOD_VERSION .. ").")
    WarnPendingMultipliers()
    return true
end

-- ============================================================================
-- RETRY HOOKS
-- ============================================================================
LoopAsync(3000, function()
    local ok, err = pcall(ApplyHooks)
    if not ok then
        log("Tentativa de hook falhou: " .. tostring(err))
        return false
    end
    return hooksApplied
end)

-- ============================================================================
-- TUNING PERIÓDICO — pega sistemas/componentes criados depois do load
-- ============================================================================
if Config.Enabled then
    for _, className in ipairs(NOTIFY_CLASSES) do
        NotifyOnNewObject("/Script/Pal." .. className, function(obj) Track(obj, className) end)
    end
    -- v1.4.2: busca completa (FindAllOf) só no primeiro ClientRestart de cada
    -- mapa (crash de 13/10/2026 num FindAllOf logo após renascer).
    local scannedThisMap = false
    if type(RegisterLoadMapPreHook) == "function" then
        RegisterLoadMapPreHook(function() scannedThisMap = false end)
    end
    RegisterHook("/Script/Engine.PlayerController:ClientRestart", function()
        ExecuteWithDelay(10000, function()
            ExecuteInGameThread(function()
                if not scannedThisMap then
                    scannedThisMap = true
                    pcall(FullTuningScan)
                end
                local ok, err = pcall(ApplyTuning)
                if not ok then log("Erro no tuning: " .. tostring(err)) end
            end)
        end)
    end)

    LoopAsync(15000, function()
        ExecuteInGameThread(function()
            local ok, err = pcall(ApplyTuning)
            if not ok then log("Erro no tuning: " .. tostring(err)) end
        end)
        return false
    end)
end

log("Carregado (v" .. MOD_VERSION .. ").")

-- Troca de mapa (ex.: voltar ao menu): os objetos do mundo são destruídos.
-- Esquece as referências guardadas para não acessar objetos mortos
-- (crash de 12/10/2026 ao voltar ao menu).
if type(RegisterLoadMapPreHook) == "function" then
    RegisterLoadMapPreHook(function()
        tracked = {}
    end)
end
