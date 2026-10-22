# Contribuir a SRI Robot Monitor

Gracias por querer mejorar la app. Este documento describe cómo trabajamos para
que los cambios entren sin fricción.

## Antes de escribir código

1. Busca si ya existe un issue. Si no, abre uno con la plantilla adecuada
   (`.github/ISSUE_TEMPLATE/`).
2. Para cambios grandes (nueva fuente de logs, cambios de permisos de AWS,
   rediseño de una pantalla), abre primero un issue de *propuesta* y espera
   acuse de recibo. Así evitamos PR de 2 000 líneas sin acuerdo previo.
3. Para arreglos pequeños (typos, un color, un mensaje) puedes ir directo al PR.

## Entorno

- macOS 14 o superior.
- Xcode 26 (Swift 6, *strict concurrency*).
- Sin dependencias externas: el proyecto no usa paquetes Swift, ni siquiera el
  SDK de AWS. Mantenerlo así es parte del diseño (ver
  [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)).

```bash
git clone https://github.com/julioserpone/sri-robot-monitor.git
cd sri-robot-monitor
open SriRobotMonitor.xcodeproj
```

## Ramas y commits

- `main` está protegida: **no** se hace push directo.
- Rama por cambio, con prefijo:
  - `feat/…` — funcionalidad nueva
  - `fix/…` — corrección de errores
  - `docs/…` — documentación
  - `chore/…` — mantenimiento
  - `test/…` — pruebas
- Commits en [Conventional Commits](https://www.conventionalcommits.org/es/v1.0.0/):

```
feat(live-tail): reconectar la sesión al cambiar de región
fix(analyzer): no marcar la ejecución como error si llega el REPORT
docs(arquitectura): explicar el modo tail
```

- Un commit = un cambio con sentido. Nada de `wip` ni de mezclar refactors con
  arreglos.

## Estilo de código

- Swift Format del propio Xcode, 4 espacios, sin tabs.
- Los nombres y la documentación del proyecto están en **español**; los
  identificadores siguen las convenciones de Swift (`camelCase`,
  `PascalCase`). Los conceptos técnicos de AWS se dejan en inglés (`Live Tail`,
  `RequestId`, `log group`).
- Todo tipo o función pública lleva un comentario que explique **por qué**
  existe, no qué hace el código de al lado.
- Nada de credenciales, endpoints reales de cuentas ajenas ni datos de
  contribuyentes en el código ni en los tests.

## Pruebas

Antes de abrir el PR:

```bash
xcodebuild -project SriRobotMonitor.xcodeproj -scheme SriRobotMonitor \
  -configuration Debug -destination 'platform=macOS' test
```

Toda funcionalidad nueva trae pruebas. Si tocas el análisis de logs, la firma
SigV4 o el decodificador de streams, **añade un caso que falle sin tu cambio**.
Detalle en [docs/TESTING.md](docs/TESTING.md).

## Pull requests

1. Rellena la plantilla completa (incluida la sección de IA).
2. El PR debe pasar **todos** los checks de CI:
   - `Documentación y convenciones`
   - `Compilar y probar (macOS)`
   - `Análisis de seguridad` (CodeQL)
3. No requiere aprobaciones, pero sí checks en verde.
4. Actualiza `CHANGELOG.md` en la sección `No publicado` cuando el cambio sea
   visible para quien usa la app.
5. Un PR, un tema. Si el diff se va de 400 líneas, probablemente haya que
   partirlo.

## Uso de IA

Se acepta y se anima a usar asistentes. La condición es que entiendas y puedas
explicar cada línea que envías. Lee [docs/AI_USAGE.md](docs/AI_USAGE.md) y declara
el uso en el PR.
