-- ============================================================================
-- Spawn Variety v0.2.0
-- ============================================================================
-- Grupos de Pals selvagens mais variados: cada grupo comum ganha espécies
-- extras sorteadas da MESMA planilha (região), em vez de PalSpawnNumRate, que
-- só multiplica o mesmo grupo - inclusive chefes.
--
-- Como o jogo monta os grupos (descoberto na v0.1.0, patch 2026-09-15):
--   DT_PalWildSpawner (PalWildSpawnerDatabaseRow), 1691 linhas em 422
--   planilhas (SpawnerName). Cada linha = um grupo sorteável com até 3
--   espécies: Pal_k/NPC_k, LvMin_k/LvMax_k, NumMin_k/NumMax_k (k = 1..3),
--   mais Weight, OnlyTime, OnlyWeather, SpawnerType. 180 linhas já misturam
--   espécies no jogo original.
--   Chefes: SpawnerType 2/4 e nomes BOSS_* - nunca alterados.
--   Cada spawner copia seus grupos (SpawnGroupList) ao ser criado, por isso a
--   tabela é alterada no menu principal, antes do mundo carregar.
--
-- Regras:
--   * só linhas com SpawnerType 0, sem nenhuma espécie BOSS_*, sem NPC e com
--     planilha sem "BOSS" no nome;
--   * candidatas = Pal_1 das outras linhas da mesma planilha, compatíveis em
--     OnlyTime/OnlyWeather (0 = qualquer), diferentes das que o grupo já tem;
--   * a espécie extra usa o próprio nível dela naquela planilha e
--     quantidade ExtraNumMin..ExtraNumMax;
--   * planilhas de dungeon ("dungeon" no nome) só se IncludeDungeons = true.
--
-- Alteração só na memória (some ao fechar o jogo); nada é salvo no save.
-- ============================================================================

local LOG_PREFIX  = "[SpawnVariety]"
local MOD_VERSION = "0.2.1"

local TABLE_PATH = "/Game/Pal/DataTable/Spawner/DT_PalWildSpawner.DT_PalWildSpawner"
local SLOTS = 3
local CONFIG_PATHS = { "Mods\\SpawnVariety\\config.txt", "ue4ss\\Mods\\SpawnVariety\\config.txt" }

local function log(msg)
    print(LOG_PREFIX .. " " .. tostring(msg) .. "\n")
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

-- ============================================================================
-- CONFIG
-- ============================================================================
Config = {
    Enabled              = true,
    ExtraSpeciesPerGroup = 1,     -- 0 a 2 espécies extras por grupo
    ExtraNumMin          = 1,     -- quantidade mínima de cada espécie extra
    ExtraNumMax          = 2,     -- quantidade máxima de cada espécie extra
    IncludeDungeons      = true,  -- inimigos comuns das dungeons (nunca chefes)
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

local function Clamp(n, lo, hi)
    n = math.floor(tonumber(n) or lo)
    return math.max(lo, math.min(hi, n))
end

-- ============================================================================
-- APLICAÇÃO
-- ============================================================================
local function IsEmpty(name)
    return name == nil or name == "" or name == "None" or name == "RowName"
end

local function Field(row, name)
    local ok, v = pcall(function() return row[name] end)
    if ok then return v end
    return nil
end

local function Apply(dt)
    local extra = Clamp(Config.ExtraSpeciesPerGroup, 0, 2)
    local numMin = Clamp(Config.ExtraNumMin, 1, 10)
    local numMax = Clamp(Config.ExtraNumMax, numMin, 10)
    if extra == 0 then log("ExtraSpeciesPerGroup = 0 - nada a fazer."); return end

    -- 1ª passada: linhas elegíveis e as espécies de cada planilha.
    local eligible, pools = {}, {}
    dt:ForEachRow(function(rowName, row)
        pcall(function()
            local sheet = str(Field(row, "SpawnerName"))
            if sheet:upper():find("BOSS", 1, true) then return end
            if tonumber(Field(row, "SpawnerType")) ~= 0 then return end
            if not Config.IncludeDungeons and sheet:lower():find("dungeon", 1, true) then return end
            local species, free = {}, {}
            for k = 1, SLOTS do
                local pal = str(Field(row, "Pal_" .. k))
                local npc = str(Field(row, "NPC_" .. k))
                if pal:upper():find("BOSS", 1, true) then return end   -- grupo com chefe
                if not IsEmpty(npc) then return end                     -- grupo com humano
                if IsEmpty(pal) then free[#free + 1] = k else species[pal] = true end
            end
            local pal1 = str(Field(row, "Pal_1"))
            if IsEmpty(pal1) then return end
            local entry = {
                key = str(rowName), sheet = sheet, species = species, free = free,
                time = tonumber(Field(row, "OnlyTime")) or 0,
                weather = tonumber(Field(row, "OnlyWeather")) or 0,
            }
            eligible[#eligible + 1] = entry
            pools[sheet] = pools[sheet] or {}
            table.insert(pools[sheet], {
                pal = pal1, time = entry.time, weather = entry.weather,
                lvMin = tonumber(Field(row, "LvMin_1")) or 1, lvMax = tonumber(Field(row, "LvMax_1")) or 1,
            })
        end)
    end)

    -- Sorteio: para cada linha elegível, as espécies extras de cada slot vazio.
    local plan = {}   -- [nome da linha] = { { slot =, pick = }, ... }
    local changedRows, added, noPool = 0, 0, 0
    for _, e in ipairs(eligible) do
        local candidates = {}
        local seen = {}
        for _, c in ipairs(pools[e.sheet] or {}) do
            if not e.species[c.pal] and not seen[c.pal]
                and (c.time == 0 or e.time == 0 or c.time == e.time)
                and (c.weather == 0 or e.weather == 0 or c.weather == e.weather) then
                seen[c.pal] = true
                candidates[#candidates + 1] = c
            end
        end
        if #candidates == 0 then
            noPool = noPool + 1
        else
            local n = 0
            for _, slot in ipairs(e.free) do
                if n >= extra or #candidates == 0 then break end
                local pick = table.remove(candidates, math.random(#candidates))
                plan[e.key] = plan[e.key] or {}
                table.insert(plan[e.key], { slot = slot, pick = pick })
                n = n + 1
            end
        end
    end

    -- 2ª passada pela tabela: escreve o sorteio (sem guardar referências de
    -- linha entre passadas).
    dt:ForEachRow(function(rowName, row)
        local p = plan[str(rowName)]
        if not p then return end
        local wrote = 0
        for _, item in ipairs(p) do
            local ok = pcall(function()
                local s = item.slot
                row["Pal_" .. s] = FName(item.pick.pal)
                row["LvMin_" .. s] = item.pick.lvMin
                row["LvMax_" .. s] = math.max(item.pick.lvMin, item.pick.lvMax)
                row["NumMin_" .. s] = numMin
                row["NumMax_" .. s] = numMax
            end)
            if ok then wrote = wrote + 1 end
        end
        if wrote > 0 then changedRows = changedRows + 1; added = added + wrote end
    end)
    log(string.format("Variedade aplicada: %d grupo(s) comuns ganharam %d espécie(s) extra(s) " ..
        "(%d grupo(s) elegíveis; %d sem outra espécie na mesma planilha). Chefes intocados.",
        changedRows, added, #eligible, noPool))
end

-- ============================================================================
-- DIAGNÓSTICO (Ctrl+F6): grupos reais dos spawners perto do jogador
-- ============================================================================
-- Para saber se o spawner usa a tabela alterada (lê na hora) ou uma lista
-- própria gravada no mapa: compara SpawnGroupList de spawners próximos com as
-- linhas da tabela da mesma planilha.
local function FieldList(struct)
    local list, s, guard = {}, struct, 0
    while valid(s) and guard < 8 do
        guard = guard + 1
        pcall(function()
            s:ForEachProperty(function(prop)
                list[#list + 1] = { name = prop:GetFName():ToString(), type = prop:GetClass():GetFName():ToString(), prop = prop }
            end)
        end)
        local ok, super = pcall(function() return s:GetSuperStruct() end)
        s = ok and super or nil
    end
    return list
end

-- Escreve um valor de struct (campos simples e arrays de structs), recursivo.
local function DumpStruct(value, struct, prefix, depth, out)
    for _, f in ipairs(FieldList(struct)) do
        if f.type == "ArrayProperty" and depth > 0 then
            local okI, inner = pcall(function() return f.prop:GetInner() end)
            local okS, innerStruct = false, nil
            if okI and inner then okS, innerStruct = pcall(function() return inner:GetStruct() end) end
            local okA, arr = pcall(function() return value[f.name] end)
            if okA and arr then
                local n = 0
                pcall(function()
                    arr:ForEach(function(_, elem)
                        n = n + 1
                        if okS and valid(innerStruct) then
                            out(string.format("%s%s[%d]:", prefix, f.name, n))
                            DumpStruct(elem:get(), innerStruct, prefix .. "  ", depth - 1, out)
                        else
                            out(string.format("%s%s[%d] = %s", prefix, f.name, n, str(elem:get())))
                        end
                    end)
                end)
                if n == 0 then out(prefix .. f.name .. " = []") end
            end
        elseif f.type ~= "StructProperty" and f.type ~= "ArrayProperty" and f.type ~= "MapProperty" then
            local ok, v = pcall(function() return value[f.name] end)
            local s = ok and str(v) or "?"
            if s ~= "None" and s ~= "0" and s ~= "false" and s ~= "0.0" then out(prefix .. f.name .. " = " .. s) end
        end
    end
end

local function DumpNearbySpawners()
    local lines = {}
    local function out(msg) lines[#lines + 1] = msg end
    out(string.format("Spawn Variety v%s - spawners próximos - %s", MOD_VERSION, os.date("%Y-%m-%d %H:%M:%S")))
    local player = FindFirstOf("PalPlayerCharacter")
    local okL, ploc = pcall(function() return player:K2_GetActorLocation() end)
    local near = {}
    for _, sp in ipairs(FindAllOf("BP_PalSpawner_Standard_C") or {}) do
        pcall(function()
            local loc = sp:K2_GetActorLocation()
            local d = okL and ((loc.X - ploc.X) ^ 2 + (loc.Y - ploc.Y) ^ 2) ^ 0.5 or 0
            near[#near + 1] = { sp = sp, d = d }
        end)
    end
    table.sort(near, function(a, b) return a.d < b.d end)
    local dt = StaticFindObject(TABLE_PATH)
    for i = 1, math.min(3, #near) do
        local sp = near[i].sp
        pcall(function()
            local sheet = str(sp.SpawnerName)
            out("")
            out(string.format("SPAWNER %s | planilha %s | %.0f m", sp:GetFName():ToString(), sheet, near[i].d / 100))
            local listProp
            for _, f in ipairs(FieldList(sp:GetClass())) do
                if f.name == "SpawnGroupList" then listProp = f end
            end
            if listProp then
                local okI, inner = pcall(function() return listProp.prop:GetInner() end)
                local okS, st = pcall(function() return inner:GetStruct() end)
                local n = 0
                sp.SpawnGroupList:ForEach(function(_, elem)
                    n = n + 1
                    out(string.format("  grupo %d:", n))
                    if okS and valid(st) then DumpStruct(elem:get(), st, "    ", 2, out) end
                end)
                out(string.format("  (%d grupo(s) na lista do spawner)", n))
            end
            if valid(dt) then
                out("  linhas da tabela para " .. sheet .. ":")
                dt:ForEachRow(function(rowName, row)
                    if str(row.SpawnerName) ~= sheet then return end
                    local parts = {}
                    for k = 1, SLOTS do
                        local pal = str(row["Pal_" .. k])
                        if not IsEmpty(pal) then
                            parts[#parts + 1] = string.format("%s x%s-%s", pal, str(row["NumMin_" .. k]), str(row["NumMax_" .. k]))
                        end
                    end
                    out("    " .. str(rowName) .. ": " .. table.concat(parts, " + "))
                end)
            end
        end)
    end
    for _, dir in ipairs({ "Mods\\SpawnVariety\\", "ue4ss\\Mods\\SpawnVariety\\" }) do
        local f = io.open(dir .. "spawners.txt", "w")
        if f then
            f:write(table.concat(lines, "\n"), "\n")
            f:close()
            log("Spawners próximos gravados em " .. dir .. "spawners.txt")
            return
        end
    end
end

RegisterKeyBind(Key.F6, { ModifierKey.CONTROL }, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(DumpNearbySpawners)
        if not ok then log("Erro no diagnóstico: " .. tostring(err)) end
    end)
end)

-- ============================================================================
-- INIT
-- ============================================================================
LoadConfig()
if not Config.Enabled then
    log("v" .. MOD_VERSION .. " desativado no config.txt.")
    return
end
math.randomseed(os.time())

-- Aplica uma vez, assim que a tabela existir (menu principal, antes do mundo).
local applied, tries = false, 0
LoopAsync(1000, function()
    tries = tries + 1
    ExecuteInGameThread(function()
        if applied then return end
        local dt = StaticFindObject(TABLE_PATH)
        if not valid(dt) then return end
        applied = true
        local ok, err = pcall(Apply, dt)
        if not ok then log("Erro aplicando: " .. tostring(err)) end
    end)
    return applied or tries > 120
end)

log(string.format("v%s carregado: até %d espécie(s) extra(s) por grupo comum (%d-%d cada).", MOD_VERSION,
    Clamp(Config.ExtraSpeciesPerGroup, 0, 2), Clamp(Config.ExtraNumMin, 1, 10),
    Clamp(Config.ExtraNumMax, Clamp(Config.ExtraNumMin, 1, 10), 10)))
