# AGENTS.md

## Regla de oro (inquebrantable)

NUNCA eliminar, sobrescribir ni descartar información no versionada.
Bajo ningún concepto. Sin permiso explícito y específico del usuario.

Prohibido sin OK explícito del usuario:
- `git checkout --`, `git restore` sobre ficheros con cambios sin commitear
- `git reset --hard`, `git clean`, `git stash drop` / `stash pop` destructivo
- Sobrescribir, truncar o borrar ficheros que no estén en el historial de git
  (incluidos los no rastreados)
- `rm` de cualquier cosa que no haya creado yo en esa misma operación

Si hay que revertir algo:
1. Primero pregunto.
2. Me limito a lo que yo mismo acabo de crear en esa misma operación.
3. Nunca toco trabajo del usuario ni cambios preexistentes.

## Contexto

- Repo: jukebox (Raspberry Pi + Volumio). Ver `skills/jukebox/SKILL.md`.
- Equipo en producción: `volumio@jukebox.local`. Los cambios en la caja son
  reales; avisar antes de operaciones disruptivas (reinicios, restarts de
  servicios, reinstalaciones).
