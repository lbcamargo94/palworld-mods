# Better Fishing

Melhora a experiência de pesca no Palworld com hooks UE4SS. Não substitui arquivos do jogo — maior compatibilidade com outros mods e atualizações.

**Compatível com Palworld 1.0** (build 1.100.427) e com o patch de 15/09/2026 (hooks conferidos no executável; v1.3.2 ainda não testada em jogo)

---

## Funcionalidades (v1.3.2)

| Feature | Config | Padrão | Status |
| --- | --- | --- | --- |
| Captura instantânea | `InstantCapture` | `true` | ✅ Funcionando |
| Auto-ferrar na mordida | `AutoStrike` | `true` | ✅ Funcionando |
| Tempo de mordida | `BiteTimeMultiplier` | `0.25` | 🧪 v1.3 (não testado) |
| Resistência do peixe | `FishResistanceMultiplier` | — | 🔜 v1.2 |
| Chance de escapar | `EscapeChanceMultiplier` | — | 🔜 v1.2 |
| Respawn de pontos | `FishingSpotRespawnMultiplier` | `1.0` | 🧪 v1.3 (se a propriedade for acessível) |
| Quantidade de loot | `RewardMultiplier` | — | 🔜 v1.2 |
| Consumo de isca | `BaitConsumptionChance` | — | 🔜 v1.2 |
| Modo Hardcore | `HardcoreMode` | — | 🔜 v1.2 |

---

## Instalação

**Pré-requisito:** [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS/releases) instalado.

### Manual

1. Copie a pasta `BetterFishing/` para:

   ```text
   <Palworld>/Pal/Binaries/Win64/ue4ss/Mods/
   ```

2. Abra `ue4ss/Mods/mods.txt` e adicione:

   ```text
   BetterFishing : 1
   ```

3. Lance o jogo.

### Via Vortex

Zippe a pasta `BetterFishing/` e instale como mod do tipo **UE4SS Lua**.

---

## Configuração

Edite `config.txt` dentro da pasta do mod. As opções disponíveis na v1.1.0:

```ini
Enabled = true          ; ativa/desativa o mod
InstantCapture = true   ; captura sem mini-jogo
AutoStrike = true       ; ferragem automática na mordida
CatchSuccessDelayMs = 200  ; delay antes de forçar sucesso (ms)
NotifyChatEnabled = true   ; mensagem no chat a cada captura
VerboseLogging = false     ; logs de debug (manter false em uso normal)
```

---

## Solução de problemas

- **Nada acontece:** verifique `mods.txt` (`BetterFishing : 1`) e `Enabled = true` no config.
- **InstantCapture não valida em servidor dedicado:** aumente `CatchSuccessDelayMs` (tente 500 ou 1000).
- **Jogo crasha:** desative `VerboseLogging` e verifique se outros mods não conflitam.

---

## Guia: Gerando ObjectDump para a v1.2

Os multiplicadores (BiteTime, Resistance, Escape, Respawn, Reward) precisam dos **nomes exatos das propriedades** dentro dos objetos do jogo para funcionar sem causar crashes. O UE4SS consegue gerar um dump com todos esses nomes.

### 1. Habilitar o GUI do UE4SS

Edite o arquivo:

```text
<Palworld>/Pal/Binaries/Win64/ue4ss/UE4SS-settings.ini
```

Encontre e altere estas duas linhas:

```ini
GuiConsoleEnabled = 1
GuiConsoleVisible = 1
```

### 2. Gerar o dump

1. Lance o Palworld normalmente
2. Uma **janela separada do UE4SS** vai abrir junto com o jogo
3. Entre no mundo (carregue o save)
4. Na janela UE4SS, clique na aba **Dumpers**
5. Clique em **Dump Objects and Properties**
6. Aguarde alguns segundos até aparecer "Done" na janela

> ⚠️ **Não feche o jogo durante o dump** — pode levar 5–30 segundos.

### 3. Localizar o arquivo gerado

```text
<Palworld>/Pal/Binaries/Win64/ue4ss/UE4SS_ObjectDump.txt
```

### 4. Encontrar as propriedades de pesca

Abra o `UE4SS_ObjectDump.txt` (é grande — use um editor como VS Code) e busque pelas classes:

#### `PalFishingComponent` — controla a cana e o mini-jogo

```text
Buscar por: PalFishingComponent
Propriedades esperadas (nomes aproximados):
  → tempo de mordida:   WaitBite, BitingWait, HitWait, FishingBite
  → resistência:        Resistance, GaugeIncrease, BattleGauge
  → chance de escapar:  Escape, FailureRate, EscapeChance
  → consumo de isca:    Bait, Consume, BaitUse
```

#### `PalFishingPoint` ou `BP_FishingPoint_C` — pontos de pesca no mapa

```text
Buscar por: FishingPoint
Propriedades esperadas (nomes aproximados):
  → respawn:  RespawnTime, RestoreTime, RegenTime, SpawnInterval
```

### 5. O que fazer com os nomes encontrados

Abra uma **issue no repositório** (ou envie aqui) com os nomes exatos que aparecerem no dump para a classe `PalFishingComponent`. Com esses nomes, implementamos os multiplicadores na v1.2 com segurança.

Exemplo do que queremos ver:

```text
Class: PalFishingComponent
  Property: WaitBiteTimeMin  (float)
  Property: WaitBiteTimeMax  (float)
  Property: EscapeRate       (float)
  Property: BaitConsumeRate  (float)
```

### 6. Desabilitar o GUI após o dump (opcional)

Restaure o `UE4SS-settings.ini` para:

```ini
GuiConsoleEnabled = 0
GuiConsoleVisible = 0
```

---

## Notas técnicas

Hooks verificados (build 1.0 / 1.100.427):

- `/Script/Pal.PalFishingComponent:OnChangeRodState` — detecta mordida (WaitHit = 6)
- `/Script/Pal.PalNetworkFishingComponent:StartCatchBattle_ToServer` — dispara InstantCapture

Arquitetura de ownership descoberta durante o desenvolvimento:

- `PalFishingComponent` → owned by `BP_Player_Female_C` (Pawn)
- `PalNetworkFishingComponent` → owned by `PalNetworkTransmitter` *(não pelo Pawn nem pelo PlayerController)*

Por isso o mod usa uma flag interna (`localFishingPending`) em vez de checar o owner do `PalNetworkFishingComponent`.

---

## Histórico

### v1.3.2
- Corrige a v1.3.1: o sucesso volta a ser enviado ao servidor logo após `CatchSuccessDelayMs`. A v1.3.1 esperava a cutscene de captura antes, mas ela só carrega depois que o servidor recebe o sucesso, então a espera nunca terminava e o mini-jogo normal seguia.

### v1.3.1
- **Correção de crash** (`FMallocBinned2 Attempt to realloc an unrecognized block`, 06/10/2026, logo após uma captura instantânea):
  - `SuccessCatchBattle_ToServer` agora roda via `ExecuteInGameThread`. Antes era chamado de dentro do `ExecuteWithDelay`, que roda fora da thread do jogo.
  - Removido o aviso no chat (`SendLog_ToClient` com `FText`/`TArray` criados pelo Lua), que falhava a cada captura. A mensagem vai só para o log.
- **Pesca montado em Pal:** em single-player, o personagem do jogador é reconhecido mesmo quando `pc.Pawn` é a montaria.

### v1.3.0
- `BiteTimeMultiplier` implementado (`CatchBattleParameter.SinkWaitMinTime/MaxTime`).
- `FishingSpotRespawnMultiplier` via `FishShadowRespawnTime`, se acessível.
- Valores sempre calculados sobre o original (reaplicar não acumula).
- Diagnóstico automático das propriedades de pesca no log.
