-- ============================================================================
-- Bigger Magazines v0.2.0
-- ============================================================================
-- Multiplica a capacidade do pente das armas (MagazineSize) por
-- MagazineMultiplier (2 a 10; padrão 3).
--
-- Nomes encontrados no executável (patch 2026-09-15), sem a classe dona:
--   MagazineSize, MaxMagazineSize, GetMagazineSize, GetMaxMagazineSize,
--   IsFullMagazine, IsInfinityMagazine, CurrentBulletNum
--
-- v0.2.0 descobre e aplica na mesma execução:
--   1. Uma vez, ~15 s após carregar: percorre todas as classes/structs e grava
--      no log as propriedades com "Magazine" no nome (classe, nome, tipo).
--      Classes com MagazineSize:IntProperty viram alvos.
--   2. A cada ScanIntervalMs: em cada instância dos alvos, MagazineSize =
--      original × multiplicador (original guardado na primeira leitura, então
--      reaplicar nunca acumula). Valores <= 0 (sem pente) são ignorados.
--
-- Segurança: só toca em MagazineSize de classes que a reflexão confirmou ter
-- essa propriedade como IntProperty (acessar propriedade inexistente causa
-- ACCESS_VIOLATION mesmo dentro de pcall). Não chama funções do jogo.
-- ============================================================================

local LOG_PREFIX  = "[BiggerMagazines]"
local MOD_VERSION = "0.2.2"

local PROPERTY_NAME = "MagazineSize"
local DIAG_PATTERN  = "Magazine"

local MIN_MULTIPLIER = 2
local MAX_MULTIPLIER = 10

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
    Enabled            = true,
    MagazineMultiplier = 3,
    ScanIntervalMs     = 15000,
    VerboseLogging     = false,
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
    "Mods\\BiggerMagazines\\config.txt",
    "Mods/BiggerMagazines/config.txt",
    "ue4ss\\Mods\\BiggerMagazines\\config.txt",
    "ue4ss/Mods/BiggerMagazines/config.txt",
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

-- Lê um número do config: ParseValue converte "1"/"0" em true/false e o
-- usuário pode escrever vírgula decimal ("2,5").
local function ConfigNumber(name, default, minValue, maxValue)
    local raw = Config[name]
    if raw == true then raw = 1 elseif raw == false then raw = 0 end
    local n = tonumber((tostring(raw):gsub(",", ".")))
    if not n then
        log(string.format("%s inválido (%s) - usando %s.", name, tostring(Config[name]), tostring(default)))
        return default
    end
    if n < minValue or n > maxValue then
        local clamped = math.max(minValue, math.min(maxValue, n))
        log(string.format("%s %s fora de %s-%s - usando %s.",
            name, tostring(n), tostring(minValue), tostring(maxValue), tostring(clamped)))
        return clamped
    end
    return n
end

-- ============================================================================
-- DESCOBERTA (uma vez)
-- ============================================================================
local targetClasses = {}   -- nomes de classes com MagazineSize:IntProperty
local discovered = false

local function RunDiscovery()
    local found = 0
    ForEachUObject(function(obj)
        pcall(function()
            local kind = obj:GetClass():GetFName():ToString()
            if kind ~= "Class" and kind ~= "ScriptStruct" then return end
            local parts = {}
            obj:ForEachProperty(function(prop)
                local name = prop:GetFName():ToString()
                if name:find(DIAG_PATTERN) then
                    local typeName = prop:GetClass():GetFName():ToString()
                    table.insert(parts, name .. ":" .. typeName)
                    if kind == "Class" and name == PROPERTY_NAME and typeName == "IntProperty" then
                        table.insert(targetClasses, obj:GetFName():ToString())
                    end
                end
            end)
            if #parts > 0 then
                found = found + 1
                log("PROP " .. obj:GetFullName() .. " {" .. table.concat(parts, ", ") .. "}")
            end
        end)
    end)
    log(string.format("Descoberta: %d tipo(s) com \"%s\"; alvos: %s", found, DIAG_PATTERN,
        #targetClasses > 0 and table.concat(targetClasses, ", ") or "nenhum"))
end

-- ============================================================================
-- APLICAÇÃO
-- ============================================================================
local multiplier = 3
local originals = {}       -- [nome completo do objeto] = MagazineSize original
local reportedClass = {}

-- Rastreamento (v0.2.0): FindAllOf percorre todos os objetos do jogo
-- (~200 ms neste save); 3 buscas a cada 15 s causavam travadas periódicas.
-- Agora a busca completa roda só na descoberta e 10 s após ClientRestart;
-- NotifyOnNewObject guarda os objetos criados depois e o loop periódico só
-- reaplica nos objetos guardados.
local tracked = {}   -- [nome da classe] = { [endereço] = objeto }

local function Track(obj, className)
    local ok, addr = pcall(function() return obj:GetAddress() end)
    if not (ok and addr) then return end
    tracked[className] = tracked[className] or {}
    tracked[className][addr] = obj
end

local function FullScan()
    for _, className in ipairs(targetClasses) do
        for _, obj in ipairs(FindAllOf(className) or {}) do Track(obj, className) end
    end
end

local notifyRegistered = false
local function RegisterNotifications()
    if notifyRegistered then return end
    notifyRegistered = true
    for _, className in ipairs(targetClasses) do
        pcall(NotifyOnNewObject, "/Script/Pal." .. className, function(obj) Track(obj, className) end)
    end
end

local function TrackedObjects(className)
    local list = {}
    for addr, obj in pairs(tracked[className] or {}) do
        local ok, isValid = pcall(function() return obj:IsValid() end)
        if ok and isValid then list[#list + 1] = obj else tracked[className][addr] = nil end
    end
    return list
end

local function ApplyMagazines()
    for _, className in ipairs(targetClasses) do
        local changed, examples = 0, {}
        for _, obj in ipairs(TrackedObjects(className)) do
            pcall(function()
                if not obj:IsValid() then return end
                local key = obj:GetFullName()
                local current = obj[PROPERTY_NAME]
                if type(current) ~= "number" then return end
                if originals[key] == nil then originals[key] = current end
                local original = originals[key]
                if original <= 0 then return end
                local target = math.floor(original * multiplier + 0.5)
                if current ~= target then
                    obj[PROPERTY_NAME] = target
                    changed = changed + 1
                    if #examples < 8 then
                        table.insert(examples, string.format("%s %d->%d",
                            obj:GetFName():ToString(), original, target))
                    end
                end
            end)
        end
        if changed > 0 then
            if not reportedClass[className] then
                reportedClass[className] = true
                log(string.format("%s: %d objeto(s) com pente x%s. Ex.: %s",
                    className, changed, tostring(multiplier), table.concat(examples, ", ")))
            else
                logV(string.format("%s: %d objeto(s) reaplicados.", className, changed))
            end
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

multiplier = ConfigNumber("MagazineMultiplier", 3, MIN_MULTIPLIER, MAX_MULTIPLIER)
local scanInterval = ConfigNumber("ScanIntervalMs", 15000, 5000, 600000)

LoopAsync(scanInterval, function()
    ExecuteInGameThread(function()
        if not discovered then
            discovered = true
            local ok, err = pcall(RunDiscovery)
            if not ok then log("Erro na descoberta: " .. tostring(err)) end
            pcall(FullScan)
            pcall(RegisterNotifications)
        end
        local ok, err = pcall(ApplyMagazines)
        if not ok then log("Erro aplicando o pente: " .. tostring(err)) end
    end)
    return false
end)

-- v0.2.2: busca completa (FindAllOf) só no primeiro ClientRestart de cada mapa
-- (crash de 13/10/2026 num FindAllOf logo após renascer).
local scannedThisMap = false
if type(RegisterLoadMapPreHook) == "function" then
    RegisterLoadMapPreHook(function() scannedThisMap = false end)
end

RegisterHook("/Script/Engine.PlayerController:ClientRestart", function()
    ExecuteWithDelay(10000, function()
        ExecuteInGameThread(function()
            if not discovered then return end   -- a descoberta já faz a busca completa
            if not scannedThisMap then
                scannedThisMap = true
                pcall(FullScan)
            end
            local ok, err = pcall(ApplyMagazines)
            if not ok then log("Erro aplicando o pente: " .. tostring(err)) end
        end)
    end)
end)

log(string.format("v%s carregado: pente x%s.", MOD_VERSION, tostring(multiplier)))

-- Troca de mapa (ex.: voltar ao menu): os objetos do mundo são destruídos.
-- Esquece as referências guardadas para não acessar objetos mortos
-- (crash de 12/10/2026 ao voltar ao menu).
if type(RegisterLoadMapPreHook) == "function" then
    RegisterLoadMapPreHook(function()
        tracked = {}
    end)
end
