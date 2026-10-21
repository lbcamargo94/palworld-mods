# Expedition Exp

Ajustes nas expedições do Palworld. Mod Lua para UE4SS: não substitui arquivos do jogo.

**Status:** v0.4.1. Tempo das expedições implementado (ainda não testado em jogo). XP dos Pals e boost de recompensas planejados.

---

## Funcionalidades

| Feature | Config | Padrão | Status |
| --- | --- | --- | --- |
| Tempo da expedição | `ExpeditionTimePercent` (0 a 200) | `20` (80% menor) | ✅ testado (v0.2.1) |
| Tempo igual para todas | `ExpeditionFixedMinutes` (0 a 720) | `0` (desativado) | 🧪 v0.2.1 (não testado) |
| XP para os Pals da expedição | `ExpPercentOfNextLevel` (0 a 100) | `50` (meio nível) | ✅ testado (v0.4.0) |
| Boost nas recompensas | `RewardBoostPercent` (10 a 100) | `20` | ⏸️ aplicado na tabela, efeito não confirmado (pausado) |

### Tempo da expedição

`ExpeditionTimePercent` = % do tempo normal. Tempo final = `original × valor / 100`.

| Valor | Efeito | Expedição de 60 min |
| --- | --- | --- |
| 0 | quase instantâneo (mínimo 1 s) | ~0 min |
| 20 (padrão) | 80% menor | 12 min |
| 100 | normal | 60 min |
| 200 | o dobro | 120 min |

**Tempo igual para todas:** `ExpeditionFixedMinutes` > 0 faz todas as expedições (fáceis ou Hard) durarem exatamente esse tempo, ignorando `ExpeditionTimePercent`. `0` (padrão) desativa. Faixa: 0 a 720 min.

**Vale só para expedições iniciadas depois que o jogo carregou com o mod.** Cada expedição guarda a data de término (`MissionCompleteDateTime`) quando começa.

O mod altera o campo `RequiredSeconds` de cada linha de `DT_CharacterTeamMissionDataTable` (no código do jogo, expedição = "CharacterTeamMission"), sempre a partir do valor original. Reaplicar não acumula.

Tempos originais (patch de 15/09/2026):

| Expedição | `RequiredSeconds` |
| --- | --- |
| Grass, Forest | 1800 (30 min) |
| Volcano, Desert | 2700 (45 min) |
| Snow, Sakurajima, DarkIsland, SkyIsland, WorldTree | 3600 (60 min) |
| Todas as versões Hard | 7200 (2 h) |

**Conflito:** o mod `ExpeditionTimer_75` (`.pak`) substitui a mesma tabela. Remova-o: na descoberta os valores lidos eram os originais, ou seja, ele já não estava tendo efeito.

### XP dos Pals

Cada Pal que volta da expedição ganha **`ExpPercentOfNextLevel` % do XP do nível atual para o próximo** (50 = meio nível). Nunca sobe mais de um nível por expedição; Pals no nível máximo não ganham.

Como funciona:

1. `AddStartTeamMissionLog_ToServer` (início) e uma checagem a cada minuto anotam quais Pals estão em expedição (`IsAssignedToExpedition()`).
2. `AddCompleteTeamMissionLog_ToClient(MissionId)` (fim): 3 s depois, quem saiu da lista voltou.
3. Para cada um: `PalExpDatabase:GetTotalExp` dá o XP do nível; o mod soma em `SaveParameter.Exp` e recalcula `SaveParameter.Level` com `CalcLevelFromTotalExp`, e confere lendo `GetExp()`.

O jogo não expõe uma função para dar XP a um Pal específico (`AddExp` é nativa), por isso a escrita é direta no save do Pal. **Riscos:** sem animação de "subiu de nível"; atributos podem só atualizar quando o Pal for recarregado. Faça backup do save antes de testar.

A regra original ("mesmo XP do bônus do jogador") foi abandonada: `CalcExpeditionBonusExp` não dispara ao fim da expedição.

### Boost nas recompensas

As recompensas ficam em `DT_ItemLotteryDataTable`, nas linhas cujo `FieldName` começa com `Expedition_` (o mesmo nome do campo `ItemFieldLotteryName` de cada expedição). O mod multiplica `MinNum` e `MaxNum` dessas linhas por `1 + RewardBoostPercent/100`, arredondando e sempre a partir do original.

Exemplo (Expedition_Grass, +20%): PalSphere 5-10 → 6-12; CopperOre 30-50 → 36-60. Quantidades pequenas (1-2) podem não mudar com o arredondamento.

**Status (07/10/2026): pausado, efeito não confirmado.** O log confirma que `MinNum`/`MaxNum` mudaram na tabela, mas os itens recebidos não permitiram confirmar que o jogo usa esses valores: as quantidades são sorteadas, o jogo aplica o próprio "Prêmio %" por cima e não houve uma expedição de referência sem boost. Próximo passo sugerido: testar com `RewardBoostPercent = 100` (faixas dobradas) e comparar com as expedições a +20%.

---

## Instalação

**Pré-requisito:** [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS/releases) para Palworld.

Copie o conteúdo deste projeto para:

```text
<Palworld>/Pal/Binaries/Win64/ue4ss/Mods/ExpeditionExp/
```

A pasta precisa ter `enabled.txt`, `config.txt` e `Scripts/main.lua`.

---

## Verificando no log

Em `ue4ss/UE4SS.log`:

```text
[ExpeditionExp] v0.2.0 carregado: tempo das expedições = 20% do original.
[ExpeditionExp] Tempo das expedições = 20% do original (18 linha(s)): DUNGEON_GRASS 1800->360, ...
[ExpeditionExp] HOOK AddCompleteTeamMissionLog_ToClient disparou em ...
```

---

## Histórico

### v0.4.1

- Confirmado em jogo (v0.4.0): 100 de 100 Pals ganharam XP em cada expedição; quem subiu de nível teve os atributos atualizados na hora (ex.: Vixy Lv1 → Lv2, HP 600 → 651).
- Ao fim de cada expedição, grava no log as faixas de itens daquela expedição (original → com boost), para conferir o boost de recompensas.

### v0.4.0

- Boost de recompensas (`RewardBoostPercent`, padrão 20).

### v0.3.1

- Corrige "0 Pal(s) voltaram": a checagem periódica esvaziava a lista entre o hook de fim e a conferência. Agora o mod guarda quando viu cada Pal em expedição pela última vez.

### v0.3.0

- XP para os Pals que voltam da expedição (`ExpPercentOfNextLevel`, padrão 50).
- Descoberta (só log) das tabelas de sorteio de itens, para o boost de recompensas.

### v0.2.2

- Confirmado em jogo: o tempo reduzido funciona (Sakurajima a 20% durou 10:12). `AddStartTeamMissionLog_ToServer` dispara no início e `AddCompleteTeamMissionLog_ToClient(MissionId)` no fim. `CalcExpeditionBonusExp` não disparou.
- Descoberta para o XP (só log): funções de XP/nível dos Pals e campos de XP do save; quantos Pals voltam ao fim de cada expedição.

### v0.2.1

- `ExpeditionFixedMinutes`: mesmo tempo para todas as expedições.

### v0.2.0

- Tempo das expedições configurável (`ExpeditionTimePercent`).
- Removida a varredura completa de descoberta (causava uma travada ao carregar).

### v0.1.0 a v0.1.2 (descoberta)

- Só gravavam no log as funções, estruturas e a tabela das expedições.
