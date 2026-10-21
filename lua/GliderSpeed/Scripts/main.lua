-- ============================================================================
-- Glider Speed v0.2.1
-- ============================================================================
-- Aumenta a velocidade de todos os planadores (itens e Pals planadores) em
-- GliderSpeedPercent (0 a 200; padrão 50 = +50%).
--
-- Como o jogo faz (descoberto na v0.1.0, patch 2026-09-15):
--   Cada planador (PalGliderObject, ex.: BP_Glider_Good_C) tem GliderMaxSpeed
--   (650 no planador bom). Ao começar a planar, o jogo copia os parâmetros do
--   planador atual para o movimento do personagem
--   (PalCharacterMovementComponent.GliderMaxSpeed) - é esse o valor usado no
--   voo, já com o bônus de relíquias.
--
-- O mod ajusta o movimento do personagem: quando o GliderMaxSpeed muda para um
-- valor que não foi o mod que escreveu (o jogo aplicou um planador), esse valor
-- vira a base e o mod grava base x (1 + GliderSpeedPercent/100). Vale para
-- qualquer planador, inclusive os de Pals, sem tabela de valores.
--
-- Custo: 5 conferências por segundo de 1 propriedade no personagem já
-- guardado (nenhum FindAllOf periódico; FindFirstOf só quando o personagem
-- muda - ex.: ao entrar no mundo ou renascer).
--
-- A descoberta da v0.1.0 está em tools\discovery.lua.
-- ============================================================================

local LOG_PREFIX  = "[GliderSpeed]"
local MOD_VERSION = "0.2.2"

local SPEED_PROP = "GliderMaxSpeed"
local MIN_PERCENT, MAX_PERCENT = 0, 200

local CONFIG_PATHS = {
    "Mods\\GliderSpeed\\config.txt",
    "ue4ss\\Mods\\GliderSpeed\\config.txt",
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
-- CONFIG
-- ============================================================================
Config = {
    Enabled            = true,
    GliderSpeedPercent = 50,
    CheckIntervalMs    = 200,
    VerboseLogging     = false,
}

local function ParseValue(v)
    if v == "0" or v:lower() == "false" then return false end
    if v == "1" or v:lower() == "true"  then return true  end
    local n = tonumber((v:gsub(",", ".")))
    if n ~= nil then return n end
    return v
end

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
            if key and Config[key] ~= nil then Config[key] = ParseValue(value) end
        end
    end
    f:close()
end

-- "GliderSpeedPercent = 0" vira false no ParseValue; trata como número.
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
        log(string.format("%s %s fora de %s-%s - usando %s.", name, tostring(n), tostring(minValue),
            tostring(maxValue), tostring(clamped)))
        return clamped
    end
    return n
end

-- ============================================================================
-- UTILITÁRIOS
-- ============================================================================
local function valid(obj)
    if not obj then return false end
    local ok, v = pcall(function() return obj:IsValid() end)
    return ok and v
end

local function HasFloat(obj, name)
    local found = false
    pcall(function()
        local s, guard = obj:GetClass(), 0
        while not found and valid(s) and guard < 32 do
            guard = guard + 1
            s:ForEachProperty(function(prop)
                if prop:GetFName():ToString() == name and prop:GetClass():GetFName():ToString() == "FloatProperty" then
                    found = true
                end
            end)
            s = s:GetSuperStruct()
        end
    end)
    return found
end

-- ============================================================================
-- APLICAÇÃO
-- ============================================================================
local factor = 1.5
local movement = nil       -- PalCharacterMovementComponent do jogador
local lastWritten = nil    -- último valor gravado pelo mod
local lastBase = nil

local movementAddr = nil

-- O estado (lastWritten/lastBase) só é zerado quando o componente de
-- movimento é OUTRO. Na v0.2.0 ele era zerado a cada ClientRestart (entrar,
-- morrer, teleportar) e o valor já aumentado virava "base" de novo - a
-- velocidade acumulava (650 -> 975 -> 1462 -> 2194).
local function FindMovement()
    local player = FindFirstOf("PalPlayerCharacter")
    if not valid(player) then movement = nil; return end
    local ok, mv = pcall(function() return player.CharacterMovement end)
    if not (ok and valid(mv) and HasFloat(mv, SPEED_PROP)) then movement = nil; return end
    local okA, addr = pcall(function() return mv:GetAddress() end)
    addr = okA and addr or nil
    if addr ~= movementAddr then
        movementAddr, lastWritten, lastBase = addr, nil, nil
        logV("Movimento do personagem encontrado.")
    end
    movement = mv
end

local nextSearch = 0

local function Apply()
    if not valid(movement) then
        -- Sem personagem (menu/carregando): FindFirstOf percorre objetos, então
        -- procura no máximo a cada 5 s.
        if os.time() < nextSearch then return end
        nextSearch = os.time() + 5
        FindMovement()
        if not valid(movement) then return end
    end
    local current = movement[SPEED_PROP]
    if type(current) ~= "number" or current <= 0 then return end
    -- Valor que o mod não escreveu = o jogo aplicou um planador: nova base.
    if lastWritten == nil or math.abs(current - lastWritten) > 0.01 then
        local target = current * factor
        movement[SPEED_PROP] = target
        lastWritten = target
        if lastBase == nil or math.abs(current - lastBase) > 0.01 then
            log(string.format("Planador: velocidade %.0f -> %.0f (+%d%%)", current, target,
                math.floor((factor - 1) * 100 + 0.5)))
        end
        lastBase = current
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

factor = 1 + ConfigNumber("GliderSpeedPercent", 50, MIN_PERCENT, MAX_PERCENT) / 100
local interval = ConfigNumber("CheckIntervalMs", 200, 50, 2000)

-- Personagem novo (entrar no mundo/renascer): procura o movimento de novo.
RegisterHook("/Script/Engine.PlayerController:ClientRestart", function()
    ExecuteWithDelay(2000, function()
        ExecuteInGameThread(function() pcall(FindMovement) end)
    end)
end)

local queued = false
LoopAsync(interval, function()
    if queued then return false end
    queued = true
    ExecuteInGameThread(function()
        local ok, err = pcall(Apply)
        if not ok then logV("Erro aplicando: " .. tostring(err)) end
        queued = false
    end)
    return false
end)

log(string.format("v%s carregado: planadores +%d%%.", MOD_VERSION, math.floor((factor - 1) * 100 + 0.5)))

-- Troca de mapa (ex.: voltar ao menu): os objetos do mundo são destruídos.
-- Esquece as referências guardadas para não acessar objetos mortos
-- (crash de 12/10/2026 ao voltar ao menu).
if type(RegisterLoadMapPreHook) == "function" then
    RegisterLoadMapPreHook(function()
        movement = nil
    end)
end
