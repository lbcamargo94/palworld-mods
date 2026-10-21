-- ============================================================================
-- Pal Performance v0.1.0
-- ============================================================================
-- Aplica variáveis de console (cvars) do Unreal que reduzem engasgos de
-- carregamento do mapa e de limpeza de memória. Nada de gráficos.
--
-- Os valores ficam no config.txt (seção [CVars]: "nome = valor"). O mod:
--   * aplica cada cvar pelo próprio jogo (KismetSystemLibrary:
--     ExecuteConsoleCommand) - não altera Engine.ini; desligar o mod volta ao
--     padrão na próxima abertura do jogo;
--   * registra no log o valor antes e depois de cada uma;
--   * reaplica ao entrar no mundo (o carregamento do mapa pode redefinir
--     algumas).
--
-- Custo: só roda no menu principal e uma vez por entrada no mundo.
-- ============================================================================

local LOG_PREFIX  = "[PalPerformance]"
local MOD_VERSION = "0.1.0"

local UEHelpers = require("UEHelpers")

local CONFIG_PATHS = { "Mods\\PalPerformance\\config.txt", "ue4ss\\Mods\\PalPerformance\\config.txt" }

local function log(msg)
    print(LOG_PREFIX .. " " .. tostring(msg) .. "\n")
end

local function valid(obj)
    if not obj then return false end
    local ok, v = pcall(function() return obj:IsValid() end)
    return ok and v
end

-- ============================================================================
-- CONFIG
-- ============================================================================
local Enabled = true
local cvars = {}   -- { { name =, value = } } na ordem do arquivo

local function LoadConfig()
    for _, p in ipairs(CONFIG_PATHS) do
        local f = io.open(p, "r")
        if f then
            local section = ""
            for line in f:lines() do
                line = line:gsub("[;#].*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
                local sec = line:match("^%[(.-)%]$")
                if sec then
                    section = sec:lower()
                elseif line ~= "" then
                    local key, value = line:match("^([%w_%.]+)%s*=%s*(.-)$")
                    if key then
                        if section == "cvars" then
                            -- Só caracteres seguros no comando de console.
                            if value:match("^[%w%.%-]+$") then
                                cvars[#cvars + 1] = { name = key, value = value }
                            else
                                log("Valor ignorado para " .. key .. ": " .. value)
                            end
                        elseif key == "Enabled" then
                            Enabled = value:lower() ~= "false" and value ~= "0"
                        end
                    end
                end
            end
            f:close()
            return
        end
    end
    log("config.txt não encontrado - nada será aplicado.")
end

-- ============================================================================
-- APLICAÇÃO
-- ============================================================================
local function ReadCvar(lib, name)
    local ok, v = pcall(function() return lib:GetConsoleVariableFloatValue(name) end)
    if ok and type(v) == "number" then return v end
    return nil
end

local function Fmt(v)
    if v == nil then return "?" end
    if v == math.floor(v) then return string.format("%d", v) end
    return string.format("%.3f", v)
end

-- Aplica todas; `verbose` = registrar antes/depois de cada uma.
local function ApplyAll(verbose)
    local lib = UEHelpers.GetKismetSystemLibrary()
    local ctx = UEHelpers.GetWorldContextObject()
    if not (valid(lib) and valid(ctx)) then return false end
    local changed = 0
    for _, c in ipairs(cvars) do
        local before = ReadCvar(lib, c.name)
        local okE, err = pcall(function() lib:ExecuteConsoleCommand(ctx, c.name .. " " .. c.value, nil) end)
        local after = ReadCvar(lib, c.name)
        if not okE then
            log(string.format("%s: erro ao aplicar (%s)", c.name, tostring(err)))
        elseif verbose then
            log(string.format("%s: %s -> %s%s", c.name, Fmt(before), Fmt(after),
                (after ~= nil and tonumber(c.value) and math.abs(after - tonumber(c.value)) > 0.001)
                    and "  (NÃO aplicou - cvar inexistente ou bloqueada?)" or ""))
        end
        if before ~= after then changed = changed + 1 end
    end
    return true, changed
end

-- ============================================================================
-- INIT
-- ============================================================================
LoadConfig()
if not Enabled then
    log("v" .. MOD_VERSION .. " desativado no config.txt.")
    return
end

-- Menu principal: aplica assim que houver contexto de mundo.
local appliedAtStart, tries = false, 0
LoopAsync(2000, function()
    tries = tries + 1
    ExecuteInGameThread(function()
        if appliedAtStart then return end
        local ok, done = pcall(ApplyAll, true)
        if ok and done then appliedAtStart = true end
    end)
    return appliedAtStart or tries > 60
end)

-- Entrar no mundo: reaplica e registra só o que tinha voltado ao padrão.
RegisterHook("/Script/Engine.PlayerController:ClientRestart", function()
    ExecuteWithDelay(5000, function()
        ExecuteInGameThread(function()
            local ok, done, changed = pcall(ApplyAll, false)
            if ok and done and changed and changed > 0 then
                log(string.format("Ao entrar no mundo: %d cvar(s) tinham voltado ao padrão e foram reaplicadas.", changed))
            end
        end)
    end)
end)

log(string.format("v%s carregado: %d cvar(s) no config.", MOD_VERSION, #cvars))
