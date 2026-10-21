-- ============================================================================
-- Expedition Exp v0.4.1
-- ============================================================================
-- Ajustes nas expedições (no código do jogo: "CharacterTeamMission").
--
-- Implementado:
--   * Tempo: RequiredSeconds de cada linha de DT_CharacterTeamMissionDataTable
--     = original × ExpeditionTimePercent / 100 (0 a 200; padrão 20 = 80% menor),
--     ou, se ExpeditionFixedMinutes > 0, o mesmo tempo fixo para todas.
--     Vale para expedições iniciadas DEPOIS de aplicado: as em andamento já
--     guardam MissionCompleteDateTime no PalMapObjectCharacterTeamMissionModel.
--
-- Confirmado em jogo (07/10/2026, Sakurajima a 20%: 10:18:15 -> 10:28:27):
--   * o tempo reduzido vale;
--   * AddStartTeamMissionLog_ToServer dispara no início e
--     AddCompleteTeamMissionLog_ToClient(MissionId) no fim;
--   * CalcExpeditionBonusExp e FlushPendingExpeditionBonusExpReward NÃO
--     dispararam (não servem de sinal nem de valor de XP).
--
-- Confirmado em jogo (v0.2.2, 07/10/2026): o rastreio vê 100 Pals saírem e
-- os mesmos 100 voltarem. Não há UFunction para dar XP a um Pal específico
-- (AddExp é nativa, sem reflexão), mas há:
--   PalIndividualCharacterParameter: GetLevel(), GetExp(), IsLevelMax()
--   PalIndividualCharacterSaveParameter: Exp:Int64Property, Level:ByteProperty
--   PalExpDatabase: GetTotalExp(Level, IsPlayer), GetNextExp(Level, IsPlayer),
--                   CalcLevelFromTotalExp(TotalEXP:Int, IsPlayer)
--
-- v0.3.0 (XP dos Pals, NÃO testado):
--   Ao fim da expedição, cada Pal que voltou ganha ExpPercentOfNextLevel % do
--   XP do nível atual para o próximo. O mod soma direto em SaveParameter.Exp e
--   recalcula SaveParameter.Level com CalcLevelFromTotalExp do próprio jogo.
--   Riscos: sem animação de "subiu de nível"; atributos podem só atualizar
--   quando o Pal for recarregado. Faça backup do save antes de testar.
--
-- v0.3.1: corrigido "0 Pal(s) voltaram" (a checagem periódica esvaziava a
-- lista entre o hook de fim e a conferência).
--
-- v0.4.0 (boost de recompensas, NÃO testado): a descoberta da v0.3.0 achou
-- os itens em DT_ItemLotteryDataTable, linhas com FieldName = Expedition_*
-- (ex.: Expedition_Grass: PalSphere 5-10, CopperOre 30-50). MinNum/MaxNum
-- dessas linhas = original × (1 + RewardBoostPercent/100).
--
-- Dados confirmados pela descoberta (v0.1.2, patch 2026-09-15):
--   PalCharacterTeamMissionMasterData.RequiredSeconds:IntProperty
--   18 linhas: 1800 s (Grass/Forest), 2700 s (Volcano/Desert),
--   3600 s (Snow/Sakurajima/DarkIsland/SkyIsland/WorldTree), 7200 s (Hard).
--
-- Segurança: a existência do campo é conferida pela reflexão da struct antes
-- de qualquer leitura/escrita. O valor é sempre calculado sobre o ORIGINAL
-- guardado na primeira leitura, então reaplicar nunca acumula.
-- ============================================================================

local LOG_PREFIX  = "[ExpeditionExp]"
local MOD_VERSION = "0.4.3"

local MISSION_TABLE_PATH =
    "/Game/Pal/DataTable/CharacterTeamMission/DT_CharacterTeamMissionDataTable.DT_CharacterTeamMissionDataTable"
local MISSION_ROW_STRUCT = "/Script/Pal.PalCharacterTeamMissionMasterData"
local TIME_FIELD         = "RequiredSeconds"

local MIN_TIME_PERCENT = 0
local MAX_TIME_PERCENT = 200
-- RequiredSeconds nunca fica abaixo disto (0% vira "quase instantâneo").
local MIN_REQUIRED_SECONDS = 1
-- Tempo fixo: 0 desativa; máximo de 12 h.
local MAX_FIXED_MINUTES = 720

-- XP: % do XP do nível atual para o próximo. Até 100% = no máximo 1 nível.
local MIN_EXP_PERCENT = 0
local MAX_EXP_PERCENT = 100
-- CalcLevelFromTotalExp recebe int32.
local MAX_INT32 = 2147483647

-- Recompensas: linhas de DT_ItemLotteryDataTable com FieldName = Expedition_*
-- (confirmado na v0.3.0: campos FieldName:Name, MinNum:Int, MaxNum:Int).
local ITEM_LOTTERY_TABLE_PATH = "/Game/Pal/DataTable/Item/DT_ItemLotteryDataTable.DT_ItemLotteryDataTable"
local REWARD_FIELD_PREFIX = "Expedition_"
local MIN_REWARD_BOOST = 10
local MAX_REWARD_BOOST = 100

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
    Enabled               = true,
    ExpeditionTimePercent  = 20,
    ExpeditionFixedMinutes = 0,
    ExpPercentOfNextLevel  = 50,
    RewardBoostPercent     = 20,
    ScanIntervalMs         = 30000,
    VerboseLogging        = false,
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
    "Mods\\ExpeditionExp\\config.txt",
    "Mods/ExpeditionExp/config.txt",
    "ue4ss\\Mods\\ExpeditionExp\\config.txt",
    "ue4ss/Mods/ExpeditionExp/config.txt",
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
-- usuário pode escrever vírgula decimal ("12,5").
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
-- TEMPO DA EXPEDIÇÃO
-- ============================================================================
local timePercent = 20
local fixedSeconds = 0         -- > 0: todas as expedições com este tempo
local timeFieldChecked = nil   -- nil = não conferido; true/false = existe ou não
local originalSeconds = {}     -- [nome da linha] = RequiredSeconds original
local timeReported = false

local function TimeFieldExists()
    if timeFieldChecked ~= nil then return timeFieldChecked end
    timeFieldChecked = false
    pcall(function()
        local rowStruct = StaticFindObject(MISSION_ROW_STRUCT)
        if not (rowStruct and rowStruct:IsValid()) then return end
        rowStruct:ForEachProperty(function(prop)
            if prop:GetFName():ToString() == TIME_FIELD
                and prop:GetClass():GetFName():ToString() == "IntProperty" then
                timeFieldChecked = true
            end
        end)
    end)
    if not timeFieldChecked then
        log(MISSION_ROW_STRUCT .. "." .. TIME_FIELD .. " (IntProperty) não encontrado - tempo não alterado.")
    end
    return timeFieldChecked
end

-- ============================================================================
-- BOOST DE RECOMPENSAS
-- ============================================================================
-- MinNum/MaxNum das linhas Expedition_* = original × (1 + boost/100),
-- arredondado e nunca abaixo do original. Sempre a partir do original.
local rewardBoost = 20
local rewardFieldsChecked = nil       -- nil = não conferido; true/false
local originalRewards = {}            -- [nome da linha] = { min =, max = }
local rewardReported = false
local hasStaticItemId = false          -- StaticItemId:NameProperty (para o log)

local function RewardFieldsExist(dt)
    if rewardFieldsChecked ~= nil then return rewardFieldsChecked end
    rewardFieldsChecked = false
    pcall(function()
        local rowStruct = dt.RowStruct
        if not (rowStruct and rowStruct:IsValid()) then return end
        local types = {}
        rowStruct:ForEachProperty(function(prop)
            types[prop:GetFName():ToString()] = prop:GetClass():GetFName():ToString()
        end)
        rewardFieldsChecked = types["FieldName"] == "NameProperty"
            and types["MinNum"] == "IntProperty" and types["MaxNum"] == "IntProperty"
        hasStaticItemId = types["StaticItemId"] == "NameProperty"
    end)
    if not rewardFieldsChecked then
        log("DT_ItemLotteryDataTable sem FieldName/MinNum/MaxNum esperados - recompensas não alteradas.")
    end
    return rewardFieldsChecked
end

local function Boosted(value)
    return math.max(value, math.floor(value * (1 + rewardBoost / 100) + 0.5))
end

-- ItemFieldLotteryName da expedição (ex.: DUNGEON_SAKURAJIMA ->
-- Expedition_Sakurajima), lido da linha da tabela de expedições.
local function MissionLotteryName(missionId)
    local hasField = false
    pcall(function()
        local rowStruct = StaticFindObject(MISSION_ROW_STRUCT)
        rowStruct:ForEachProperty(function(prop)
            if prop:GetFName():ToString() == "ItemFieldLotteryName"
                and prop:GetClass():GetFName():ToString() == "NameProperty" then
                hasField = true
            end
        end)
    end)
    if not hasField then return nil end
    local dt = StaticFindObject(MISSION_TABLE_PATH)
    if not (dt and dt:IsValid()) then return nil end
    local lottery = nil
    dt:ForEachRow(function(rowName, row)
        local name = tostring(rowName)
        pcall(function() name = rowName:ToString() end)
        if name == missionId then lottery = row.ItemFieldLotteryName:ToString() end
    end)
    return lottery
end

-- Grava as faixas (original -> com boost) dos itens da expedição concluída,
-- para comparar com o que o jogador recebeu.
local function LogRewardRanges(missionId)
    local lottery = MissionLotteryName(missionId)
    if not lottery then
        log("Faixas de itens: sorteio da expedição " .. tostring(missionId) .. " não encontrado.")
        return
    end
    local dt = StaticFindObject(ITEM_LOTTERY_TABLE_PATH)
    if not (dt and dt:IsValid()) or not RewardFieldsExist(dt) then return end
    local parts = {}
    dt:ForEachRow(function(rowName, row)
        if row.FieldName:ToString() ~= lottery then return end
        local name = tostring(rowName)
        pcall(function() name = rowName:ToString() end)
        local item = hasStaticItemId and row.StaticItemId:ToString() or name
        local orig = originalRewards[name] or { min = row.MinNum, max = row.MaxNum }
        table.insert(parts, string.format("%s %d-%d -> %d-%d",
            item, orig.min, orig.max, row.MinNum, row.MaxNum))
    end)
    log(string.format("Faixas de itens de %s (%s, +%s%%; o jogo ainda aplica o seu \"Prêmio %%\"): %s",
        tostring(missionId), lottery, tostring(rewardBoost), table.concat(parts, "; ")))
end

local function ApplyRewardBoost()
    local dt = StaticFindObject(ITEM_LOTTERY_TABLE_PATH)
    if not (dt and dt:IsValid()) then
        logV("Tabela de itens ainda não carregada.")
        return
    end
    if not RewardFieldsExist(dt) then return end

    local changed, fields = 0, {}
    dt:ForEachRow(function(rowName, row)
        local field = row.FieldName:ToString()
        if field:sub(1, #REWARD_FIELD_PREFIX) ~= REWARD_FIELD_PREFIX then return end
        local name = tostring(rowName)
        pcall(function() name = rowName:ToString() end)
        local orig = originalRewards[name]
        if not orig then
            orig = { min = row.MinNum, max = row.MaxNum }
            originalRewards[name] = orig
        end
        local newMin, newMax = Boosted(orig.min), Boosted(orig.max)
        if row.MinNum ~= newMin or row.MaxNum ~= newMax then
            row.MinNum = newMin
            row.MaxNum = newMax
            changed = changed + 1
            fields[field] = true
        end
    end)

    if changed > 0 then
        if not rewardReported then
            rewardReported = true
            local names = {}
            for f in pairs(fields) do table.insert(names, f) end
            table.sort(names)
            log(string.format("Recompensas +%s%% em %d linha(s) de %d expedição(ões): %s",
                tostring(rewardBoost), changed, #names, table.concat(names, ", ")))
        else
            logV(string.format("Recompensas reaplicadas em %d linha(s).", changed))
        end
    end
end

local function ApplyExpeditionTime()
    if not TimeFieldExists() then return end
    local dt = StaticFindObject(MISSION_TABLE_PATH)
    if not (dt and dt:IsValid()) then
        logV("Tabela de expedições ainda não carregada.")
        return
    end

    local changed, summary = 0, {}
    dt:ForEachRow(function(rowName, row)
        local name = tostring(rowName)
        pcall(function() name = rowName:ToString() end)
        local current = row[TIME_FIELD]
        if type(current) ~= "number" then return end
        if originalSeconds[name] == nil then originalSeconds[name] = current end
        local target
        if fixedSeconds > 0 then
            target = fixedSeconds
        else
            target = math.max(MIN_REQUIRED_SECONDS,
                math.floor(originalSeconds[name] * timePercent / 100 + 0.5))
        end
        if current ~= target then
            row[TIME_FIELD] = target
            changed = changed + 1
            table.insert(summary, string.format("%s %d->%d", name, originalSeconds[name], target))
        end
    end)

    if changed > 0 then
        if not timeReported then
            timeReported = true
            local mode = fixedSeconds > 0
                and string.format("fixo de %d s", fixedSeconds)
                or (tostring(timePercent) .. "% do original")
            log(string.format("Tempo das expedições = %s (%d linha(s)): %s",
                mode, changed, table.concat(summary, ", ")))
        else
            logV(string.format("Tempo reaplicado em %d linha(s).", changed))
        end
    end
end

-- ============================================================================
-- SAVE DO PAL
-- ============================================================================
-- Campos Exp/Level confirmados pela descoberta da v0.2.2.
local EXP_SAVE_STRUCT = "/Script/Pal.PalIndividualCharacterSaveParameter"

-- ============================================================================
-- RASTREIO DOS PALS EM EXPEDIÇÃO (só log) — quem volta quando ela termina
-- ============================================================================
-- IsAssignedToExpedition() é uma UFunction sem parâmetros (confirmada na
-- v0.1.1). O conjunto é atualizado no início da expedição, periodicamente e
-- logo depois do fim; quem sai do conjunto após o fim é quem voltou.
local assignedPals = {}   -- [nome completo] = true
local RETURN_CHECK_DELAY_MS = 3000
-- v0.4.3: 5 min (era 1 min). FindAllOf de todos os parâmetros de Pal pesa no
-- Lua; o gancho de início da expedição já atualiza a lista na hora.
local ASSIGNED_POLL_MS = 300000

-- Todos os PalIndividualCharacterParameter vivos: [nome completo] = objeto.
local function AllPalParams()
    local all = {}
    for _, param in ipairs(FindAllOf("PalIndividualCharacterParameter") or {}) do
        pcall(function()
            if not param:IsValid() then return end
            local name = param:GetFullName()
            if not name:find("Default__") then all[name] = param end
        end)
    end
    return all
end

local function CollectAssignedPals()
    local current = {}
    for name, param in pairs(AllPalParams()) do
        pcall(function()
            if param:IsAssignedToExpedition() then current[name] = true end
        end)
    end
    return current
end

-- ============================================================================
-- XP DOS PALS QUE VOLTARAM
-- ============================================================================
local expPercent = 50
local saveFieldsChecked = nil   -- nil = não conferido; true/false

-- SaveParameter (struct) com Exp:Int64Property e Level:ByteProperty.
local function SaveFieldsExist(param)
    if saveFieldsChecked ~= nil then return saveFieldsChecked end
    saveFieldsChecked = false
    pcall(function()
        local hasSave = false
        local class = param:GetClass()
        while class and class:IsValid() and not hasSave do
            class:ForEachProperty(function(prop)
                if prop:GetFName():ToString() == "SaveParameter" then hasSave = true end
            end)
            class = class:GetSuperStruct()
        end
        if not hasSave then return end
        local saveStruct = StaticFindObject(EXP_SAVE_STRUCT)
        if not (saveStruct and saveStruct:IsValid()) then return end
        local types = {}
        saveStruct:ForEachProperty(function(prop)
            types[prop:GetFName():ToString()] = prop:GetClass():GetFName():ToString()
        end)
        saveFieldsChecked = types["Exp"] == "Int64Property" and types["Level"] == "ByteProperty"
    end)
    if not saveFieldsChecked then
        log("SaveParameter.Exp/Level não encontrados com os tipos esperados - XP desativado.")
    end
    return saveFieldsChecked
end

local function GetExpDatabase()
    local db = FindFirstOf("PalExpDatabase")
    if db and db:IsValid() then return db end
    return nil
end

-- XP do nível atual para o próximo (GetTotalExp(L+1) - GetTotalExp(L)).
local function ExpToNextLevel(db, level)
    local current = tonumber(db:GetTotalExp(level, false))
    local nextTotal = tonumber(db:GetTotalExp(level + 1, false))
    if current and nextTotal and nextTotal > current then
        return nextTotal - current
    end
    local fallback = tonumber(db:GetNextExp(level, false))
    if fallback and fallback > 0 then return fallback end
    return nil
end

-- Dá o XP a um Pal. Retorna "subiu", "xp", "max" ou nil (pulado).
local function GrantExp(db, param)
    if param:IsLevelMax() then return "max" end
    local level = tonumber(param:GetLevel())
    local exp = tonumber(param:GetExp())
    if not (level and exp and level > 0) then return nil end

    local need = ExpToNextLevel(db, level)
    if not need then return nil end
    local gain = math.floor(need * expPercent / 100)
    if gain <= 0 then return nil end

    local newExp = exp + gain
    if newExp > MAX_INT32 then return nil end
    local newLevel = tonumber(db:CalcLevelFromTotalExp(newExp, false)) or level
    -- Nunca desce de nível nem pula mais de um por expedição.
    newLevel = math.max(level, math.min(level + 1, newLevel))

    local save = param.SaveParameter
    save.Exp = newExp
    if newLevel > level then save.Level = newLevel end

    -- Confere pela leitura do jogo (a struct precisa ser referência, não cópia).
    local readExp = tonumber(param:GetExp())
    if readExp ~= newExp then
        log(string.format("XP não aplicado (lido %s, esperado %d) - verifique o UE4SS.", tostring(readExp), newExp))
        return nil
    end
    logV(string.format("  Lv%d +%d XP%s", level, gain, newLevel > level and (" -> Lv" .. newLevel) or ""))
    return newLevel > level and "subiu" or "xp"
end

local function GrantExpToReturned(returnedParams)
    if expPercent <= 0 or #returnedParams == 0 then return end
    if not SaveFieldsExist(returnedParams[1]) then return end
    local db = GetExpDatabase()
    if not db then
        log("PalExpDatabase não encontrado - XP não aplicado.")
        return
    end
    local counts = { xp = 0, subiu = 0, max = 0, skipped = 0 }
    for _, param in ipairs(returnedParams) do
        local ok, result = pcall(GrantExp, db, param)
        if not ok then
            counts.skipped = counts.skipped + 1
            log("Erro dando XP: " .. tostring(result))
        elseif result then
            counts[result] = counts[result] + 1
        else
            counts.skipped = counts.skipped + 1
        end
    end
    log(string.format("XP (%s%% do próximo nível): %d ganharam XP, %d subiram de nível, %d já no máximo, %d pulados.",
        tostring(expPercent), counts.xp + counts.subiu, counts.subiu, counts.max, counts.skipped))
end

local function CountKeys(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local lastAssignedCount = -1

-- Última vez (os.time, em s) que cada Pal foi visto em expedição. A checagem
-- periódica só atualiza/acrescenta; nunca apaga. Bug da v0.3.0: ela rodou
-- entre o hook de fim e a conferência, esvaziou a lista e "0 Pal(s) voltaram".
local assignedSeenAt = {}
-- Candidatos ao retorno: vistos em expedição até este tempo antes do fim.
local RETURN_WINDOW_S = math.floor(ASSIGNED_POLL_MS / 1000) + 120
-- Registros mais velhos que isto são descartados.
local SEEN_PRUNE_S = 3600

-- Só grava no log quando o número muda (a checagem periódica é a cada minuto).
local function RefreshAssigned(reason)
    assignedPals = CollectAssignedPals()
    local now = os.time()
    for name in pairs(assignedPals) do assignedSeenAt[name] = now end
    for name, seenAt in pairs(assignedSeenAt) do
        if now - seenAt > SEEN_PRUNE_S then assignedSeenAt[name] = nil end
    end
    local count = CountKeys(assignedPals)
    if count ~= lastAssignedCount then
        lastAssignedCount = count
        log("Pals em expedição (" .. reason .. "): " .. count)
    end
end

local function OnExpeditionComplete(missionId)
    local hookTime = os.time()
    ExecuteWithDelay(RETURN_CHECK_DELAY_MS, function()
        ExecuteInGameThread(function()
            local ok, err = pcall(function()
                local all = AllPalParams()
                local current = CollectAssignedPals()
                local returned = {}
                -- Voltou = visto em expedição há pouco e não está mais em uma
                -- (Pals de outra expedição ainda em andamento continuam em current).
                for name, seenAt in pairs(assignedSeenAt) do
                    if hookTime - seenAt <= RETURN_WINDOW_S and not current[name] and all[name] then
                        table.insert(returned, all[name])
                        assignedSeenAt[name] = nil
                    end
                end
                log(string.format("Expedição %s concluída: %d Pal(s) voltaram.",
                    tostring(missionId), #returned))
                assignedPals = current
                lastAssignedCount = CountKeys(current)
                GrantExpToReturned(returned)
            end)
            if not ok then log("Erro rastreando o retorno: " .. tostring(err)) end
            local ok2, err2 = pcall(LogRewardRanges, missionId)
            if not ok2 then log("Erro listando as faixas de itens: " .. tostring(err2)) end
        end)
    end)
end

-- ============================================================================
-- HOOKS
-- ============================================================================
local START_HOOK    = "/Script/Pal.PalNetworkMapObjectComponent:AddStartTeamMissionLog_ToServer"
local COMPLETE_HOOK = "/Script/Pal.PalNetworkMapObjectComponent:AddCompleteTeamMissionLog_ToClient"

local function RegisterHooks()
    -- Confirmado em jogo (07/10/2026): dispara quando a expedição começa.
    RegisterHook(START_HOOK, function()
        log("HOOK expedição iniciada.")
        ExecuteWithDelay(RETURN_CHECK_DELAY_MS, function()
            ExecuteInGameThread(function()
                pcall(RefreshAssigned, "após início")
            end)
        end)
    end)

    -- Confirmado em jogo (07/10/2026): dispara quando a expedição termina.
    -- Parâmetro: MissionId (FName).
    RegisterHook(COMPLETE_HOOK, function(Context, MissionIdArg)
        local missionId = "?"
        pcall(function() missionId = MissionIdArg:get():ToString() end)
        log("HOOK expedição concluída: " .. missionId)
        OnExpeditionComplete(missionId)
    end)

    -- v0.4.2: os ganchos de observação (PROBE_HOOKS) foram removidos. Um deles,
    -- BP_PalGameSetting_C:CalcExpeditionBonusExp, é função de blueprint com
    -- valor de retorno - gancho do UE4SS 3.0.1 nesse tipo de função derrubou
    -- o jogo (crashes de 11/10/2026 logo após "HOOK CalcExpeditionBonusExp
    -- disparou"). Só os ganchos de início/fim, que são do C++, ficam.
end

-- ============================================================================
-- INIT
-- ============================================================================
LoadConfig()

if not Config.Enabled then
    log("v" .. MOD_VERSION .. " desativado no config.txt.")
    return
end

timePercent = ConfigNumber("ExpeditionTimePercent", 20, MIN_TIME_PERCENT, MAX_TIME_PERCENT)
local fixedMinutes = ConfigNumber("ExpeditionFixedMinutes", 0, 0, MAX_FIXED_MINUTES)
if fixedMinutes > 0 then
    fixedSeconds = math.max(MIN_REQUIRED_SECONDS, math.floor(fixedMinutes * 60 + 0.5))
end
expPercent = ConfigNumber("ExpPercentOfNextLevel", 50, MIN_EXP_PERCENT, MAX_EXP_PERCENT)
rewardBoost = ConfigNumber("RewardBoostPercent", 20, MIN_REWARD_BOOST, MAX_REWARD_BOOST)
local scanInterval = ConfigNumber("ScanIntervalMs", 30000, 5000, 600000)

-- Reaplica periodicamente: a tabela pode ser carregada depois do mod ou
-- recarregada pelo jogo. Como o cálculo usa o original, não acumula.
-- v0.4.3: depois da primeira aplicação completa, só confere a cada
-- REAPPLY_AFTER_OK_S (ForEachRow na tabela de itens a cada 30 s era pesado).
local REAPPLY_AFTER_OK_S = 600
local lastFullApply = nil
LoopAsync(scanInterval, function()
    if lastFullApply and os.time() - lastFullApply < REAPPLY_AFTER_OK_S then return false end
    ExecuteInGameThread(function()
        local ok, err = pcall(ApplyExpeditionTime)
        if not ok then log("Erro ajustando o tempo: " .. tostring(err)) end
        local ok2, err2 = pcall(ApplyRewardBoost)
        if not ok2 then log("Erro ajustando as recompensas: " .. tostring(err2)) end
        if ok and ok2 and next(originalSeconds) ~= nil and next(originalRewards) ~= nil then
            lastFullApply = os.time()
        end
    end)
    return false
end)

local hooksRegistered = false
LoopAsync(5000, function()
    if hooksRegistered then return true end
    hooksRegistered = true
    ExecuteInGameThread(function()
        local ok, err = pcall(RegisterHooks)
        if not ok then log("Erro registrando hooks: " .. tostring(err)) end
    end)
    return true
end)

-- Mantém o conjunto de Pals em expedição atualizado (ex.: expedições que já
-- estavam em andamento quando o jogo abriu).
LoopAsync(ASSIGNED_POLL_MS, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(RefreshAssigned, "periódico")
        if not ok then log("Erro listando Pals em expedição: " .. tostring(err)) end
    end)
    return false
end)

local timeText = fixedSeconds > 0
    and string.format("tempo fixo de %s min para todas", tostring(fixedMinutes))
    or string.format("tempo = %s%% do original", tostring(timePercent))
log(string.format("v%s carregado: %s; XP = %s%% do próximo nível; recompensas +%s%%.",
    MOD_VERSION, timeText, tostring(expPercent), tostring(rewardBoost)))
