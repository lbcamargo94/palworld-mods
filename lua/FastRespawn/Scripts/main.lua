-- ============================================================================
-- Fast Respawn v0.5.5
-- ============================================================================
-- Reduz o tempo de reaparecimento e aumenta o alcance de surgimento dos Pals
-- (valores no config.txt).
--
-- Onde o jogo guarda os valores (patch 2026-09-15, descoberto na v0.1.0):
--   * Alcance: PalGameSetting.Spawner_DefaultSpawnRadius_S/M/L/NPC
--     (80/100/150/200 m) e Spawner_DefaultDespawnDistance_S/M/L/NPC
--     (80/150/200/200 m). Os dois escalam juntos: Pals que surgem além da
--     distância de desaparecimento ficariam aparecendo e sumindo.
--   * Chefe de dungeon: PalDungeonFixedEntrance.
--     RespawnCoolTimeMinutesAfterBossDefeated (60 min, uma por dungeon).
--   * Ainda em descoberta: Pals normais e chefes de campo
--     (DT_PalSpawnerPlacement.RespawnCoolTime?) e o horário de volta do chefe
--     (PalDungeonInstanceModelFixedDungeon.RespawnBossTimeAt) para o
--     cronômetro no mapa.
--
-- Aplicação sem travadas: nada de FindAllOf periódico. NotifyOnNewObject
-- guarda as entradas de dungeon quando o jogo as cria; uma busca completa só
-- 10 s após ClientRestart; o loop periódico só reaplica nos objetos guardados.
-- Valores sempre calculados a partir do original (reaplicar nunca acumula).
--
-- Ctrl+F9: descoberta focada (só leitura) em Mods\FastRespawn\discovery.txt.
--
-- Segurança: só lê/escreve propriedades que a reflexão confirmou existirem
-- (acessar propriedade inexistente causa ACCESS_VIOLATION mesmo em pcall).
-- ============================================================================

local LOG_PREFIX  = "[FastRespawn]"
local MOD_VERSION = "0.5.8"

local RADIUS_PROPS = {
    "Spawner_DefaultSpawnRadius_S", "Spawner_DefaultSpawnRadius_M",
    "Spawner_DefaultSpawnRadius_L", "Spawner_DefaultSpawnRadius_NPC",
    "Spawner_DefaultDespawnDistance_S", "Spawner_DefaultDespawnDistance_M",
    "Spawner_DefaultDespawnDistance_L", "Spawner_DefaultDespawnDistance_NPC",
}
local GAME_SETTING_CDO = "/Game/Pal/Blueprint/System/BP_PalGameSetting.Default__BP_PalGameSetting_C"
local DUNGEON_CLASS = "PalDungeonFixedEntrance"
local DUNGEON_PROP  = "RespawnCoolTimeMinutesAfterBossDefeated"
local SPAWNER_TABLE = "/Game/Pal/DataTable/Spawner/DT_PalSpawnerPlacement.DT_PalSpawnerPlacement"

local CONFIG_DIRS = { "Mods\\FastRespawn\\", "ue4ss\\Mods\\FastRespawn\\" }

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
    Enabled                   = true,
    SpawnRangePercent         = 100,  -- % a mais de alcance (100 = o dobro)
    DungeonBossRespawnPercent = 50,   -- % do tempo original (50 = metade)
    FieldBossRespawnPercent   = 50,   -- % do tempo original
    DungeonBossRespawnMinutes = 30,    -- minutos fixos (0 = usar a %)
    FieldBossRespawnMinutes   = 30,    -- minutos fixos (0 = usar a %)
    WildRespawnPercent        = 50,   -- reservado (em descoberta)
    ShowBossTimerOnMap        = true, -- reservado (próxima versão)
    ScanIntervalMs            = 15000,
    VerboseLogging            = false,
}

local modDir = nil

local function ParseValue(v)
    if v == "0" or v:lower() == "false" then return false end
    if v == "1" or v:lower() == "true"  then return true  end
    local n = tonumber((v:gsub(",", ".")))
    if n ~= nil then return n end
    return v
end

local function LoadConfig()
    local f = nil
    for _, dir in ipairs(CONFIG_DIRS) do
        f = io.open(dir .. "config.txt", "r")
        if f then modDir = dir; break end
    end
    if not f then
        log("config.txt não encontrado - usando valores padrão.")
        return
    end
    for line in f:lines() do
        line = line:gsub("[;#].*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" then
            local key, value = line:match("^([%w_]+)%s*=%s*(.-)$")
            if key and Config[key] ~= nil then Config[key] = ParseValue(value) end
        end
    end
    f:close()
end

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

local function addressOf(obj)
    local ok, a = pcall(function() return obj:GetAddress() end)
    return ok and a or nil
end

-- Nomes/tipos das propriedades da classe e superclasses. Só strings no cache
-- (FProperty* de blueprints ficam inválidos quando o jogo os descarrega - foi
-- o crash do Ctrl+F9 na v0.1.0).
local typeCache = {}
local function PropTypes(cls)
    local key = fullName(cls)
    if typeCache[key] then return typeCache[key] end
    local map, s, guard = {}, cls, 0
    while valid(s) and guard < 32 do
        guard = guard + 1
        pcall(function()
            s:ForEachProperty(function(prop)
                map[prop:GetFName():ToString()] = prop:GetClass():GetFName():ToString()
            end)
        end)
        local ok, super = pcall(function() return s:GetSuperStruct() end)
        s = ok and super or nil
    end
    typeCache[key] = map
    return map
end

local function HasNumber(obj, name)
    local t = PropTypes(obj:GetClass())[name]
    return t == "FloatProperty" or t == "DoubleProperty" or t == "IntProperty"
end

-- ============================================================================
-- APLICAÇÃO
-- ============================================================================
local rangeFactor, dungeonFactor = 2.0, 0.5
-- Tempos fixos em minutos (0 = usar a porcentagem).
local dungeonMinutes, fieldMinutes = 0, 0
local originals = {}      -- [endereço][propriedade] = valor original
local trackedEntrances = {}
local reported = {}

local function Original(obj, prop)
    local addr = addressOf(obj)
    if not addr then return nil end
    originals[addr] = originals[addr] or {}
    if originals[addr][prop] == nil then originals[addr][prop] = obj[prop] end
    return originals[addr][prop]
end

-- `absolute` (opcional) substitui orig x factor por um valor fixo.
local function SetScaled(obj, prop, factor, label, absolute)
    if not HasNumber(obj, prop) then return false end
    local orig = Original(obj, prop)
    if type(orig) ~= "number" or orig <= 0 then return false end
    local target = absolute or orig * factor
    if math.abs((obj[prop] or 0) - target) < 0.001 then return false end
    obj[prop] = target
    local key = label .. "|" .. prop
    if not reported[key] then
        reported[key] = true
        log(string.format("%s.%s: %.1f -> %.1f", label, prop, orig, target))
    end
    return true
end

local function ApplyGameSetting()
    local objs = FindAllOf("PalGameSetting") or {}
    local cdo = StaticFindObject(GAME_SETTING_CDO)
    if valid(cdo) then objs[#objs + 1] = cdo end
    local changed = 0
    for _, gs in ipairs(objs) do
        pcall(function()
            if not valid(gs) then return end
            for _, prop in ipairs(RADIUS_PROPS) do
                if SetScaled(gs, prop, rangeFactor, "PalGameSetting") then changed = changed + 1 end
            end
        end)
    end
    return changed
end

local function TrackEntrance(obj)
    local addr = addressOf(obj)
    if addr then trackedEntrances[addr] = obj end
end

local function ApplyDungeons()
    local changed = 0
    for addr, obj in pairs(trackedEntrances) do
        local ok = pcall(function()
            if not valid(obj) then trackedEntrances[addr] = nil; return end
            if SetScaled(obj, DUNGEON_PROP, dungeonFactor, DUNGEON_CLASS, dungeonMinutes > 0 and dungeonMinutes or nil) then changed = changed + 1 end
        end)
        if not ok then trackedEntrances[addr] = nil end
    end
    return changed
end

-- Chefes de campo: linhas de DT_PalSpawnerPlacement com RespawnCoolTime > 0
-- (na v0.2.0: 18 linhas *_FBOSS_*, SpawnerType=4, todas com 60). As demais
-- têm 0 e usam um padrão interno do jogo ainda não localizado.
local fieldFactor = 0.5
local fieldOriginals = {}   -- [nome da linha] = RespawnCoolTime original
local spawnerCool = {}      -- [SpawnerName] = RespawnCoolTime original (min), p/ o cronômetro

-- A tabela fica carregada e mantém os valores: basta uma passada por sessão.
-- (v0.5.6: o ForEachRow de 8253 linhas a cada ClientRestart coincidiu com
-- crashes dentro do Lua do UE4SS.)
local fieldApplied, fieldAppliedRows = false, 0

local function ApplyFieldBosses()
    if fieldApplied then return 0, fieldAppliedRows end
    local dt = StaticFindObject(SPAWNER_TABLE)
    if not valid(dt) then return 0, 0 end
    if PropTypes(dt.RowStruct)["RespawnCoolTime"] ~= "FloatProperty" then return 0, 0 end
    local changed, rows = 0, 0
    dt:ForEachRow(function(rowName, row)
        pcall(function()
            local key = str(rowName)
            local orig = fieldOriginals[key]
            if orig == nil then
                orig = row.RespawnCoolTime
                fieldOriginals[key] = orig
            end
            if type(orig) ~= "number" then return end
            local target
            if orig > 0 then
                pcall(function() spawnerCool[row.SpawnerName:ToString()] = orig end)
                target = fieldMinutes > 0 and fieldMinutes or orig * fieldFactor
            elseif fieldMinutes > 0 then
                -- Experimental (v0.5.0): linhas de chefe com 0 ("padrão interno")
                -- recebem o tempo fixo. O log "Chefe de campo voltou" confirma
                -- se o jogo respeita.
                local okN, name = pcall(function() return row.SpawnerName:ToString() end)
                if not (okN and name:upper():find("BOSS", 1, true)) then return end
                target = fieldMinutes
            else
                return
            end
            rows = rows + 1
            if math.abs(row.RespawnCoolTime - target) > 0.001 then
                row.RespawnCoolTime = target
                changed = changed + 1
            end
        end)
    end)
    if rows > 0 then fieldApplied, fieldAppliedRows = true, rows end
    return changed, rows
end

local function FullScan()
    for _, obj in ipairs(FindAllOf(DUNGEON_CLASS) or {}) do TrackEntrance(obj) end
    local gs = ApplyGameSetting()
    local dg = ApplyDungeons()
    local fbChanged, fbRows = ApplyFieldBosses()
    local n = 0
    for _ in pairs(trackedEntrances) do n = n + 1 end
    local dungeonLabel = dungeonMinutes > 0 and string.format("%g min", dungeonMinutes) or string.format("x%.2f", dungeonFactor)
    local fieldLabel = fieldMinutes > 0 and string.format("%g min", fieldMinutes) or string.format("x%.2f", fieldFactor)
    log(string.format("Aplicado: alcance x%.2f (%d valor(es)); chefe de dungeon %s (%d de %d entrada(s)); " ..
        "chefe de campo %s (%d de %d linha(s) da tabela).",
        rangeFactor, gs, dungeonLabel, dg, n, fieldLabel, fbChanged, fbRows))
end

-- ============================================================================
-- DESCOBERTA FOCADA (Ctrl+F9, só leitura)
-- ============================================================================
local NUMERIC = { IntProperty = true, FloatProperty = true, DoubleProperty = true,
                  ByteProperty = true, Int64Property = true, BoolProperty = true,
                  EnumProperty = true, NameProperty = true }

-- Escreve os campos de um valor (objeto/struct) cujo tipo é `struct`,
-- descendo em structs até `depth`. FProperty* usados só nesta chamada.
local function DumpFields(value, struct, prefix, depth, out)
    local s, guard = struct, 0
    while valid(s) and guard < 8 do
        guard = guard + 1
        pcall(function()
            s:ForEachProperty(function(prop)
                local name = prop:GetFName():ToString()
                local t = prop:GetClass():GetFName():ToString()
                if NUMERIC[t] then
                    local ok, v = pcall(function() return value[name] end)
                    out(string.format("%s%s:%s = %s", prefix, name, t, ok and str(v) or "?"))
                elseif t == "StructProperty" and depth > 0 then
                    local okS, inner = pcall(function() return prop:GetStruct() end)
                    local okV, sub = pcall(function() return value[name] end)
                    out(string.format("%s%s:%s(%s)", prefix, name, t, okS and fname(inner) or "?"))
                    if okS and okV and sub and valid(inner) then
                        DumpFields(sub, inner, prefix .. "  ", depth - 1, out)
                    end
                end
            end)
        end)
        local ok, super = pcall(function() return s:GetSuperStruct() end)
        s = ok and super or nil
    end
end

local function RunDiscovery()
    local lines = {}
    local function out(msg) lines[#lines + 1] = msg end
    out(string.format("Fast Respawn v%s - descoberta focada - %s", MOD_VERSION, os.date("%Y-%m-%d %H:%M:%S")))

    -- Campos de um objeto, incluindo para onde apontam as ObjectProperty.
    local function DumpObject(obj, prefix)
        DumpFields(obj, obj:GetClass(), prefix, 1, out)
        for name, t in pairs(PropTypes(obj:GetClass())) do
            if t == "ObjectProperty" or t == "WeakObjectProperty" then
                local ok, v = pcall(function() return obj[name] end)
                if ok and valid(v) then out(string.format("%s%s -> %s", prefix, name, fullName(v))) end
            end
        end
    end

    -- Funções (nome e parâmetros) de uma classe, filtradas por padrão.
    local function DumpFunctions(classOrPath, patterns)
        local cls = classOrPath
        if type(classOrPath) == "string" then cls = StaticFindObject(classOrPath) end
        if not valid(cls) then out("  " .. tostring(classOrPath) .. ": classe não encontrada"); return end
        local s, guard = cls, 0
        while valid(s) and guard < 6 do
            guard = guard + 1
            pcall(function()
                s:ForEachFunction(function(fn)
                    local name = fname(fn)
                    local hit = false
                    for _, p in ipairs(patterns) do if name:find(p, 1, true) then hit = true end end
                    if not hit then return end
                    local params = {}
                    pcall(function()
                        fn:ForEachProperty(function(prop)
                            local pt = prop:GetClass():GetFName():ToString()
                            if pt == "StructProperty" then
                                local okS, st = pcall(function() return prop:GetStruct() end)
                                if okS and valid(st) then pt = pt .. "(" .. fname(st) .. ")" end
                            end
                            params[#params + 1] = prop:GetFName():ToString() .. ":" .. pt
                        end)
                    end)
                    out(string.format("  %s:%s(%s)", fname(s), name, table.concat(params, ", ")))
                end)
            end)
            local ok, super = pcall(function() return s:GetSuperStruct() end)
            s = ok and super or nil
        end
    end

    -- 1. Funções de horário (achar quem devolve o GameDateTime atual).
    out("")
    out("== Funções de horário ==")
    local TIME = { "Time", "Date", "Day" }
    DumpFunctions("/Script/Pal.PalTimeManager", TIME)
    DumpFunctions("/Script/Pal.PalGameStateInGame", TIME)
    DumpFunctions("/Script/Pal.PalUtility", { "GameTime", "GameDate", "TimeManager", "RealDate" })
    DumpFunctions("/Script/Pal.PalDungeonInstanceModelFixedDungeon", TIME)

    -- 2. Ícones de chefe no mapa (abra o mapa).
    out("")
    out("== Ícones de chefe no mapa ==")
    for _, cls in ipairs({ "WBP_Map_IconBoss_C", "WBP_Map_StandAloneBossIcon_C" }) do
        pcall(function()
            local objs = FindAllOf(cls) or {}
            out(string.format("  %s: %d", cls, #objs))
            local shown = 0
            for _, w in ipairs(objs) do
                if shown >= 2 then break end
                local okV, vis = pcall(function() return w:IsVisible() end)
                if okV and vis then
                    shown = shown + 1
                    out("  -- " .. fullName(w))
                    DumpObject(w, "    ")
                    if shown == 1 then
                        out("  funções de " .. fname(w:GetClass()) .. ":")
                        DumpFunctions(w:GetClass(), { "Boss", "Respawn", "Time", "Defeat", "Dead", "Update", "Setup", "Init", "Icon" })
                    end
                end
            end
        end)
    end

    -- 3. Onde fica o estado dos chefes de campo: classes com propriedade cujo
    --    struct/nome tenha "BossSpawner".
    out("")
    out("== Estado dos chefes de campo ==")
    ForEachUObject(function(obj)
        pcall(function()
            local kind = obj:GetClass():GetFName():ToString()
            if kind ~= "Class" and kind ~= "BlueprintGeneratedClass" and kind ~= "ScriptStruct" then return end
            local hits = {}
            obj:ForEachProperty(function(prop)
                local n = prop:GetFName():ToString()
                local t = prop:GetClass():GetFName():ToString()
                local extra = ""
                if t == "StructProperty" then
                    local okS, inner = pcall(function() return prop:GetStruct() end)
                    if okS and valid(inner) then extra = fname(inner) end
                end
                if n:find("BossSpawner", 1, true) or n:find("BossRespawn", 1, true) or n:find("DefeatBoss", 1, true)
                    or n:find("BossDefeat", 1, true) or extra:find("BossSpawner", 1, true) then
                    hits[#hits + 1] = n .. ":" .. t .. (extra ~= "" and ("(" .. extra .. ")") or "")
                end
            end)
            if #hits > 0 then out("  PROP " .. fullName(obj) .. " {" .. table.concat(hits, ", ") .. "}") end
        end)
    end)

    -- 4. Dungeon derrotada: dados completos para o cálculo do tempo.
    out("")
    out("== Dungeons com chefe derrotado ==")
    for _, d in ipairs(FindAllOf("PalDungeonInstanceModelFixedDungeon") or {}) do
        pcall(function()
            if (tonumber(d.BossState) or 0) == 0 then return end
            out(string.format("  %s | BossState=%s | RespawnBossTimeAt=%s | DisappearTimeAt=%s",
                str(d.OverrideDungeonNameTextId), str(d.BossState), str(d.RespawnBossTimeAt.Ticks),
                str(d.DisappearTimeAt.Ticks)))
        end)
    end

    local dirs = modDir and { modDir } or CONFIG_DIRS
    for _, dir in ipairs(dirs) do
        local f = io.open(dir .. "discovery.txt", "w")
        if f then
            f:write(table.concat(lines, "\n"), "\n")
            f:close()
            log("Descoberta gravada em " .. dir .. "discovery.txt")
            return
        end
    end
end

-- ============================================================================
-- CRONÔMETRO NO MAPA (v0.4.0, ShowBossTimerOnMap)
-- ============================================================================
-- Ícones de chefe: WBP_Map_IconBoss_C ("Is Defeated", "Spawner Id",
-- SpawnerPosition, CanvasPanel_Boss). Ficam no GameInstance (persistem com o
-- mapa fechado): uma busca por entrada no mundo + aviso de criação.
--
-- Tempo restante (v0.4.0, estimado - "~"):
--   * o mod anota quando vê o ícone virar "derrotado" (boss_timers.txt, vale
--     entre sessões) e soma o tempo de reaparecimento:
--       - chefe de dungeon (ícone a < DUNGEON_MATCH_CM de uma dungeon):
--         60 min x DungeonBossRespawnPercent;
--       - chefe de campo: RespawnCoolTime da linha da tabela com o mesmo
--         SpawnerName x FieldBossRespawnPercent, senão 60 min x a mesma %.
--   * Para as dungeons o jogo guarda o horário exato (RespawnBossTimeAt, em
--     ticks de GameDateTime); o log registra esse valor e o relógio do jogo
--     (PalTimeManager) para calibrar a conversão na próxima versão.
--
-- O texto é um TextBlock criado dentro do CanvasPanel_Boss do ícone; o FText
-- vem do jogo (KismetTextLibrary:Conv_StringToText) - nunca montado no Lua.
local ICON_CLASS        = "WBP_Map_IconBoss_C"
local DUNGEON_MATCH_CM  = 5000
local DEFAULT_BOSS_MIN  = 60
local TIMER_FILE        = "boss_timers.txt"
local VIS_SHOW, VIS_HIDE = 3, 1   -- ESlateVisibility: HitTestInvisible / Collapsed

local icons = {}          -- [endereço] = ícone
local timerText = {}      -- [endereço do ícone] = TextBlock criado
local lastShown = {}      -- [endereço do ícone] = último texto escrito
local defeatedAt = {}     -- [Spawner Id] = os.time() em que foi visto derrotado
local dungeons = {}       -- { obj=, x=, y=, name= }
local textLib, textBlockClass = nil, nil
local timersDirty = false
local iconNotifyRegistered = false

local function TimerPath()
    return (modDir or CONFIG_DIRS[1]) .. TIMER_FILE
end

local function LoadTimers()
    local f = io.open(TimerPath(), "r")
    if not f then return end
    for line in f:lines() do
        local id, t = line:match("^([^\t]+)\t(%d+)$")
        if id then defeatedAt[id] = tonumber(t) end
    end
    f:close()
end

local function SaveTimers()
    if not timersDirty then return end
    timersDirty = false
    local f = io.open(TimerPath(), "w")
    if not f then return end
    for id, t in pairs(defeatedAt) do f:write(id, "\t", tostring(t), "\n") end
    f:close()
end

local iconCount, iconLogged = 0, false
local function TrackIcon(w)
    local addr = addressOf(w)
    if addr and not icons[addr] then
        icons[addr] = w
        iconCount = iconCount + 1
        if not iconLogged then
            iconLogged = true
            log("Cronômetro: primeiro ícone de chefe recebido (o mapa foi aberto).")
        end
    end
end

local function RefreshDungeons()
    dungeons = {}
    for _, d in ipairs(FindAllOf("PalDungeonInstanceModelFixedDungeon") or {}) do
        pcall(function()
            local loc = d.FieldWarpPointTransform.Translation
            dungeons[#dungeons + 1] = { obj = d, x = loc.X, y = loc.Y, name = str(d.OverrideDungeonNameTextId) }
        end)
    end
end

local function FindIcons()
    local list = FindAllOf(ICON_CLASS) or {}
    for _, w in ipairs(list) do TrackIcon(w) end
    -- Registra o aviso de criação com o caminho real da classe do ícone.
    if not iconNotifyRegistered and #list > 0 then
        local path = (fullName(list[1]:GetClass()):match("^%S+ (.+)$"))
        if path then
            iconNotifyRegistered = true
            pcall(NotifyOnNewObject, path, function(w) TrackIcon(w) end)
        end
    end
    return #list
end

local function NearestDungeon(x, y)
    for _, d in ipairs(dungeons) do
        local dx, dy = d.x - x, d.y - y
        if dx * dx + dy * dy < DUNGEON_MATCH_CM * DUNGEON_MATCH_CM then return d end
    end
    return nil
end

local function CooldownSeconds(icon, spawnerId)
    local okP, pos = false, nil
    if icon then okP, pos = pcall(function() return icon.SpawnerPosition end) end
    if okP and pos and NearestDungeon(pos.X, pos.Y) then
        return (dungeonMinutes > 0 and dungeonMinutes or DEFAULT_BOSS_MIN * dungeonFactor) * 60
    end
    if fieldMinutes > 0 then return fieldMinutes * 60 end
    local cool = spawnerCool[spawnerId]
    if cool and cool > 0 then return cool * fieldFactor * 60 end
    return DEFAULT_BOSS_MIN * fieldFactor * 60
end

local function FormatRemaining(sec)
    if sec <= 0 then return "~0:00" end
    local h = math.floor(sec / 3600)
    local m = math.floor((sec % 3600) / 60)
    local s = math.floor(sec % 60)
    if h > 0 then return string.format("~%d:%02d:%02d", h, m, s) end
    return string.format("~%d:%02d", m, s)
end

-- Cria (uma vez) o TextBlock do cronômetro dentro do CanvasPanel_Boss.
local function EnsureText(icon, addr)
    local tb = timerText[addr]
    if valid(tb) then return tb end
    if not textBlockClass then
        textBlockClass = StaticFindObject("/Script/UMG.TextBlock")
        if not valid(textBlockClass) then return nil end
    end
    if PropTypes(icon:GetClass())["CanvasPanel_Boss"] ~= "ObjectProperty" then return nil end
    local panel = icon.CanvasPanel_Boss
    if not valid(panel) then return nil end
    local okT, created = pcall(StaticConstructObject, textBlockClass, icon.WidgetTree)
    if not (okT and valid(created)) then return nil end
    local okS, slot = pcall(function() return panel:AddChildToCanvas(created) end)
    if okS and valid(slot) then
        pcall(function() slot:SetAutoSize(true) end)
        pcall(function() slot:SetPosition({ X = -8.0, Y = 44.0 }) end)
    end
    pcall(function() created:SetRenderScale({ X = 0.55, Y = 0.55 }) end)
    timerText[addr] = created
    return created
end

local function SetTimerText(tb, addr, text)
    if lastShown[addr] == text then return end
    if not valid(textLib) then
        textLib = StaticFindObject("/Script/Engine.Default__KismetTextLibrary")
        if not valid(textLib) then return end
    end
    tb:SetText(textLib:Conv_StringToText(text))
    pcall(function() tb:SetVisibility(VIS_SHOW) end)
    lastShown[addr] = text
end

local function HideTimer(addr)
    local tb = timerText[addr]
    if lastShown[addr] ~= nil and valid(tb) then pcall(function() tb:SetVisibility(VIS_HIDE) end) end
    lastShown[addr] = nil
end

-- Chefes de campo mortos AGORA: chaves de PalNPCManager.RespawnDisableFlag.
-- ("Is Defeated" do ícone = já derrotado alguma vez - o ✓ permanente do
-- mapa; usado na v0.4.0, marcou 69 chefes vivos como mortos.)
local npcManager = nil
local deadLogged = false
-- Devolve nil quando não dá para ler a lista (gerenciador trocado durante uma
-- recarga): o chamador pula a checagem em vez de tratar todos como "voltaram".
local nextManagerSearch = 0
local function DeadSpawners()
    local dead = {}
    if not valid(npcManager) then
        -- FindFirstOf percorre objetos: no menu (sem gerenciador) tenta só a
        -- cada 10 s.
        if os.time() < nextManagerSearch then return nil end
        nextManagerSearch = os.time() + 10
        npcManager = FindFirstOf("PalNPCManager")
        if not valid(npcManager) then return nil end
    end
    if PropTypes(npcManager:GetClass())["RespawnDisableFlag"] ~= "MapProperty" then return nil end
    local sample, total = {}, 0
    npcManager.RespawnDisableFlag:ForEach(function(k, v)
        total = total + 1
        local okK, key = pcall(function() return str(k:get()) end)
        local okV, val = pcall(function() return v:get() end)
        if okK and key then
            if not okV or (val ~= false and val ~= 0) then dead[key] = true end
            if #sample < 12 then sample[#sample + 1] = key .. "=" .. (okV and str(val) or "?") end
        end
    end)
    if not deadLogged then
        deadLogged = true
        log(string.format("Chefes de campo em espera (RespawnDisableFlag): %d - ex.: %s", total,
            table.concat(sample, ", ")))
    end
    return dead
end

-- [Spawner Id] = ícone (para saber se é de dungeon e posicionar o texto).
local iconBySpawner = {}

-- Registra mortes e voltas a partir da lista do jogo, com ou sem ícones (na
-- v0.5.1 isso só rodava depois de achar os ícones, que o jogo só cria ao
-- abrir o mapa - mortes com o mapa fechado não eram anotadas).
local function TrackDeaths(dead, now)
    for spawnerId in pairs(dead) do
        if not defeatedAt[spawnerId] then
            defeatedAt[spawnerId] = now
            timersDirty = true
            log(string.format("Chefe de campo derrotado: %s (volta em ~%.0f min).", spawnerId,
                CooldownSeconds(iconBySpawner[spawnerId], spawnerId) / 60))
        end
    end
    for spawnerId, at in pairs(defeatedAt) do
        if not dead[spawnerId] then
            log(string.format("Chefe de campo voltou: %s após %.1f min (estimativa do mod: %.1f min).",
                spawnerId, (now - at) / 60, CooldownSeconds(iconBySpawner[spawnerId], spawnerId) / 60))
            defeatedAt[spawnerId] = nil
            timersDirty = true
        end
    end
end

-- Ícones: o jogo recria os ~159 ícones a cada abertura do mapa. A v0.5.2
-- percorria todos a cada segundo lendo classe/propriedades (centenas de
-- chamadas por segundo, crescendo a cada abertura). Agora cada ícone é
-- identificado uma vez e, a cada segundo, só os ícones dos chefes mortos são
-- tocados.
local iconInfo = {}      -- [endereço] = { id =, dungeon =, nextTry = }
local iconsById = {}     -- [Spawner Id] = { [endereço] = true }
local iconHasId = nil    -- a classe do ícone tem "Spawner Id"? (checado uma vez)
local nextCleanup = 0
local shownLogged = {}    -- registra "Cronômetro exibido" uma vez por morte

local function RemoveIcon(addr)
    local info = iconInfo[addr]
    if info and info.id and iconsById[info.id] then iconsById[info.id][addr] = nil end
    icons[addr], iconInfo[addr], timerText[addr], lastShown[addr] = nil, nil, nil, nil
end

-- Identifica até `budget` ícones novos (qual chefe e se é de dungeon).
local function ResolveIcons(now, budget)
    for addr, icon in pairs(icons) do
        if budget <= 0 then return end
        local info = iconInfo[addr]
        if not info then info = { nextTry = 0 }; iconInfo[addr] = info end
        if not info.id and info.nextTry <= now then
            budget = budget - 1
            local ok = pcall(function()
                if not valid(icon) then RemoveIcon(addr); return end
                if iconHasId == nil then iconHasId = PropTypes(icon:GetClass())["Spawner Id"] == "NameProperty" end
                if not iconHasId then return end
                local id = str(icon["Spawner Id"])
                if id == "" or id == "None" then info.nextTry = now + 3; return end   -- SetBoss ainda não rodou
                info.id = id
                local okP, pos = pcall(function() return icon.SpawnerPosition end)
                info.dungeon = (okP and pos and NearestDungeon(pos.X, pos.Y)) and true or false
                iconsById[id] = iconsById[id] or {}
                iconsById[id][addr] = true
                iconBySpawner[id] = icon
            end)
            if not ok then RemoveIcon(addr) end
        end
    end
end

local function UpdateBossTimers()
    local now = os.time()
    local okD, dead = pcall(DeadSpawners)
    if not okD or dead == nil then return end
    TrackDeaths(dead, now)
    ResolveIcons(now, 40)

    -- Limpeza dos ícones descartados pelo jogo (a cada 30 s).
    if now >= nextCleanup then
        nextCleanup = now + 30
        for addr, icon in pairs(icons) do
            if not valid(icon) then RemoveIcon(addr) end
        end
    end

    -- Esconde textos de chefes que voltaram.
    for addr in pairs(lastShown) do
        local info = iconInfo[addr]
        if not (info and info.id and defeatedAt[info.id]) then HideTimer(addr) end
    end

    -- Atualiza só os ícones dos chefes mortos (dungeon: o jogo já mostra).
    for id, at in pairs(defeatedAt) do
        for addr in pairs(iconsById[id] or {}) do
            local icon = icons[addr]
            local info = iconInfo[addr]
            if not valid(icon) then
                RemoveIcon(addr)
            elseif info and not info.dungeon then
                local ok = pcall(function()
                    local remaining = at + CooldownSeconds(icon, id) - now
                    local tb = EnsureText(icon, addr)
                    if tb then
                        local logKey = id .. ":" .. tostring(at)
                        if not shownLogged[logKey] then
                            shownLogged[logKey] = true
                            log(string.format("Cronômetro exibido para %s (%s).", id, FormatRemaining(remaining)))
                        end
                        SetTimerText(tb, addr, FormatRemaining(remaining))
                    end
                end)
                if not ok then RemoveIcon(addr) end
            end
        end
    end
    SaveTimers()
end

-- Calibração: horário de volta das dungeons derrotadas x relógio do jogo.
local calibrationLogged = {}
local function LogDungeonCalibration()
    local tm = FindFirstOf("PalTimeManager")
    if not valid(tm) then return end
    local okT, day, hour, minute, second, rate = pcall(function()
        return tm:GetCurrentPalWorldTime_TotalDay(), tm:GetCurrentPalWorldTime_Hour(),
            tm:GetCurrentPalWorldTime_Minute(), tm:GetCurrentPalWorldTime_Second(), tm:GetDayTimePassRate()
    end)
    if not okT then return end
    local nowTicks = ((((day * 24) + hour) * 60 + minute) * 60 + second) * 10000000
    for _, d in ipairs(dungeons) do
        pcall(function()
            if not valid(d.obj) or (tonumber(d.obj.BossState) or 0) == 0 then return end
            local at = d.obj.RespawnBossTimeAt.Ticks
            local key = d.name .. ":" .. tostring(at)
            if calibrationLogged[key] then return end
            calibrationLogged[key] = true
            log(string.format("Calibração %s: RespawnBossTimeAt=%s relógio(dia=%d %02d:%02d:%02d, taxa=%s)=%d " ..
                "diferença=%.1f min de jogo", d.name, tostring(at), day, hour, minute, second, tostring(rate),
                nowTicks, (at - nowTicks) / 10000000 / 60))
        end)
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

rangeFactor   = 1 + ConfigNumber("SpawnRangePercent", 100, 0, 300) / 100
dungeonFactor = ConfigNumber("DungeonBossRespawnPercent", 50, 5, 100) / 100
fieldFactor   = ConfigNumber("FieldBossRespawnPercent", 50, 5, 100) / 100
dungeonMinutes = ConfigNumber("DungeonBossRespawnMinutes", 30, 0, 600)
fieldMinutes   = ConfigNumber("FieldBossRespawnMinutes", 30, 0, 600)
local interval = ConfigNumber("ScanIntervalMs", 15000, 5000, 600000)

-- O aviso pode chegar fora do game thread: só guarda a referência.
NotifyOnNewObject("/Script/Pal." .. DUNGEON_CLASS, function(obj) TrackEntrance(obj) end)

-- Troca de mapa (ex.: voltar ao menu): os objetos do mundo e os ícones são
-- destruídos. Esquece todas as referências guardadas e pausa os ciclos por
-- alguns segundos (v0.5.6: crash de 12/10/2026 ao voltar ao menu, Lua
-- acessando objeto destruído).
local mapPausedUntil = 0
if type(RegisterLoadMapPreHook) == "function" then
    RegisterLoadMapPreHook(function()
        mapPausedUntil = os.clock() + 5
        trackedEntrances, originals = {}, {}
        icons, timerText, lastShown, dungeons = {}, {}, {}, {}
        iconBySpawner, iconInfo, iconsById = {}, {}, {}
        npcManager, textLib, textBlockClass = nil, nil, nil
    end)
end

local showTimers = Config.ShowBossTimerOnMap == true
if showTimers then LoadTimers() end

-- v0.5.8: as buscas completas (4 FindAllOf) rodam só no primeiro
-- ClientRestart de cada mapa. Renascer/viajar não recria esses objetos, e o
-- crash de 13/10/2026 veio de um FindAllOf logo após um ClientRestart.
-- Entradas de dungeon novas chegam pelo NotifyOnNewObject; os ícones, pelo
-- aviso registrado ao abrir o mapa.
local worldScanned = false
if type(RegisterLoadMapPreHook) == "function" then
    RegisterLoadMapPreHook(function() worldScanned = false end)
end

RegisterHook("/Script/Engine.PlayerController:ClientRestart", function()
    ExecuteWithDelay(10000, function()
        ExecuteInGameThread(function()
            if worldScanned then
                pcall(ApplyDungeons)
                return
            end
            worldScanned = true
            local ok, err = pcall(FullScan)
            if not ok then log("Erro aplicando: " .. tostring(err)) end
            if showTimers then
                local okT, n = pcall(function() RefreshDungeons(); return FindIcons() end)
                if okT then logV(string.format("Cronômetro: %d ícone(s) de chefe, %d dungeon(s).", n, #dungeons))
                else log("Erro preparando o cronômetro: " .. tostring(n)) end
            end
        end)
    end)
end)

-- Cronômetro: atualiza os textos a cada 1 s (só percorre os ícones guardados)
-- e registra a calibração das dungeons a cada 60 s.
-- Caminhos possíveis da classe do ícone (pastas vistas no índice do pak).
local ICON_CLASS_PATHS = {
    "/Game/Pal/Blueprint/UI/WorldMap/IconWidgets/WBP_Map_IconBoss.WBP_Map_IconBoss_C",
    "/Game/Pal/Blueprint/UI/WorldMap/WBP_Map_IconBoss.WBP_Map_IconBoss_C",
    "/Game/Pal/Blueprint/UI/UserInterface/Map/WBP_Map_IconBoss.WBP_Map_IconBoss_C",
}

if showTimers then
    -- Assim que a classe do ícone existir (no máximo ao abrir o mapa), registra
    -- o aviso de criação e pega os ícones já criados com uma busca única.
    LoopAsync(2000, function()
        if iconNotifyRegistered then return true end
        ExecuteInGameThread(function()
            if iconNotifyRegistered then return end
            for _, path in ipairs(ICON_CLASS_PATHS) do
                if valid(StaticFindObject(path)) then
                    iconNotifyRegistered = true
                    pcall(NotifyOnNewObject, path, function(w) TrackIcon(w) end)
                    local okF, n = pcall(FindIcons)
                    log(string.format("Cronômetro: ícones de chefe detectados (%s ícone(s)).", okF and tostring(n) or "?"))
                    return
                end
            end
        end)
        return false
    end)

    local timerQueued, ticks = false, 0
    LoopAsync(1000, function()
        if timerQueued or os.clock() < mapPausedUntil then return false end
        timerQueued = true
        ticks = ticks + 1
        ExecuteInGameThread(function()
            local ok, err = pcall(UpdateBossTimers)
            if not ok then logV("Erro no cronômetro: " .. tostring(err)) end
            if ticks % 60 == 1 then pcall(LogDungeonCalibration) end
            timerQueued = false
        end)
        return false
    end)
end

-- Reaplica só nos objetos guardados (e no PalGameSetting, 1 objeto + CDO).
LoopAsync(interval, function()
    if os.clock() < mapPausedUntil then return false end
    ExecuteInGameThread(function()
        pcall(ApplyDungeons)
    end)
    return false
end)

RegisterKeyBind(Key.F9, { ModifierKey.CONTROL }, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(RunDiscovery)
        if not ok then log("Erro na descoberta: " .. tostring(err)) end
    end)
end)

log(string.format("v%s carregado: alcance +%d%%, chefe de dungeon %d%% do tempo.", MOD_VERSION,
    math.floor((rangeFactor - 1) * 100 + 0.5), math.floor(dungeonFactor * 100 + 0.5)))
