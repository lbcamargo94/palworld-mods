# Arquivo

Tentativas desativadas, mantidas como referência.

| Mod | Ideia | Por que ficou de fora |
|---|---|---|
| **SpawnVariety** (Lua) | Variar as espécies dos grupos editando `DT_PalWildSpawner`. | Os spawners usam uma lista de grupos embutida no mapa (`SpawnGroupList`); a tabela não é lida durante o jogo. |
| **SpawnDensity** (Lua) | Mais grupos criando cópias dos spawners comuns. | As cópias de spawner causavam travadas e crashes. Substituído pelo `PalSpawnGroups` (C++). |
| **PalTransportBoost** (C++) | Mais pilhas por viagem no transporte da base (`MaxItemStackNum`). | O valor é sempre 0 durante o jogo; não é ele que limita a carga. |
| **BigStacks** (PalSchema) | Pilhas de 999.999 editando `DT_ItemDataTable`. | O jogo usa os objetos `UPalStaticItemDataBase`, não a tabela. Substituído pelo `PalItemTweaks` (C++). |
