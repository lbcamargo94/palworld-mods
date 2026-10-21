# Passive Remover

Mod para Palworld (UE4SS Lua + PalSchema) que adiciona a opção **"Remover característica"** na mesa de cirurgia. Com ela você tira uma característica (habilidade passiva) de um Pal e deixa o slot vazio.

## Como usar

1. Abra a **mesa de cirurgia** e escolha o Pal.
2. Selecione o **slot** da característica que quer tirar.
3. Na lista, escolha **"Remover característica"**. Não exige implante e custa 1.000 de ouro.
4. Pronto: a característica some e o slot fica vazio. Se a tela do Pal não atualizar, feche e abra de novo.

## Instalação

São duas partes; as duas são necessárias:

| Pasta do projeto | Destino |
|---|---|
| `Scripts\`, `info.json`, `enabled.txt` | `Palworld\Pal\Binaries\Win64\ue4ss\Mods\PassiveRemover\` |
| `PalSchema\PassiveRemover\` | `Palworld\Pal\Binaries\Win64\ue4ss\Mods\PalSchema\mods\PassiveRemover\` |

Requer UE4SS 3.0.1 ou mais novo e o PalSchema.

## Configuração

- **Preço:** edite `"Price"` em `PalSchema\PassiveRemover\raw\passive_remover.jsonc` (em ouro) e reinicie o jogo.
- **Nome:** edite os arquivos em `PalSchema\PassiveRemover\translations\<idioma>\` (`pt-BR` e `en`).

## Como funciona

- **PalSchema:** cria a característica `PR_NoPassive`. Ela não tem efeito e nunca é sorteada em Pals selvagens (`LotteryWeight` 0). O mod a adiciona à lista da mesa (`DT_OperatingTablePassiveSkillDataTable`) sem implante, e o nome fica em `DT_SkillNameText` (`PASSIVE_PR_NoPassive`).
- **Lua:** observa o pedido da mesa (`PalMapObjectOperatingTableModel:RequestChangePassiveSkill`). Quando a característica escolhida é `PR_NoPassive`, chama `PalIndividualCharacterParameter:RemovePassiveSkill` no Pal da cirurgia. Para achar o Pal, tenta primeiro `targetHandle:TryGetIndividualParameter()` e, se falhar, procura entre todos os Pals.
- **Limpeza:** 15 s depois de entrar no mundo, remove `PR_NoPassive` de qualquer Pal que tenha ficado com ela (por exemplo, uma cirurgia feita com o script desativado).
- Mesmo que a remoção falhe, `PR_NoPassive` não tem efeito nenhum.
- `GetPassiveSkillList` devolve uma tabela Lua (e não um `TArray`). A v0.2.0 não tratava esse formato e por isso não removia.

## Versões

- **0.2.1:** remoção funcionando, com suporte ao formato de lista correto e uso do Pal da cirurgia.
- **0.2.0:** primeira versão com a característica na mesa. A remoção falhava.
- **0.1.0:** descoberta, só leitura (`tools\discovery.lua`).
