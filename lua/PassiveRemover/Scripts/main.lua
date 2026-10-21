-- ============================================================================
-- Passive Remover v0.2.1
-- ============================================================================
-- Opção "Remover característica" na mesa de cirurgia.
--
-- Duas partes:
--   * PalSchema (pasta PalSchema\mods\PassiveRemover): cria a característica
--     PR_NoPassive (sem efeito, nunca sorteada) e a coloca na lista da mesa
--     (DT_OperatingTablePassiveSkillDataTable), sem implante.
--   * Este script: quando a mesa aplica PR_NoPassive num Pal, remove-a logo em
--     seguida (PalIndividualCharacterParameter:RemovePassiveSkill), deixando o
--     slot vazio. Mesmo se a remoção falhar, PR_NoPassive não tem efeito.
--
-- Funções do jogo (descobertas na v0.1.0, patch 2026-09-15):
--   PalMapObjectOperatingTableModel:RequestChangePassiveSkill(targetHandle,
--     skillIndex, PassiveSkill)          - pedido da mesa
--   PalIndividualCharacterParameter:GetPassiveSkillList() / RemovePassiveSkill(SkillId)
--
-- A busca pelos Pals (FindAllOf) só roda depois de uma cirurgia com
-- PR_NoPassive e uma vez ao entrar no mundo (limpeza) - nunca em loop.
-- ============================================================================

local LOG_PREFIX  = "[PassiveRemover]"
local MOD_VERSION = "0.2.2"

local MARKER = "PR_NoPassive"
local REQUEST_HOOK = "/Script/Pal.PalMapObjectOperatingTableModel:RequestChangePassiveSkill"
local PARAM_CLASS = "PalIndividualCharacterParameter"
local RETRIES = 6          -- tentativas de remoção após a cirurgia
local RETRY_MS = 700

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

-- Nomes das características do Pal. GetPassiveSkillList pode voltar como
-- tabela Lua (v0.2.0 tratava só TArray e nunca achava a marca) ou TArray.
local listFormatLogged = false
local function PassiveNames(param)
    local names = {}
    local ok, list = pcall(function() return param:GetPassiveSkillList() end)
    if not (ok and list) then return names end
    if not listFormatLogged then
        listFormatLogged = true
        log("Formato da lista de características: " .. type(list))
    end
    if type(list) == "table" then
        for _, v in ipairs(list) do
            local okV, s = pcall(function() return str(type(v) == "userdata" and v.get and v:get() or v) end)
            names[#names + 1] = okV and s or str(v)
        end
    else
        pcall(function()
            list:ForEach(function(_, elem) names[#names + 1] = str(elem:get()) end)
        end)
    end
    return names
end

-- true se a lista de características do Pal contém PR_NoPassive.
local function HasMarker(param)
    for _, n in ipairs(PassiveNames(param)) do
        if n == MARKER then return true end
    end
    return false
end

-- Remove PR_NoPassive de todos os Pals que a tiverem. Devolve quantos.
local function Sweep()
    local removed = 0
    for _, param in ipairs(FindAllOf(PARAM_CLASS) or {}) do
        pcall(function()
            if valid(param) and HasMarker(param) then
                param:RemovePassiveSkill(FName(MARKER))
                if not HasMarker(param) then removed = removed + 1 end
            end
        end)
    end
    return removed
end

-- Após uma cirurgia com PR_NoPassive: tenta algumas vezes (o jogo aplica a
-- troca no servidor logo depois do pedido).
-- Remove do Pal da cirurgia (handle informado pela mesa); devolve 1 se removeu.
local function RemoveFromHandle(handle)
    if not valid(handle) then return 0 end
    local ok, param = pcall(function() return handle:TryGetIndividualParameter() end)
    if not (ok and valid(param)) then return 0 end
    if not HasMarker(param) then return 0 end
    param:RemovePassiveSkill(FName(MARKER))
    return HasMarker(param) and 0 or 1
end

local function RemoveAfterSurgery(attempt, handle)
    ExecuteWithDelay(RETRY_MS, function()
        ExecuteInGameThread(function()
            local okH, h = pcall(RemoveFromHandle, handle)
            if okH and h > 0 then
                log("Característica removida do Pal da cirurgia.")
                return
            end
            local ok, n = pcall(Sweep)
            if ok and n > 0 then
                log(string.format("Característica removida (%d Pal(s)).", n))
            elseif attempt < RETRIES then
                RemoveAfterSurgery(attempt + 1, handle)
            else
                -- Diagnóstico: o que o mod enxerga no Pal da cirurgia.
                local seen = "?"
                pcall(function()
                    local okP, param = pcall(function() return handle:TryGetIndividualParameter() end)
                    if okP and valid(param) then seen = table.concat(PassiveNames(param), ", ")
                    else seen = "TryGetIndividualParameter indisponível" end
                end)
                log("Não encontrei o Pal com " .. MARKER .. " após a cirurgia (" ..
                    (ok and "nenhum" or tostring(n)) .. "); características vistas no Pal: [" .. seen ..
                    "] - será limpo ao entrar no mundo.")
            end
        end)
    end)
end

local ok, err = pcall(function()
    RegisterHook(REQUEST_HOOK, function(self, targetHandle, skillIndex, passiveSkill)
        local okN, name = pcall(function() return str(passiveSkill:get()) end)
        if okN and name == MARKER then
            local okI, idx = pcall(function() return skillIndex:get() end)
            local okT, handle = pcall(function() return targetHandle:get() end)
            log("Mesa de cirurgia: remover característica do slot " .. tostring(okI and idx or "?") .. ".")
            RemoveAfterSurgery(1, okT and handle or nil)
        end
    end)
end)
if not ok then log("Não foi possível observar a mesa de cirurgia: " .. tostring(err)) end

-- Limpeza ao entrar no mundo (ex.: cirurgia feita sem este script ativo).
-- v0.2.2: a limpeza (FindAllOf de todos os Pals) roda só no primeiro
-- ClientRestart de cada mapa (crash de 13/10/2026 num FindAllOf logo após
-- renascer); a remoção normal acontece no gancho da mesa de cirurgia.
local sweptThisMap = false
if type(RegisterLoadMapPreHook) == "function" then
    RegisterLoadMapPreHook(function() sweptThisMap = false end)
end

RegisterHook("/Script/Engine.PlayerController:ClientRestart", function()
    ExecuteWithDelay(15000, function()
        ExecuteInGameThread(function()
            if sweptThisMap then return end
            sweptThisMap = true
            local okS, n = pcall(Sweep)
            if okS and n > 0 then log(string.format("Limpeza: %s removida de %d Pal(s).", MARKER, n)) end
        end)
    end)
end)

log(string.format("v%s carregado: opção \"Remover característica\" na mesa de cirurgia.", MOD_VERSION))
