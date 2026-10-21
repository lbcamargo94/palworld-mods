# Correção do UE4SS: trava nos ciclos assíncronos do Lua

**Base:** RE-UE4SS, commit `2281fa311e417b1dfddedbcd49972d764fddb244`
(build "Experimental Palworld" 3.0.1).

## Problema

`LuaMod::process_delayed_actions()` (thread assíncrona de cada mod Lua) executa os
callbacks de `LoopAsync` e `ExecuteWithDelay` em `async_lua`, que é uma *thread* Lua do
mesmo `lua_State` usado por `hook_lua` no game thread (`RegisterHook`,
`ExecuteInGameThread`, `NotifyOnNewObject`). O game thread segura
`LuaMod::m_thread_actions_mutex` ao rodar Lua; a thread assíncrona não. Quando os dois
coincidem, o estado Lua compartilhado (GC, registro, tabelas) é corrompido e o jogo cai
em pontos aleatórios (`luaH_set`, `mainpositionTV`, `luaL_ref`, `prepare_to_handle`...).

## Correção

`0001-luamod-async-lock.patch` faz a thread assíncrona segurar a mesma trava enquanto
executa cada callback. `LuaMod::uninstall()` já para a thread assíncrona antes de pegar a
trava, então não há deadlock na descarga dos mods.

Aplicar e compilar:

```
git apply 0001-luamod-async-lock.patch
cmake --build build_cmake_Game__Shipping__Win64 --target UE4SS
```

Depois substitua `Palworld\Pal\Binaries\Win64\ue4ss\UE4SS.dll` pelo arquivo compilado
(guarde o original). Gerenciadores de mods como o Vortex podem recolocar o original ao
reimplantar os mods.

O DLL compilado não é distribuído aqui: ele inclui código do submódulo privado
`deps/first/Unreal` (UEPseudo).
