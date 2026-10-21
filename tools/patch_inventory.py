"""Aumenta containers já existentes no Level.sav do Palworld.

Alvos:
  inventory - inventário principal do jogador (CommonContainerId do Players/*.sav)
  guild     - baú da guilda (container único citado em GuildItemStorage)

Edição de 4 bytes: o IntProperty SlotNum do container (só os slots ocupados
ficam salvos, o jogo cria os vazios até SlotNum). Nenhum tamanho muda. O
arquivo é regravado como PlM com blocos Oodle sem compressão (flag
"uncompressed" no cabeçalho de cada bloco de 256 KB) e validado com ooz antes
de substituir o original. No próximo salvamento o jogo volta a compactar.

Uso: python patch_inventory.py <pasta do mundo> <inventory|guild> <novo tamanho> [--write]
Sem --write só mostra o que faria. Feche o jogo e faça backup antes.
"""
import struct
import sys
from pathlib import Path

import ooz

BLOCK = 0x40000  # 256 KB por bloco Oodle


def fstring(name: str) -> bytes:
    raw = name.encode("ascii") + b"\0"
    return struct.pack("<i", len(raw)) + raw


SLOT_PATTERN = fstring("SlotNum") + fstring("IntProperty") + struct.pack("<q", 4) + b"\0"


def decode(data: bytes, name: str):
    uncompressed, compressed = struct.unpack_from("<II", data, 0)
    magic = data[8:12]
    if magic[:3] != b"PlM":
        raise SystemExit(f"{name}: formato {magic!r} não suportado")
    stream = data[12:12 + compressed]
    raw = ooz.decompress(stream, uncompressed)
    if len(raw) != uncompressed:
        raise SystemExit(f"{name}: tamanho descompactado não confere")
    return raw, magic, stream[:2]


def read_sav(path: Path):
    return decode(path.read_bytes(), path.name)


def build_plm(raw: bytes, magic: bytes, first_header: bytes) -> bytes:
    # Cabeçalho do bloco: byte0 = 0x0C | 0x80 (restart) | 0x40 (uncompressed);
    # byte1 = tipo do decodificador do original, sem checksum.
    header = bytes([0x0C | 0x80 | 0x40, first_header[1] & 0x7F])
    parts = []
    for off in range(0, len(raw), BLOCK):
        parts.append(header)
        parts.append(raw[off:off + BLOCK])
    stream = b"".join(parts)
    return struct.pack("<II", len(raw), len(stream)) + magic + stream


def container_range(level: bytes):
    start = level.find(fstring("ItemContainerSaveData"))
    end = level.find(fstring("CharacterContainerSaveData"), start)
    if start < 0 or end < 0:
        raise SystemExit("ItemContainerSaveData não encontrado no Level.sav")
    return start, end


def slotnum_offset(level: bytes, guid: bytes) -> int:
    """Offset do valor do SlotNum do container cuja chave é `guid`."""
    start, end = container_range(level)
    hits, pos = [], level.find(guid, start, end)
    while pos >= 0:
        hits.append(pos)
        pos = level.find(guid, pos + 1, end)
    if len(hits) != 1:
        raise SystemExit(f"Container encontrado {len(hits)} vezes na lista (esperado 1)")
    h = hits[0]
    # O valor do container começa com o próprio BelongInfo; o próximo
    # BelongInfo marca o container seguinte.
    own = level.find(fstring("BelongInfo"), h, end)
    nxt = level.find(fstring("BelongInfo"), own + 1, end)
    s = level.find(SLOT_PATTERN, h, end)
    if s < 0 or (nxt >= 0 and s > nxt):
        raise SystemExit("SlotNum não encontrado dentro do container")
    return s + len(SLOT_PATTERN)


def inventory_guid(world: Path) -> bytes:
    player, _, _ = read_sav(next((world / "Players").glob("*.sav")))
    i = player.find(fstring("CommonContainerId"))
    if i < 0:
        raise SystemExit("CommonContainerId não encontrado no Players.sav")
    j = player.find(fstring("ID"), i)
    k = player.find(fstring("Guid"), j)
    start = k + len(fstring("Guid")) + 16 + 1
    return player[start:start + 16]


def guild_guid(level: bytes) -> bytes:
    """Chave do container cujo GUID aparece nos dados de GuildItemStorage."""
    g = level.find(fstring("GuildItemStorage"))
    if g < 0:
        raise SystemExit("GuildItemStorage não encontrado (o mundo tem guilda com baú?)")
    window = level[g:g + 400]
    start, end = container_range(level)
    found = []
    pos = level.find(SLOT_PATTERN, start, end)
    while pos >= 0:
        belong = level.rfind(fstring("BelongInfo"), start, pos)
        key = level[belong - 25:belong - 9]
        if key in window:
            found.append(key)
        pos = level.find(SLOT_PATTERN, pos + 1, end)
    if len(found) != 1:
        raise SystemExit(f"{len(found)} containers ligados a GuildItemStorage (esperado 1)")
    return found[0]


def main() -> None:
    if len(sys.argv) < 4 or sys.argv[2] not in ("inventory", "guild"):
        raise SystemExit(__doc__)
    world, target, new_size = Path(sys.argv[1]), sys.argv[2], int(sys.argv[3])
    write = "--write" in sys.argv
    level_path = world / "Level.sav"

    level, magic, first_header = read_sav(level_path)
    guid = inventory_guid(world) if target == "inventory" else guild_guid(level)
    off = slotnum_offset(level, guid)
    current = struct.unpack_from("<i", level, off)[0]
    label = "Inventário principal" if target == "inventory" else "Baú da guilda"
    print(f"{label}: SlotNum = {current} (offset {off})")
    if current >= new_size:
        raise SystemExit(f"Já tem {current} slots - nada a fazer.")

    patched = bytearray(level)
    struct.pack_into("<i", patched, off, new_size)
    patched = bytes(patched)
    out = build_plm(patched, magic, first_header)

    # Validação: o arquivo novo precisa descompactar idêntico ao editado e
    # diferir do original só nos 4 bytes do SlotNum.
    check, _, _ = decode(out, "novo Level.sav")
    if check != patched:
        raise SystemExit("Validação falhou: descompactado difere do editado - nada gravado.")
    if sum(1 for a, b in zip(level, check) if a != b) > 4:
        raise SystemExit("Validação falhou: mais de 4 bytes alterados - nada gravado.")
    print(f"Validação OK: {len(out)} bytes, só o SlotNum mudou ({current} -> {new_size}).")

    if not write:
        print("Simulação - use --write para gravar.")
        return
    tmp = level_path.with_suffix(".sav.tmp")
    tmp.write_bytes(out)
    reread, _, _ = read_sav(tmp)
    if struct.unpack_from("<i", reread, off)[0] != new_size:
        tmp.unlink()
        raise SystemExit("Releitura falhou - nada gravado.")
    tmp.replace(level_path)
    print(f"Gravado: {level_path}")


if __name__ == "__main__":
    main()
