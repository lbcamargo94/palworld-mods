# Fast Breeding

Define o tempo da fazenda de acasalamento do Palworld para **1 ovo a cada 1 minuto** (configurável de 0,5 a 60 minutos; vanilla = 5 minutos). Mod Lua para UE4SS: não substitui arquivos do jogo.

- Altera apenas a propriedade `BreedRequiredRealTime`.
- **Não altera** receitas de bolo nem o consumo: cada ovo continua gastando 1 bolo. Com tempos menores, os bolos acabam mais rápido.
- Não chama funções do jogo. Antes de ler ou escrever, confere pela reflexão da classe se a propriedade existe, porque acessar uma propriedade inexistente causa ACCESS_VIOLATION mesmo dentro de `pcall`.

**Status:** v1.1.0. Testado em jogo no patch de 15/09/2026 (v1.0.0 confirmada: 300 s -> 60 s).

---

## Instalação

**Pré-requisito:** [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS/releases) instalado.

### Manual

1. Copie o conteúdo deste projeto para uma pasta `FastBreeding/` em:

   ```text
   <Palworld>/Pal/Binaries/Win64/ue4ss/Mods/FastBreeding/
   ```

   A pasta precisa ter `enabled.txt`, `config.txt` e `Scripts/main.lua`.

2. Lance o jogo. O `enabled.txt` já ativa o mod. Se preferir, adicione `FastBreeding : 1` em `ue4ss/Mods/mods.txt`.

### Via Vortex

Zippe a pasta `FastBreeding/` e instale como mod do tipo **UE4SS Lua**.

---

## Configuração

Edite `config.txt` dentro da pasta do mod:

```ini
Enabled = true         ; ativa/desativa o mod
BreedMinutes = 1       ; minutos por ovo (0.5 a 60; aceita 0,5)
ScanIntervalMs = 15000 ; intervalo entre verificações (ms)
VerboseLogging = false ; logs de debug
```

---

## Como funciona

A cada `ScanIntervalMs`, o mod procura objetos desta classe e ajusta `BreedRequiredRealTime` (em segundos) para `BreedMinutes × 60`:

| Classe | O que é |
| --- | --- |
| `PalMapObjectBreedFarmModel` | Cada fazenda de acasalamento construída |

Na primeira vez que encontra cada classe, o mod grava no `UE4SS.log` se a propriedade existe e quais propriedades com "Breed" a classe tem. Isso ajuda a ajustar o mod se uma atualização do jogo renomear algo.

---

## Verificando no log

Em `ue4ss/UE4SS.log`, procure linhas como:

```text
[FastBreeding] v1.1.0 carregado: 1 ovo a cada 1.0 min (60 s)
[FastBreeding] PalMapObjectBreedFarmModel: BreedRequiredRealTime encontrada (propriedades Breed: ...)
[FastBreeding] PalMapObjectBreedFarmModel: BreedRequiredRealTime 300.0 -> 60.0
```

Se todas as classes aparecerem como `ausente`, a propriedade está em outro lugar. Use a lista de propriedades "Breed" do log para ajustar `TARGET_CLASSES` ou `PROPERTY_NAME` no `main.lua`.

---

## Solução de problemas

- **Nada acontece:** confira se `enabled.txt` existe na pasta do mod e se `Enabled = true` no config.
- **Ovos ainda demoram:** veja o log. Se a propriedade aparece como `ausente`, o jogo guarda o tempo em outra classe.
- **Jogo crasha:** desative o mod (`Enabled = false`) e envie o trecho do `UE4SS.log` com `[FastBreeding]`.
