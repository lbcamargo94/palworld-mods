# Bigger Storage

Mod UE4SS (Lua) para Palworld que aumenta os slots dos baús, caixas e armários da base e mostra quantos slots estão ocupados no título das janelas.

- **Baús maiores:** cada tipo tem seu próprio valor no `config.txt` (por padrão, o dobro do jogo).
- **Contador de slots:** o título da janela mostra "usados/total", por exemplo "Baú de Metal Refinado (39/80)" e "Inventário (8/48)".

## Instalação

Copie a pasta para `Palworld\Pal\Binaries\Win64\ue4ss\Mods\BiggerStorage` (com `Scripts\main.lua`, `config.txt`, `info.json` e `enabled.txt`). Requer UE4SS 3.0.1 ou mais novo.

## Limitações

- **Só vale para baús construídos depois de instalar o mod.** Um baú que já existia guarda o tamanho no save; para aumentá-lo, esvazie, desmonte e construa de novo.
- **O mod não altera o inventário do jogador.** O tamanho dele também fica no save, e o jogo não oferece um jeito de mudá-lo (`SetInventorySize` e `DebugInventorySize` não têm efeito na versão final). `InventorySlots` no config fica reservado. Para aumentar o inventário, edite o save com `tools\patch_inventory.py` (veja abaixo).
- O contador aparece na janela do baú (no título do baú e no do inventário ao lado). Na tela de inventário da tecla Tab, ainda não.

## Configuração

Cada linha `Id = slots` define o tamanho de um tipo. Valores menores que o padrão do jogo são ignorados. Os padrões estão comentados no `config.txt`.

| Id | Objeto | Padrão | Mod |
|---|---|---|---|
| ItemChest | Baú de Madeira | 10 | 20 |
| ItemChest_02 | Baú de Metal | 24 | 48 |
| ItemChest_03 | Baú de Metal Refinado | 40 | 80 |
| ItemChest_04 | Baú de Civilização Avançada | 54 | 108 |
| Refrigerator | Refrigerador | 25 | 50 |
| GuildChestSlots | Baú da Guilda | 54 | 108 |
| PalFoodBox | Ração | 6 | 12 |
| CoolerPalFoodBox | Caixa de Ração Refrigerada | 30 | 60 |
| PalMedicineBox | Armário de Remédios | 6 | 12 |

Caixas, prateleiras e armários decorativos também estão no `config.txt`.

Outras opções:

- `ShowSlotCounter`: liga ou desliga o contador no título.
- `HitchMonitor`: grava em `hitches.txt` cada frame acima de `HitchThresholdMs`. É só para diagnóstico.
- `VerboseLogging`: logs detalhados no console do UE4SS.

## Aumentar o inventário e o baú da guilda (edição do save)

`tools\patch_inventory.py` muda o `SlotNum` de um container que já existe no `Level.sav`. São 4 bytes; nenhum tamanho do arquivo muda. Os alvos são:

- `inventory`: o inventário principal. O ID do container é lido de `Players\*.sav`.
- `guild`: o baú da guilda. Todos os baús da guilda compartilham um único container, criado junto com o primeiro baú. Por isso o `GuildChestSlots` do mod não aumenta um baú da guilda que já existe. O script acha o container pelo ID citado em `GuildItemStorage`.

Nos dois casos, o save só guarda os slots ocupados, e o jogo cria os vazios até chegar ao `SlotNum`. O arquivo é regravado como `PlM` com blocos Oodle sem compressão e, antes de substituir o original, o script confere que ele descompacta idêntico ao editado. No próximo salvamento, o jogo volta a compactar.

Com o **jogo fechado** e um **backup** da pasta do mundo:

```bat
py -m venv venv
venv\Scripts\pip install pyooz
venv\Scripts\python tools\patch_inventory.py "%LOCALAPPDATA%\Pal\Saved\SaveGames\<steamid>\<mundo>" inventory 96            (simulação)
venv\Scripts\python tools\patch_inventory.py "%LOCALAPPDATA%\Pal\Saved\SaveGames\<steamid>\<mundo>" inventory 96 --write    (grava)
venv\Scripts\python tools\patch_inventory.py "%LOCALAPPDATA%\Pal\Saved\SaveGames\<steamid>\<mundo>" guild 108 --write       (baú da guilda)
```

Funciona com saves `PlM1` (formato Oodle do jogo a partir de 2025). Assume um único jogador na pasta `Players`.

## Atalhos de diagnóstico

- **Ctrl+F10:** grava `report.txt` com os slots reais dos baús no mundo e do inventário.
- **Ctrl+F11:** grava `ui.txt` com a árvore de widgets da janela de itens aberta.

## Como funciona

- O tamanho de cada baú vem do `SlotNum` do componente `PalMapObject<X>ParameterComponent` no blueprint `BP_BuildObject_<Id>_C`. O mod recebe um aviso (`NotifyOnNewObject`) quando o jogo cria esse componente e ajusta o `SlotNum`. Ele não carrega assets nem faz buscas periódicas: a v0.2.0 recarregava blueprints e causava travadas.
- O contador lê o `Target Container` das listas `WBP_PalItemScrollList_C` e `WBP_PalPlayerInventoryScrollList_C`. O texto é criado pelo próprio jogo (`KismetTextLibrary:Conv_StringToText` e depois `SetText`); o mod nunca monta um FText no Lua.
- A descoberta usada para levantar os padrões está em `tools\discovery.lua`.

## Versões

- **0.3.2:** o contador confere se cada slot existe antes de perguntar se está vazio (provável causa de um crash no UE4SS com o baú da guilda editado para 108).
- **0.3.1:** contador no título "Inventário", procurando o título pelo nome na árvore da janela.
- **0.3.0:** contador "usados/total" no título do baú.
- **0.2.4:** monitor de travadas e diagnóstico da interface.
- **0.2.1–0.2.3:** sem travadas (`NotifyOnNewObject` no lugar de `LoadAsset` e varreduras); tentativas de aumentar o inventário, sem efeito.
- **0.2.0:** primeira versão que aumenta os baús novos.
- **0.1.x:** descoberta, só leitura.
