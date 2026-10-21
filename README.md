# Palworld Mods

Coleção de mods para **Palworld** (Steam, versão de 15/09/2026, build 25246127), feitos com
[RE-UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) (Lua e C++) e
[PalSchema](https://github.com/Okaetsu/PalSchema). Todos foram testados em single-player.

> Requer o UE4SS **"Experimental Palworld"** (3.0.1, commit `2281fa31`) e, para os mods
> PalSchema, o próprio PalSchema. Os mods C++ foram compilados contra esse mesmo commit.

## Mods

### Lua (`lua/`)

| Mod | O que faz |
|---|---|
| **BiggerStorage** | Mais slots nos baús (padrão: o dobro) e contador `usados/total` no título do baú e do inventário. |
| **FastRespawn** | Respawn de chefes de campo e de dungeon em minutos configuráveis (padrão 30) e cronômetro de respawn no ícone do chefe no mapa. |
| **GliderSpeed** | Velocidade dos planadores +50% (configurável de 0 a 200%). |
| **BetterFishing** | Pesca automática (sem mini-jogo), mordida mais rápida e spots de pesca voltando em tempo fixo (padrão 10 s). |
| **FastBreeding** | Rancho de criação produz ovos mais rápido (padrão 30 s). |
| **BiggerMagazines** | Pentes das armas maiores (padrão x3). |
| **BiggerPalBox** | Caixa de Pals com o dobro de páginas (64). Não desative depois de guardar Pals nas páginas novas. |
| **PalPerformance** | Ajustes de carregamento e coleta de lixo do motor (cvars) que reduzem as travadas. |
| **ExpeditionExp** | Expedições mais curtas, recompensas maiores e XP para os Pals que voltam. |
| **PassiveRemover** | Opção "Remover característica" na Mesa de Cirurgia (parte Lua + parte PalSchema). |

### C++ (`cpp/`, com a DLL pronta em `dist/dlls/main.dll`)

| Mod | O que faz |
|---|---|
| **PalItemTweaks** | Pilhas até 999.999; implantes de "uso único" viram permanentes; reviver na caixa de Pals em 10% do tempo; máquina de condensação pede metade dos Pals (com correção para Pals que ficariam travados); moedas sem peso; coleta automática do loot próximo (fora das bases); organizador que leva itens importantes para a aba certa. |
| **PalBaseStorage** | Fabricar e construir usando os baús de todas as bases da guilda e o Baú da Guilda (o que falta é trazido para o inventário na hora). Receitas de itens que você já possui (ex.: selas) aparecem em verde. |
| **PalSpawnGroups** | Grupos extras de Pals selvagens nos spawners comuns, com grupos de 1 a 3 Pals (chefes e dungeons de fora). Pesa no FPS. |

### PalSchema (`palschema/`)

| Mod | O que faz |
|---|---|
| **ImplantShop** | Todos os implantes do jogo à venda nos negociantes que usam ouro, 16 implantes novos de passivas únicas (Regente de Terra, Imponência...), preços da Mesa de Cirurgia 75% menores e nomes corrigidos. |
| **EssentialCoins** | Moeda de cachorro e prova de conquista na aba de itens importantes, sem peso. |
| **AlwaysDrops** | Todos os itens da tabela de drops dos Pals com 100% de chance. |
| **PassiveRemover** | Parte PalSchema do Passive Remover (característica "Remover característica" e textos). |

## Instalação

Pasta base: `Palworld\Pal\Binaries\Win64\ue4ss\Mods\`.

- **Lua:** copie `lua/<Mod>` para `Mods\<Mod>` (a pasta precisa ter `enabled.txt`).
- **C++:** crie `Mods\<Mod>\dlls\` e copie `dist/dlls/main.dll` para lá, junto com `config.txt`
  em `Mods\<Mod>\` e um `enabled.txt` vazio.
- **PalSchema:** copie `palschema/<Mod>` para `Mods\PalSchema\mods\<Mod>`.

Cada mod tem um `config.txt` comentado em português; as mudanças valem ao abrir o jogo.

## Correção do UE4SS (`ue4ss-patch/`)

O UE4SS 3.0.1 executa os ciclos `LoopAsync`/`ExecuteWithDelay` dos mods Lua numa thread
separada **sem** a trava (`m_thread_actions_mutex`) que protege o estado Lua compartilhado
com os ganchos do jogo. Isso corrompe a memória do Lua e causa crashes aleatórios. O patch
acrescenta a trava; veja [`ue4ss-patch/README.md`](ue4ss-patch/README.md).

## Compilando os mods C++

1. Clone o RE-UE4SS no commit `2281fa31` com os submódulos (o submódulo `deps/first/Unreal`
   exige acesso à organização EpicGames no GitHub).
2. Em `cppmods/CMakeLists.txt`, acrescente `add_subdirectory("<caminho>/cpp/<Mod>" "${CMAKE_BINARY_DIR}/<Mod>")`.
3. Com o Visual Studio 2026 (C++), Rust nightly e Ninja:
   ```
   cmake -B build_cmake_Game__Shipping__Win64 -G Ninja -DCMAKE_BUILD_TYPE=Game__Shipping__Win64
   cmake --build build_cmake_Game__Shipping__Win64 --target <Mod>
   ```

## Ferramentas (`tools/`)

- `patch_inventory.py`: aumenta o inventário do jogador ou o Baú da Guilda direto no save
  (`patch_inventory.py <world> <inventory|guild> <tamanho> [--write]`). Faça backup antes.
- `discovery_*.lua`: scripts de descoberta usados durante o desenvolvimento.

## Arquivo (`archive/`)

Tentativas que não deram certo e ficaram desativadas, mantidas como referência — veja
[`archive/README.md`](archive/README.md).

## Licença

MIT — veja [LICENSE](LICENSE). Palworld é marca da Pocketpair, Inc.; este projeto não tem
relação oficial com a Pocketpair.
