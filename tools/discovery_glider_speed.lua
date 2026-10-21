-- ============================================================================
-- Glider Speed v0.1.0 (descoberta)
-- ============================================================================
-- Fase 1: SÓ LEITURA. Levanta onde o jogo guarda a velocidade dos planadores
-- (itens e Pals planadores) e quais são os valores padrão.
--
-- Nomes encontrados no executável (patch 2026-09-15), sem a classe dona:
--   GliderMaxSpeed, GliderSpeed, GliderAirControl, GliderGravityScale,
--   ApplyGliderParameter, UPalGliderComponent, CurrentGlider,
--   Relic_GliderSpeed, GliderPalInfos
--
-- Relatórios em Mods\GliderSpeed\:
--   discovery.txt - ~20 s após entrar no mundo: classes/structs com "Glid",
--                   valores padrão (CDO, inclusive BP_*) e DataTables.
--   gliding.txt   - Ctrl+F8 DURANTE o voo: componente de planador do
--                   jogador, planador atual e campos de velocidade do
--                   movimento do personagem naquele instante.
--
-- Segurança: só lê propriedades que a reflexão confirmou existirem. FProperty*
-- nunca ficam em cache entre execuções (blueprints podem ser descarregados).
-- ============================================================================

local LOG_PREFIX  = "[GliderSpeed]"
local MOD_VERSION = "0.1.0"

local PATTERNS = { "Glid" }
local MOVE_PATTERNS = { "Speed", "Glid", "Gravity", "Air", "Fall", "Fly", "Accel", "Velocity", "Friction" }
local NUMERIC = { IntProperty = true, FloatProperty = true, DoubleProperty = true,
                  ByteProperty = true, BoolProperty = true, EnumProperty = true, NameProperty = true }

local DIRS = { "Mods\\GliderSpeed\\", "ue4ss\\Mods\\GliderSpeed\\" }

-- ============================================================================
-- UTILITÁRIOS
-- ============================================================================
local function log(msg)
    print(LOG_PREFIX .. " " .. tostring(msg) .. "\n")
end

local function valid(obj)
    if not obj then return false end
    local ok, v = pcall(function() return obj:IsValid() end)
    return ok and v
end

local function str(v)
    if type(v) == "number" and math.type(v) == "float" then return string.format("%.3f", v) end
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

local function matchesAny(name, list)
    for _, p in ipairs(list) do
        if name:find(p, 1, true) then return true end
    end
    return false
end

-- Percorre as propriedades (com superclasses) chamando fn(name, type, prop).
local function EachProp(struct, fn)
    local s, guard = struct, 0
    while valid(s) and guard < 32 do
        guard = guard + 1
        pcall(function()
            s:ForEachProperty(function(prop)
                fn(prop:GetFName():ToString(), prop:GetClass():GetFName():ToString(), prop)
            end)
        end)
        local ok, super = pcall(function() return s:GetSuperStruct() end)
        s = ok and super or nil
    end
end

-- Campos de `value` (tipo `struct`) que passam em `filter`, descendo em structs.
local function DumpFields(value, struct, prefix, depth, filter, out)
    EachProp(struct, function(name, t, prop)
        if NUMERIC[t] then
            if filter(name) then
                local ok, v = pcall(function() return value[name] end)
                out(string.format("%s%s:%s = %s", prefix, name, t, ok and str(v) or "?"))
            end
        elseif t == "StructProperty" and depth > 0 then
            local okS, inner = pcall(function() return prop:GetStruct() end)
            if not (okS and valid(inner)) then return end
            local any = false
            EachProp(inner, function(n2) if filter(n2) or filter(name) then any = true end end)
            if not any then return end
            local okV, sub = pcall(function() return value[name] end)
            out(string.format("%s%s:%s(%s)", prefix, name, t, fname(inner)))
            if okV and sub then
                local subFilter = filter(name) and function() return true end or filter
                DumpFields(sub, inner, prefix .. "  ", depth - 1, subFilter, out)
            end
        elseif t == "ObjectProperty" and filter(name) then
            local ok, v = pcall(function() return value[name] end)
            out(string.format("%s%s:%s -> %s", prefix, name, t, (ok and valid(v)) and fullName(v) or "nil"))
        end
    end)
end

local function Write(fileName, lines)
    for _, dir in ipairs(DIRS) do
        local f = io.open(dir .. fileName, "w")
        if f then
            f:write(table.concat(lines, "\n"), "\n")
            f:close()
            log("Relatório gravado em " .. dir .. fileName)
            return
        end
    end
end

local function GliderName(name) return matchesAny(name, PATTERNS) end

-- ============================================================================
-- 1. DESCOBERTA GERAL (automática)
-- ============================================================================
local function RunDiscovery()
    local lines = {}
    local function out(msg) lines[#lines + 1] = msg end
    out(string.format("Glider Speed v%s - descoberta - %s", MOD_VERSION, os.date("%Y-%m-%d %H:%M:%S")))
    out("")

    local dataTables, cdos = {}, {}
    ForEachUObject(function(obj)
        pcall(function()
            local kind = obj:GetClass():GetFName():ToString()
            local name = obj:GetFName():ToString()
            if kind == "Class" or kind == "ScriptStruct" or kind == "BlueprintGeneratedClass" then
                local parts = {}
                obj:ForEachProperty(function(prop)
                    local n = prop:GetFName():ToString()
                    if GliderName(n) then parts[#parts + 1] = n .. ":" .. prop:GetClass():GetFName():ToString() end
                end)
                if #parts > 0 or (kind ~= "ScriptStruct" and GliderName(name)) then
                    out("PROP " .. obj:GetFullName() .. " {" .. table.concat(parts, ", ") .. "}")
                end
            elseif kind == "DataTable" or kind == "CompositeDataTable" then
                dataTables[#dataTables + 1] = obj
            elseif name:sub(1, 9) == "Default__" then
                local clsName = fname(obj:GetClass())
                if GliderName(clsName) then
                    cdos[#cdos + 1] = obj
                else
                    local has = false
                    EachProp(obj:GetClass(), function(n) if GliderName(n) then has = true end end)
                    if has then cdos[#cdos + 1] = obj end
                end
            end
        end)
    end)

    out("")
    out("== Valores padrão (CDO) ==")
    for _, cdo in ipairs(cdos) do
        pcall(function()
            local cls = cdo:GetClass()
            out("CDO " .. fullName(cls))
            local glider = GliderName(fname(cls))
            DumpFields(cdo, cls, "    ", 1, function(n)
                return glider and matchesAny(n, MOVE_PATTERNS) or GliderName(n)
            end, out)
        end)
    end

    out("")
    out("== DataTables com campos de planador ==")
    for _, dt in ipairs(dataTables) do
        pcall(function()
            local rs = dt.RowStruct
            if not valid(rs) then return end
            local has = false
            EachProp(rs, function(n) if GliderName(n) or matchesAny(n, { "Speed" }) and GliderName(fname(dt)) then has = true end end)
            if not has and not GliderName(fname(dt)) then return end
            out("DT " .. fullName(dt) .. " (linha: " .. fname(rs) .. ")")
            local n = 0
            dt:ForEachRow(function(rowName, row)
                n = n + 1
                if n > 40 then return end
                local parts = {}
                EachProp(rs, function(name, t)
                    if (t == "FloatProperty" or t == "IntProperty" or t == "DoubleProperty")
                        and (GliderName(name) or matchesAny(name, MOVE_PATTERNS)) then
                        local ok, v = pcall(function() return row[name] end)
                        parts[#parts + 1] = name .. "=" .. (ok and str(v) or "?")
                    end
                end)
                if #parts > 0 then out("DT   " .. str(rowName) .. ": " .. table.concat(parts, ", ")) end
            end)
            if n > 40 then out(string.format("DT   ... (%d linhas)", n)) end
        end)
    end
    Write("discovery.txt", lines)
end

-- ============================================================================
-- 2. DURANTE O VOO (Ctrl+F8)
-- ============================================================================
local function RunGliding()
    local lines = {}
    local function out(msg) lines[#lines + 1] = msg end
    out(string.format("Glider Speed v%s - durante o voo - %s", MOD_VERSION, os.date("%Y-%m-%d %H:%M:%S")))

    local player = FindFirstOf("PalPlayerCharacter")
    if not valid(player) then out("Personagem não encontrado."); Write("gliding.txt", lines); return end
    out("Personagem: " .. fullName(player))

    out("")
    out("== Componentes do personagem com 'Glid' ==")
    for _, comp in ipairs(FindAllOf("PalGliderComponent") or {}) do
        pcall(function()
            local okO, owner = pcall(function() return comp:GetOwner() end)
            if okO and valid(owner) and owner:GetAddress() ~= player:GetAddress() then return end
            out("COMP " .. fullName(comp))
            DumpFields(comp, comp:GetClass(), "    ", 2, function() return true end, out)
            -- Só lê CurrentGlider se a reflexão confirmar que existe (ler
            -- propriedade inexistente causa ACCESS_VIOLATION mesmo em pcall).
            local hasCurrent = false
            EachProp(comp:GetClass(), function(n, t) if n == "CurrentGlider" and t == "ObjectProperty" then hasCurrent = true end end)
            local okG, glider = false, nil
            if hasCurrent then okG, glider = pcall(function() return comp.CurrentGlider end) end
            if okG and valid(glider) then
                out("  CurrentGlider " .. fullName(glider))
                DumpFields(glider, glider:GetClass(), "      ", 1, function(n) return matchesAny(n, MOVE_PATTERNS) end, out)
            end
        end)
    end

    out("")
    out("== Movimento do personagem (campos de velocidade/gravidade/ar) ==")
    pcall(function()
        local mv = player.CharacterMovement
        if valid(mv) then
            out("MOVE " .. fullName(mv))
            DumpFields(mv, mv:GetClass(), "    ", 1, function(n) return matchesAny(n, MOVE_PATTERNS) end, out)
        else
            out("CharacterMovement indisponível")
        end
    end)
    Write("gliding.txt", lines)
end

-- ============================================================================
-- INIT
-- ============================================================================
local done, seenAt = false, nil
LoopAsync(5000, function()
    if done then return true end
    ExecuteInGameThread(function()
        if done then return end
        if not valid(FindFirstOf("PalPlayerCharacter")) then return end
        seenAt = seenAt or os.time()
        if os.time() - seenAt < 20 then return end
        done = true
        local ok, err = pcall(RunDiscovery)
        if not ok then log("Erro na descoberta: " .. tostring(err)) end
    end)
    return false
end)

RegisterKeyBind(Key.F8, { ModifierKey.CONTROL }, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(RunGliding)
        if not ok then log("Erro no relatório de voo: " .. tostring(err)) end
    end)
end)

log(string.format("v%s carregado (descoberta, só leitura). Relatório ~20 s após entrar no mundo; Ctrl+F8 durante o voo.", MOD_VERSION))
