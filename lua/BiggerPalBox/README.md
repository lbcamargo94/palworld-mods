# Bigger Pal Box

Mod UE4SS (Lua) para Palworld que aumenta o número de páginas da caixa de Pals. O padrão do mod é **64 páginas (1920 Pals)**, o dobro das 32 páginas (960 Pals) do jogo.

## Instalação

Copie a pasta para `Palworld\Pal\Binaries\Win64\ue4ss\Mods\BiggerPalBox` (com `Scripts\main.lua`, `config.txt`, `info.json` e `enabled.txt`). Requer UE4SS 3.0.1 ou mais novo.

## Configuração

`PalBoxPages` no `config.txt`: cada página tem 30 Pals. Valores menores que o padrão do jogo (32) são ignorados.

## ⚠️ Importante

Depois que houver Pals além da página 32, **não desative o mod e não diminua `PalBoxPages`**. Sem o mod, o jogo volta a montar a caixa com 960 slots, e os Pals das páginas extras podem ser perdidos.

## Como funciona

- O jogo usa `PalGameSetting.PalBoxPageNum` (32) e `PalBoxSlotNumInPage` (30) para a tela da caixa e para o tamanho do container da caixa. Esse container é o `PalStorageContainerId` do jogador.
- O mod muda `PalBoxPageNum` (nas instâncias e no CDO de `BP_PalGameSetting`) antes de o save carregar. Ao carregar o mundo, o próprio jogo monta o container com 64 × 30 = 1920 slots, sem precisar editar o save. Confirmado no patch de 2026-09-15.
- Ao entrar no mundo, o log mostra as páginas e o tamanho real da caixa: `Caixa: 64 página(s) x 30 Pals; containers grandes de Pals: [1920]`.

## Versões

- **0.1.0:** primeira versão. 64 páginas, confirmadas no jogo (guardar Pals nas páginas novas funciona).
