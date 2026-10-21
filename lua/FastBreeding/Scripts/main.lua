-- ============================================================================
-- Fast Breeding v1.2.0
-- ============================================================================
-- Define o tempo da fazenda de acasalamento para 1 ovo a cada BreedMinutes
-- (entre 0,5 e 60 minutos; vanilla = 5 minutos).
-- Altera apenas a propriedade BreedRequiredRealTime; receitas e consumo de
-- bolo (1 bolo por ovo) ficam intactos.
--
-- Verificado em jogo (patch 2026-09-15): BreedRequiredRealTime (segundos,
-- vanilla 300) existe só em PalMapObjectBreedFarmModel, um por fazenda.
-- PalGameSetting não tem essa propriedade.
--
-- Segurança: acessar uma propriedade inexistente causa ACCESS_VIOLATION no
-- C++, mesmo dentro de pcall. Por isso a existência da propriedade é
-- verificada pela reflexão da classe ANTES de qualquer leitura/escrita.
-- O mod nunca chama funções do jogo, só altera esse valor.
-- ============================================================================

local LOG_PREFIX    = "[FastBreeding]"
local MOD_VERSION   = "1.2.2"
local PROPERTY_NAME = "BreedRequiredRealTime"

local MIN_MINUTES = 0.5
local MAX_MINUTES = 60

-- Modelo de cada fazenda de acasalamento construída.
local TARGET_CLASSES = {
    "PalMapObjectBreedFarmModel",
}

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
    Enabled        = true,
    BreedMinutes   = 1.0,
    ScanIntervalMs = 15000,
    VerboseLogging = false,
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
    "Mods\\FastBreeding\\config.txt",
    "Mods/FastBreeding/config.txt",
    "ue4ss\\Mods\\FastBreeding\\config.txt",
    "ue4ss/Mods/FastBreeding/config.txt",
}

local function LoadConfig()
    local f, usedPath = nil, nil
    for _, p in ipairs(CONFIG_PATHS) do
        f = io.open(p, "r")
        if f then usedPath = p; break end
    end
    if not f then
        log("config.txt não encontrado - usando valores padrão.")
        return
    end
    log("config.txt carregado: " .. tostring(usedPath))
    for line in f:lines() do
        line = line:gsub("[;#].*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" then
            local key, value = line:match("^([%w_]+)%s*=%s*(.-)$")
            if key and Config[key] ~= nil then
                Config[key] = ParseValue(value)
            end
        end
    end
    f:close()
end

-- Converte BreedMinutes em segundos, limitando ao intervalo permitido.
local function ResolveBreedSeconds()
    -- ParseValue converte "1"/"0" em true/false; aceita também vírgula decimal ("0,5").
    local raw = Config.BreedMinutes
    if raw == true then raw = 1 elseif raw == false then raw = 0 end
    local minutes = tonumber((tostring(raw):gsub(",", ".")))
    if not minutes then
        log(string.format("BreedMinutes inválido (%s) - usando 1 minuto.",
            tostring(Config.BreedMinutes)))
        minutes = 1.0
    elseif minutes < MIN_MINUTES or minutes > MAX_MINUTES then
        local clamped = math.max(MIN_MINUTES, math.min(MAX_MINUTES, minutes))
        log(string.format("BreedMinutes %s fora do intervalo %.1f-%d - usando %s.",
            tostring(minutes), MIN_MINUTES, MAX_MINUTES, tostring(clamped)))
        minutes = clamped
    end
    return minutes * 60.0
end

local breedSeconds = 60.0

-- ============================================================================
-- REFLEXÃO
-- ============================================================================
-- Cache por classe: true/false se a classe (ou superclasse) tem a propriedade.
local classHasProperty = {}

local function ClassHasProperty(obj, className)
    if classHasProperty[className] ~= nil then
        return classHasProperty[className]
    end
    local found = false
    local breedProps = {}
    pcall(function()
        local class = obj:GetClass()
        while class and class:IsValid() do
            class:ForEachProperty(function(prop)
                local name = prop:GetFName():ToString()
                if name == PROPERTY_NAME then found = true end
                if name:find("Breed") then table.insert(breedProps, name) end
            end)
            class = class:GetSuperStruct()
        end
    end)
    classHasProperty[className] = found
    log(string.format("%s: %s %s (propriedades Breed: %s)",
        className, PROPERTY_NAME, found and "encontrada" or "ausente",
        #breedProps > 0 and table.concat(breedProps, ", ") or "nenhuma"))
    return found
end

-- ============================================================================
-- APLICAÇÃO
-- ============================================================================
local reported = {}

local function ApplyTo(obj, className)
    if not obj or not obj:IsValid() then return end
    if not ClassHasProperty(obj, className) then return end

    local current = obj[PROPERTY_NAME]
    if type(current) ~= "number" or current == breedSeconds then return end

    obj[PROPERTY_NAME] = breedSeconds
    if not reported[className] then
        reported[className] = true
        log(string.format("%s: %s %.1f -> %.1f",
            className, PROPERTY_NAME, current, breedSeconds))
    else
        logV(string.format("%s: %.1f -> %.1f", className, current, breedSeconds))
    end
end

-- ============================================================================
-- RASTREAMENTO (v1.2.0)
-- ============================================================================
-- FindAllOf percorre todos os objetos do jogo (~200 ms neste save); feito a
-- cada 15 s causava travadas periódicas. Agora:
--   * NotifyOnNewObject guarda cada fazenda quando o jogo a cria;
--   * uma busca completa só 10 s após ClientRestart (entrar no mundo/renascer);
--   * o loop periódico só reaplica nos objetos guardados.
local tracked = {}   -- [endereço] = { obj =, className = }

local function Track(obj, className)
    local ok, addr = pcall(function() return obj:GetAddress() end)
    if ok and addr then tracked[addr] = { obj = obj, className = className } end
end

local function FullScan()
    for _, className in ipairs(TARGET_CLASSES) do
        local objects = nil
        pcall(function() objects = FindAllOf(className) end)
        for _, obj in ipairs(objects or {}) do Track(obj, className) end
    end
end

local function Scan()
    for addr, t in pairs(tracked) do
        local ok, isValid = pcall(function() return t.obj:IsValid() end)
        if ok and isValid then
            pcall(ApplyTo, t.obj, t.className)
        else
            tracked[addr] = nil
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

breedSeconds = ResolveBreedSeconds()

-- O aviso pode chegar fora do game thread: só guarda a referência.
for _, className in ipairs(TARGET_CLASSES) do
    NotifyOnNewObject("/Script/Pal." .. className, function(obj) Track(obj, className) end)
end

-- Busca completa uma vez por entrada no mundo (ExecuteWithDelay roda fora
-- do game thread, por isso o ExecuteInGameThread).
-- v1.2.2: busca completa (FindAllOf) só no primeiro ClientRestart de cada mapa
-- (crash de 13/10/2026 num FindAllOf logo após renascer).
local scannedThisMap = false
if type(RegisterLoadMapPreHook) == "function" then
    RegisterLoadMapPreHook(function() scannedThisMap = false end)
end

RegisterHook("/Script/Engine.PlayerController:ClientRestart", function()
    ExecuteWithDelay(10000, function()
        ExecuteInGameThread(function()
            if not scannedThisMap then
                scannedThisMap = true
                pcall(FullScan)
            end
            pcall(Scan)
        end)
    end)
end)

LoopAsync(Config.ScanIntervalMs, function()
    ExecuteInGameThread(Scan)
    return false
end)

log(string.format("v%s carregado: 1 ovo a cada %.1f min (%.0f s)",
    MOD_VERSION, breedSeconds / 60.0, breedSeconds))

-- Troca de mapa (ex.: voltar ao menu): os objetos do mundo são destruídos.
-- Esquece as referências guardadas para não acessar objetos mortos
-- (crash de 12/10/2026 ao voltar ao menu).
if type(RegisterLoadMapPreHook) == "function" then
    RegisterLoadMapPreHook(function()
        tracked = {}
    end)
end
