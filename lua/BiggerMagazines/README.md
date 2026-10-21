# Bigger Magazines

Multiplica a capacidade do pente das armas do Palworld: quantas balas cabem antes de precisar recarregar. Mod Lua para UE4SS: não substitui arquivos do jogo.

**Status:** v0.1.0, ainda não testado em jogo (patch de 15/09/2026).

---

## Configuração

Edite `config.txt` dentro da pasta do mod:

```ini
Enabled = true          ; ativa/desativa o mod
MagazineMultiplier = 3  ; 2 a 10 (3 = pente de 30 vira 90)
ScanIntervalMs = 15000  ; intervalo entre verificações (ms)
VerboseLogging = false  ; logs de debug
```

---

## Como funciona

O executável tem a propriedade `MagazineSize`, mas não diz a qual classe ela pertence. A v0.1.0 descobre e aplica na mesma execução:

1. **Descoberta (uma vez, ~15 s após carregar):** percorre todas as classes e structs e grava no log as propriedades com "Magazine" no nome. As classes com `MagazineSize` (inteiro) viram alvos.
2. **Aplicação (a cada `ScanIntervalMs`):** em cada objeto dessas classes, `MagazineSize = original × MagazineMultiplier`. O original é guardado na primeira leitura, então reaplicar nunca acumula. Pentes com valor 0 ou menor são ignorados.

Antes de tocar na propriedade, a reflexão confirma que ela existe na classe, porque acessar uma propriedade inexistente causa ACCESS_VIOLATION mesmo dentro de `pcall`. O mod não chama funções do jogo.

A descoberta percorre todos os objetos do jogo uma vez, então pode causar uma travada rápida cerca de 15 s depois de carregar.

---

## Instalação

**Pré-requisito:** [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS/releases) para Palworld.

Copie o conteúdo deste projeto para:

```text
<Palworld>/Pal/Binaries/Win64/ue4ss/Mods/BiggerMagazines/
```

A pasta precisa ter `enabled.txt`, `config.txt` e `Scripts/main.lua`.

---

## Verificando no log

Em `ue4ss/UE4SS.log`:

```text
[BiggerMagazines] v0.1.0 carregado: pente x3.
[BiggerMagazines] PROP Class /Script/Pal.<Classe> {MagazineSize:IntProperty, ...}
[BiggerMagazines] Descoberta: N tipo(s) com "Magazine"; alvos: <Classe>
[BiggerMagazines] <Classe>: M objeto(s) com pente x3. Ex.: <arma> 30->90, ...
```

Se aparecer `alvos: nenhum`, as linhas `PROP` mostram onde o tamanho do pente fica, e o mod precisa ser ajustado.
