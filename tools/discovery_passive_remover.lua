-- ============================================================================
-- Passive Remover v0.1.0 (descoberta)
-- ============================================================================
-- Fase 1: SÓ LEITURA. Levanta como o jogo troca/remove características
-- (passivas) dos Pals, para criar a opção "Sem característica" na mesa de
-- cirurgia.
--
-- Nomes encontrados no executável (patch 2026-09-15), sem a classe dona:
--   RemovePassiveSkill, RemovePassiveSkills, ChangePassiveSkill,
--   RequestChangePassiveSkill, ConsumePassiveSkillChange, ClearAllPassiveSkills,
--   OperatingTableChangePassiveSkillIndex, DT_OperatingTablePassiveSkillDataTable
--
-- Relatório em Mods\PassiveRemover\discovery.txt (~20 s após entrar no mundo;
-- Ctrl+F7 repete - de preferência com a mesa de cirurgia aberta):
--   FUNC - funções de características/mesa: classe, nome e parâmetros
--   DT   - campos e exemplos de DT_PassiveSkill_Main,
--          DT_OperatingTablePassiveSkillDataTable e textos de nome
--   UI   - widgets visíveis com "Operating"/"Surgery"/"Passive" no nome
--
-- Segurança: só lê. FProperty* nunca ficam em cache entre execuções.
-- ============================================================================

local LOG_PREFIX  = "[PassiveRemover]"
local MOD_VERSION = "0.1.0"

local FUNC_PATTERNS = { "PassiveSkill", "OperatingTable" }
local DIRS = { "Mods\\PassiveRemover\\", "ue4ss\\Mods\\PassiveRemover\\" }

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

local function PropType(prop)
    local t = prop:GetClass():GetFName():ToString()
    if t == "StructProperty" then
        local ok, s = pcall(function() return prop:GetStruct() end)
        if ok and valid(s) then t = t .. "(" .. fname(s) .. ")" end
    end
    return t
end

-- Campos (nome:tipo) de uma struct/classe, com superclasses.
local function Fields(struct)
    local list, s, guard = {}, struct, 0
    while valid(s) and guard < 16 do
        guard = guard + 1
        pcall(function()
            s:ForEachProperty(function(prop)
                list[#list + 1] = { name = prop:GetFName():ToString(), type = PropType(prop) }
            end)
        end)
        local ok, super = pcall(function() return s:GetSuperStruct() end)
        s = ok and super or nil
    end
    return list
end

local SIMPLE = { IntProperty = true, FloatProperty = true, NameProperty = true, EnumProperty = true,
                 BoolProperty = true, ByteProperty = true, StrProperty = true, TextProperty = true }

local function RowText(row, fields)
    local parts = {}
    for _, f in ipairs(fields) do
        if SIMPLE[f.type] then
            local ok, v = pcall(function() return row[f.name] end)
            parts[#parts + 1] = f.name .. "=" .. (ok and str(v) or "?")
        end
    end
    return table.concat(parts, ", ")
end

local function DumpTable(out, dt, maxRows, filter)
    if not valid(dt) then return end
    local rs = dt.RowStruct
    local fields = Fields(rs)
    local names = {}
    for _, f in ipairs(fields) do names[#names + 1] = f.name .. ":" .. f.type end
    out("DT " .. fullName(dt))
    out("  campos: " .. table.concat(names, ", "))
    local n, shown = 0, 0
    dt:ForEachRow(function(rowName, row)
        n = n + 1
        local key = str(rowName)
        if shown < maxRows and (not filter or filter(key)) then
            shown = shown + 1
            out("  " .. key .. ": " .. RowText(row, fields))
        end
    end)
    out(string.format("  (%d linhas)", n))
end

local function Run(reason)
    local lines = {}
    local function out(msg) lines[#lines + 1] = msg end
    out(string.format("Passive Remover v%s - descoberta (%s) - %s", MOD_VERSION, reason, os.date("%Y-%m-%d %H:%M:%S")))

    -- 1. Funções de características/mesa em todas as classes carregadas.
    out("")
    out("== Funções ==")
    local tables = {}   -- DataTables de interesse, achadas pelo nome
    ForEachUObject(function(obj)
        pcall(function()
            local kind = obj:GetClass():GetFName():ToString()
            if kind == "DataTable" or kind == "CompositeDataTable" then
                local n = fname(obj)
                if n:find("PassiveSkill", 1, true) or n:find("OperatingTable", 1, true) or n:find("SkillNameText", 1, true)
                    or n:find("SkillDescText", 1, true) then
                    tables[#tables + 1] = obj
                end
                return
            end
            if kind ~= "Class" and kind ~= "BlueprintGeneratedClass" and kind ~= "WidgetBlueprintGeneratedClass" then return end
            obj:ForEachFunction(function(fn)
                local name = fname(fn)
                if not matchesAny(name, FUNC_PATTERNS) or name:find("Delegate", 1, true) then return end
                local params = {}
                pcall(function()
                    fn:ForEachProperty(function(prop)
                        params[#params + 1] = prop:GetFName():ToString() .. ":" .. PropType(prop)
                    end)
                end)
                if #params > 14 then params = { table.concat(params, ", ", 1, 14) .. ", ..." } end
                out(string.format("FUNC %s:%s(%s)", fname(obj), name, table.concat(params, ", ")))
            end)
        end)
    end)

    -- 2. Tabelas.
    out("")
    out("== Tabelas ==")
    -- Exemplos: características conhecidas (Hooligan=PAL_rude, Aggressive=
    -- PAL_oraora, Rare) e as primeiras linhas da mesa.
    local function sample(k)
        return k:find("PAL_rude", 1, true) or k:find("oraora", 1, true) or k == "Rare" or k:find("_Rare", 1, true)
    end
    for _, dt in ipairs(tables) do
        local n = fname(dt)
        pcall(DumpTable, out, dt, n:find("OperatingTable", 1, true) and 8 or 6,
            (not n:find("OperatingTable", 1, true)) and sample or nil)
    end

    -- 3. Widgets da mesa de cirurgia visíveis (abra a mesa e use Ctrl+F7).
    out("")
    out("== Widgets visíveis (mesa de cirurgia) ==")
    local counts = {}
    for _, w in ipairs(FindAllOf("UserWidget") or {}) do
        pcall(function()
            local cls = fname(w:GetClass())
            if not (cls:find("Operating", 1, true) or cls:find("Surgery", 1, true) or cls:find("Passive", 1, true)) then return end
            local okV, vis = pcall(function() return w:IsVisible() end)
            if okV and vis then counts[cls] = (counts[cls] or 0) + 1 end
        end)
    end
    for cls, n in pairs(counts) do out(string.format("UI %s x%d", cls, n)) end

    for _, dir in ipairs(DIRS) do
        local f = io.open(dir .. "discovery.txt", "w")
        if f then
            f:write(table.concat(lines, "\n"), "\n")
            f:close()
            log("Relatório gravado em " .. dir .. "discovery.txt")
            return
        end
    end
end

local done, seenAt = false, nil
LoopAsync(5000, function()
    if done then return true end
    ExecuteInGameThread(function()
        if done then return end
        if not valid(FindFirstOf("PalPlayerCharacter")) then return end
        seenAt = seenAt or os.time()
        if os.time() - seenAt < 20 then return end
        done = true
        local ok, err = pcall(Run, "automática")
        if not ok then log("Erro na descoberta: " .. tostring(err)) end
    end)
    return false
end)

RegisterKeyBind(Key.F7, { ModifierKey.CONTROL }, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(Run, "Ctrl+F7")
        if not ok then log("Erro na descoberta: " .. tostring(err)) end
    end)
end)

log(string.format("v%s carregado (descoberta, só leitura). Relatório ~20 s após entrar no mundo; Ctrl+F7 com a mesa de cirurgia aberta.", MOD_VERSION))
