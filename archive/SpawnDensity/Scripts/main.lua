-- ============================================================================
-- Spawn Density v0.2.1
-- ============================================================================
-- Mais grupos de Pals selvagens na mesma área, mantendo grupos pequenos.
--
-- Como funciona:
--   * Cada spawner de Pals comuns que o jogo cria (BP_PalSpawner_Standard,
--     SpawnerType 0, planilha sem "BOSS"/"dungeon") ganha ExtraSpawners
--     cópias da MESMA classe a CloneDistanceMin..Max cm. A classe do spawner
--     já traz a lista de grupos da planilha (gravada no mapa - a tabela
--     DT_PalWildSpawner não é lida em tempo de jogo), então cada cópia sorteia
--     o próprio grupo da mesma região.
--   * Tamanho dos grupos: Num/Num_Max de cada espécie limitados a
--     MaxGroupSize (originais e cópias).
--   * Cópias sob demanda (v0.2.0): os originais só são anotados; a cópia é
--     criada quando o jogador chega a ActivateDistance do original e
--     destruída além de DeactivateDistance (lá o grupo já foi desfeito), com
--     no máximo 3 criações e 6 remoções por segundo.
--   * Ctrl+F5: relatório (spawners vistos, cópias, cópia mais próxima).
--
-- Nada é gravado no save: os spawners extras existem só na memória.
-- ============================================================================

local LOG_PREFIX  = "[SpawnDensity]"
local MOD_VERSION = "0.2.1"

local UEHelpers = require("UEHelpers")

local NOTIFY_CLASS     = "/Script/Pal.PalNPCSpawnerBase"
local STANDARD_CLASS   = "BP_PalSpawner_Standard_C"
local PROCESS_DELAY_S  = 2         -- espera o spawner terminar de inicializar
local CONFIG_PATHS = { "Mods\\SpawnDensity\\config.txt", "ue4ss\\Mods\\SpawnDensity\\config.txt" }

local function log(msg)
    print(LOG_PREFIX .. " " .. tostring(msg) .. "\n")
end

-- Migalhas (TraceLogging): uma linha antes de cada operação arriscada, para
-- saber onde foi um crash nativo (o pcall não segura ACCESS_VIOLATION).
local function trace(msg)
    if Config and Config.TraceLogging then print(LOG_PREFIX .. "[T] " .. tostring(msg) .. "\n") end
end

local function logV(msg)
    if Config and Config.VerboseLogging then print(LOG_PREFIX .. "[V] " .. tostring(msg) .. "\n") end
end

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

local function addressOf(obj)
    local ok, a = pcall(function() return obj:GetAddress() end)
    return ok and a or nil
end

-- ============================================================================
-- CONFIG
-- ============================================================================
Config = {
    Enabled          = true,
    ExtraSpawners    = 1,      -- cópias por spawner comum (0 a 3)
    CloneDistanceMin = 1500,   -- cm
    CloneDistanceMax = 3500,   -- cm
    MaxGroupSize     = 3,      -- máximo de Pals por espécie no grupo (0 = não mexer)
    ActivateDistance   = 35000, -- cm: cria cópias de spawners até esta distância do jogador
    DeactivateDistance = 50000, -- cm: remove cópias de spawners além desta distância
    VerboseLogging   = false,
    TraceLogging     = false,
}

local function LoadConfig()
    for _, p in ipairs(CONFIG_PATHS) do
        local f = io.open(p, "r")
        if f then
            for line in f:lines() do
                line = line:gsub("[;#].*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
                local key, value = line:match("^([%w_]+)%s*=%s*(.-)$")
                if key and Config[key] ~= nil then
                    if value:lower() == "true" then Config[key] = true
                    elseif value:lower() == "false" then Config[key] = false
                    else Config[key] = tonumber(value) or Config[key] end
                end
            end
            f:close()
            return
        end
    end
end

-- ============================================================================
-- REFLEXÃO (só nomes/tipos em cache - nunca FProperty* entre execuções)
-- ============================================================================
local typeCache = {}
local function PropTypes(cls)
    local ok, key = pcall(function() return cls:GetFullName() end)
    key = ok and key or tostring(cls)
    if typeCache[key] then return typeCache[key] end
    local map, s, guard = {}, cls, 0
    while valid(s) and guard < 32 do
        guard = guard + 1
        pcall(function()
            s:ForEachProperty(function(prop)
                map[prop:GetFName():ToString()] = prop:GetClass():GetFName():ToString()
            end)
        end)
        local okS, super = pcall(function() return s:GetSuperStruct() end)
        s = okS and super or nil
    end
    typeCache[key] = map
    return map
end

local standardCache = {}
local function IsStandardSpawner(obj)
    local ok, cls = pcall(function() return obj:GetClass() end)
    if not (ok and valid(cls)) then return false end
    local key = addressOf(cls) or fname(cls)
    if standardCache[key] ~= nil then return standardCache[key] end
    local s, guard, found = cls, 0, false
    while valid(s) and guard < 16 do
        guard = guard + 1
        if fname(s) == STANDARD_CLASS then found = true; break end
        local okS, super = pcall(function() return s:GetSuperStruct() end)
        s = okS and super or nil
    end
    standardCache[key] = found
    return found
end

-- ============================================================================
-- TAMANHO DOS GRUPOS
-- ============================================================================
local clampedGroups = 0

local function ClampGroups(sp, maxSize)
    if maxSize <= 0 or PropTypes(sp:GetClass())["SpawnGroupList"] ~= "ArrayProperty" then return end
    sp.SpawnGroupList:ForEach(function(_, elem)
        pcall(function()
            local group = elem:get()
            group.PalList:ForEach(function(_, tribeElem)
                pcall(function()
                    local tribe = tribeElem:get()
                    local nmax = tonumber(tribe.Num_Max) or 0
                    if nmax > maxSize then
                        tribe.Num_Max = maxSize
                        clampedGroups = clampedGroups + 1
                    end
                    if (tonumber(tribe.Num) or 0) > math.min(nmax, maxSize) then
                        tribe.Num = math.min(nmax, maxSize)
                    end
                end)
            end)
        end)
    end)
end

-- ============================================================================
-- CRIAÇÃO DAS CÓPIAS
-- ============================================================================
local statics = nil
local beginArgs, finishArgs = nil, nil   -- nº de parâmetros (sem ReturnValue)

local function ParamCount(path)
    local fn = StaticFindObject(path)
    if not valid(fn) then return nil end
    local n = 0
    fn:ForEachProperty(function(prop)
        if prop:GetFName():ToString() ~= "ReturnValue" then n = n + 1 end
    end)
    return n
end

local function SpawnClone(sp, location)
    if not valid(statics) then statics = UEHelpers.GetGameplayStatics() end
    beginArgs = beginArgs or ParamCount("/Script/Engine.GameplayStatics:BeginDeferredActorSpawnFromClass")
    finishArgs = finishArgs or ParamCount("/Script/Engine.GameplayStatics:FinishSpawningActor")
    local transform = {
        Rotation = { X = 0.0, Y = 0.0, Z = 0.0, W = 1.0 },
        Translation = { X = location.X, Y = location.Y, Z = location.Z },
        Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 },
    }
    local cls = sp:GetClass()
    local actor
    trace("spawn: begin")
    if beginArgs == 6 then
        actor = statics:BeginDeferredActorSpawnFromClass(sp, cls, transform, 1, nil, 0)
    else
        actor = statics:BeginDeferredActorSpawnFromClass(sp, cls, transform, 1, nil)
    end
    if not valid(actor) then return nil end
    trace("spawn: finish")
    if finishArgs == 3 then
        statics:FinishSpawningActor(actor, transform, 0)
    else
        statics:FinishSpawningActor(actor, transform)
    end
    return actor
end

-- Identidade do spawner = classe + posição arredondada (estável entre recargas).
local function SpawnerKey(sp, loc)
    return string.format("%s@%d,%d", fname(sp:GetClass()), math.floor(loc.X / 100), math.floor(loc.Y / 100))
end

-- Cópias sob demanda (v0.2.0): o jogo carrega spawners de uma área enorme
-- (v0.1.0 viu 2115 em 3 min e criou 1702 cópias, 717 vivas - travadas). Agora
-- os originais só são anotados; a cópia é criada quando o jogador chega a
-- ActivateDistance e destruída além de DeactivateDistance, com limite de
-- criações/remoções por segundo.
local pending = {}        -- { obj =, at = }
local cloneSet = {}       -- [endereço da cópia] = true
local entries = {}        -- [chave] = { orig =, loc =, clones = {}, sheet = }
local entryCount = 0
local stats = { seen = 0, eligible = 0, spawned = 0, failed = 0, destroyed = 0 }
local firstErrorLogged = false
local SPAWNS_PER_TICK, DESTROYS_PER_TICK = 3, 6

local function ProcessSpawner(sp)
    if not valid(sp) then return end
    local addr = addressOf(sp)
    if not addr or cloneSet[addr] then return end
    trace("anotar: classe")
    if not IsStandardSpawner(sp) then return end
    stats.seen = stats.seen + 1
    local types = PropTypes(sp:GetClass())
    trace("anotar: tipo/planilha")
    if types["SpawnerType"] and tonumber(sp.SpawnerType) ~= 0 then return end
    local sheet = types["SpawnerName"] and str(sp.SpawnerName) or ""
    local low = sheet:lower()
    if low:find("boss", 1, true) or low:find("dungeon", 1, true) then return end

    trace("anotar: limitar grupos " .. sheet)
    ClampGroups(sp, math.floor(Config.MaxGroupSize))
    stats.eligible = stats.eligible + 1
    trace("anotar: posição")
    local loc = sp:K2_GetActorLocation()
    local key = SpawnerKey(sp, loc)
    local e = entries[key]
    if e then
        e.orig = sp                      -- recriado: mantém as cópias vivas
    else
        entries[key] = { orig = sp, loc = { X = loc.X, Y = loc.Y, Z = loc.Z }, clones = {}, sheet = sheet }
        entryCount = entryCount + 1
    end
end

local function ProcessPending()
    local now = os.time()
    local keep = {}
    for _, item in ipairs(pending) do
        if now - item.at >= PROCESS_DELAY_S then
            local ok, err = pcall(ProcessSpawner, item.obj)
            if not ok then logV("Erro processando spawner: " .. tostring(err)) end
        else
            keep[#keep + 1] = item
        end
    end
    pending = keep
end

local function DestroyClones(e)
    local n = 0
    for _, c in ipairs(e.clones) do
        if valid(c) then
            local caddr = addressOf(c)
            trace("destruir cópia")
            pcall(function() c:K2_DestroyActor() end)
            if caddr then cloneSet[caddr] = nil end
            n = n + 1
        end
    end
    e.clones = {}
    stats.destroyed = stats.destroyed + n
    return n
end

local function CreateClones(e, extra, budget)
    local dmin = math.max(300, Config.CloneDistanceMin)
    local dmax = math.max(dmin, Config.CloneDistanceMax)
    local made = 0
    -- Remove referências mortas.
    local alive = {}
    for _, c in ipairs(e.clones) do if valid(c) then alive[#alive + 1] = c end end
    e.clones = alive
    while #e.clones < extra and made < budget do
        local angle = math.random() * 2 * math.pi
        local dist = dmin + math.random() * (dmax - dmin)
        local target = { X = e.loc.X + math.cos(angle) * dist, Y = e.loc.Y + math.sin(angle) * dist, Z = e.loc.Z }
        trace("criar cópia: " .. e.sheet)
        local ok, actor = pcall(SpawnClone, e.orig, target)
        made = made + 1
        if ok and valid(actor) then
            local caddr = addressOf(actor)
            if caddr then cloneSet[caddr] = true end
            -- v0.2.1: não mexe mais nos grupos da cópia logo após criá-la (passo
            -- não essencial e suspeito no crash da v0.2.0).
            table.insert(e.clones, actor)
            trace("cópia criada")
            stats.spawned = stats.spawned + 1
        else
            stats.failed = stats.failed + 1
            if not firstErrorLogged then
                firstErrorLogged = true
                log("Falha ao criar cópia de spawner: " .. tostring(actor))
            end
            break
        end
    end
    return made
end

-- A cada segundo: cria cópias perto do jogador e remove as distantes.
local cachedPlayer, nextPlayerSearch = nil, 0
local function Tick()
    local extra = math.max(0, math.min(3, math.floor(Config.ExtraSpawners)))
    -- FindFirstOf percorre objetos: guarda o personagem e só procura de novo
    -- (no máximo a cada 5 s) quando a referência fica inválida.
    if not valid(cachedPlayer) then
        if os.time() < nextPlayerSearch then return end
        nextPlayerSearch = os.time() + 5
        cachedPlayer = FindFirstOf("PalPlayerCharacter")
        if not valid(cachedPlayer) then return end
    end
    local player = cachedPlayer
    local okP, p = pcall(function() return player:K2_GetActorLocation() end)
    if not okP then return end
    local act2 = Config.ActivateDistance ^ 2
    local deact2 = Config.DeactivateDistance ^ 2
    local spawnBudget, destroyBudget = SPAWNS_PER_TICK, DESTROYS_PER_TICK
    for key, e in pairs(entries) do
        local dx, dy = e.loc.X - p.X, e.loc.Y - p.Y
        local d2 = dx * dx + dy * dy
        if d2 > deact2 then
            if #e.clones > 0 and destroyBudget > 0 then
                destroyBudget = destroyBudget - DestroyClones(e)
            end
            if #e.clones == 0 and not valid(e.orig) then
                entries[key] = nil
                entryCount = entryCount - 1
            end
        elseif d2 < act2 and extra > 0 and spawnBudget > 0 and #e.clones < extra and valid(e.orig) then
            spawnBudget = spawnBudget - CreateClones(e, extra, spawnBudget)
        end
    end
end

-- ============================================================================
-- RELATÓRIO (Ctrl+F5)
-- ============================================================================
local function Report()
    local alive, nearest = 0, nil
    local player = FindFirstOf("PalPlayerCharacter")
    local p = valid(player) and player:K2_GetActorLocation() or nil
    for _, e in pairs(entries) do
        for _, c in ipairs(e.clones) do
            if valid(c) then
                alive = alive + 1
                if p then
                    local ok, l = pcall(function() return c:K2_GetActorLocation() end)
                    if ok then
                        local d = ((l.X - p.X) ^ 2 + (l.Y - p.Y) ^ 2) ^ 0.5
                        if not nearest or d < nearest then nearest = d end
                    end
                end
            end
        end
    end
    log(string.format("Relatório: %d spawner(s) comuns vistos, %d anotados agora, %d cópia(s) vivas " ..
        "(%d criadas, %d destruídas, %d falhas), %d limite(s) de grupo aplicados; cópia mais próxima: %s.",
        stats.seen, entryCount, alive, stats.spawned, stats.destroyed, stats.failed, clampedGroups,
        nearest and string.format("%.0f m", nearest / 100) or "-"))
end

-- ============================================================================
-- INIT
-- ============================================================================
LoadConfig()
if not Config.Enabled then
    log("v" .. MOD_VERSION .. " desativado no config.txt.")
    return
end
math.randomseed(os.time())

-- O aviso chega durante a construção (possivelmente fora do game thread): só
-- enfileira; o processamento espera o spawner inicializar.
NotifyOnNewObject(NOTIFY_CLASS, function(obj)
    pending[#pending + 1] = { obj = obj, at = os.time() }
end)

local queued = false
LoopAsync(1000, function()
    if queued then return false end
    queued = true
    ExecuteInGameThread(function()
        if #pending > 0 then pcall(ProcessPending) end
        local ok, err = pcall(Tick)
        if not ok then logV("Erro no ciclo: " .. tostring(err)) end
        queued = false
    end)
    return false
end)

RegisterKeyBind(Key.F5, { ModifierKey.CONTROL }, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(Report)
        if not ok then log("Erro no relatório: " .. tostring(err)) end
    end)
end)

log(string.format("v%s carregado: %d cópia(s) por spawner comum (até %.0f m do jogador), grupos de até %d por espécie.",
    MOD_VERSION, math.floor(Config.ExtraSpawners), Config.ActivateDistance / 100, math.floor(Config.MaxGroupSize)))
